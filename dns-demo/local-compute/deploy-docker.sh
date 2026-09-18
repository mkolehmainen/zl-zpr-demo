#!/usr/bin/env bash
# Configure + run ZPR in the local docker env. Copied from multinode-demo's
# deploy-docker.sh, pruned to local-only: the single node's address is
# compose's static IP, so this script only renders the @@...@@ templates,
# generates vs_keys.toml, compiles the policy, brings the containers up, then
# launches the ZPR processes in order via `docker exec`.
#
#   ./deploy-docker.sh
#
# Re-runnable: re-renders/recompiles every run, kills old tmux sessions first.
# Builds the zpr-dns-demo image itself, so `make` (to populate ../bin) is the
# only prerequisite.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # local-compute/
DEMO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN_DIR="$DEMO_DIR/bin"
CONF_TMPL="$DEMO_DIR/zpr-conf/confs"
INC_DIR="$DEMO_DIR/zpr-conf/include"
ADMIN="$DEMO_DIR/zpr-conf/admin"
COMPOSE=(docker compose -f "$DEMO_DIR/docker-compose.yml")

CONF_ROOT="$SCRIPT_DIR/conf"        # per-container /conf mounts
LOGS_DIR="$SCRIPT_DIR/logs"

# --- Step 0: addresses ---
NODE_ADDR="172.30.1.10"             # node's docker-internal static IP (compose)
echo "node internal=$NODE_ADDR"

# --- render: sub the token, fail loud on any leftover @@...@@ ---
render() {  # $1=template path  $2=output path
  sed -e "s#@@NODE_ADDR@@#${NODE_ADDR}#g" \
      "$1" > "$2"
  if grep -n '@@[A-Z0-9_]*@@' "$2"; then
    echo "ERROR: unresolved template token(s) above in $(basename "$2")" >&2
    exit 1
  fi
}

# --- Step 1: assemble per-container /conf dirs (rendered config + whole include/) ---
# Re-runnable: take any previous stack down first (a bind mount pins the dir
# inode, so files written after an rm -rf of a mounted dir would be invisible
# inside a still-running container).
"${COMPOSE[@]}" down --remove-orphans 2>/dev/null || true
rm -rf "$CONF_ROOT"
mkdir -p "$CONF_ROOT"/{node,vs,web,client,dns} "$LOGS_DIR"
for c in node vs web client dns; do cp -r "$INC_DIR" "$CONF_ROOT/$c/include"; done

render "$CONF_TMPL/node-conf.toml.template"           "$CONF_ROOT/node/node-conf.toml"
render "$CONF_TMPL/adapter-vs-conf.toml.template"     "$CONF_ROOT/vs/adapter-vs-conf.toml"
render "$CONF_TMPL/adapter-web-conf.toml.template"    "$CONF_ROOT/web/adapter-web-conf.toml"
render "$CONF_TMPL/adapter-client-conf.toml.template" "$CONF_ROOT/client/adapter-client-conf.toml"
render "$CONF_TMPL/adapter-dns-conf.toml.template"    "$CONF_ROOT/dns/adapter-dns-conf.toml"
cp "$CONF_TMPL/Corefile" "$CONF_ROOT/dns/Corefile"
cp "$SCRIPT_DIR/vs.toml" "$CONF_ROOT/vs/vs.toml"
cp "$ADMIN/attrfile.json" "$CONF_ROOT/vs/attrfile.json"   # policy attributes, read by vs
cp "$ADMIN/machines.json" "$CONF_ROOT/vs/machines.json"   # machine hostnames (zipline#55), read by vs

# --- Step 2: vs_keys.toml + client.key (operator key, used by commands/demo-vs-admin) ---
rm -f "$CONF_ROOT/vs/vs_keys.toml"
"$BIN_DIR/vsapikey" create --init readwrite client "$CONF_ROOT/vs/vs_keys.toml" > "$SCRIPT_DIR/client.key"
echo "client key written to $SCRIPT_DIR/client.key"

# Second key for the resolver: least privilege — `resolve` only (GET
# /admin/services*), appended to the same keys file, delivered to the dns
# container's /conf as a root-only file. The key string never lands in the
# Corefile or the image.
"$BIN_DIR/vsapikey" create resolve dns "$CONF_ROOT/vs/vs_keys.toml" > "$CONF_ROOT/dns/vs-resolve.key"
chmod 0600 "$CONF_ROOT/dns/vs-resolve.key"
echo "resolve key written to $CONF_ROOT/dns/vs-resolve.key"

# --- Step 3: compile policy on host (needs ../include keys the .zplc references) ---
render "$ADMIN/dns-demo.zplc.template" "$ADMIN/dns-demo.zplc"
( cd "$ADMIN" && "$BIN_DIR/zplc" --config dns-demo.zplc dns-demo.zpl )
mv "$ADMIN/dns-demo.bin2" "$CONF_ROOT/vs/dns-demo.bin2"

# --- Step 4: build the image, then bring up infra (entrypoints set up tun9 / valkey / nginx) ---
# Always build: docker's layer cache makes this a no-op unless the Dockerfile or
# bin/ changed, and bin/ is COPY'd in, so a rebuilt binary needs a rebuilt image.
docker build -t zpr-dns-demo "$DEMO_DIR"
"${COMPOSE[@]}" up -d
sleep 2

# --- Step 5: launch ZPR processes, each in a detached tmux, tee'd to /logs ---
# tee to a mounted /logs file so output survives the tmux session dying.
launch() {  # $1=container $2=session/logname $3=command(run with cwd /conf)
  docker exec "$1" tmux kill-session -t "$2" 2>/dev/null || true
  docker exec "$1" tmux new-session -d -s "$2" -c /conf "$3 2>&1 | tee /logs/$2.log"
  sleep 1
  docker exec "$1" tmux has-session -t "$2" 2>/dev/null \
    && echo "[$1] $2 running in tmux" \
    || { echo "ERROR: $2 exited immediately in $1 — see $LOGS_DIR/$2.log" >&2; exit 1; }
}

launch node node "/app/bin/ph node -c node-conf.toml"
sleep 4
launch vs vs "/app/bin/vs --clear-state dns-demo.bin2"
launch vs vs-adapter "/app/bin/ph adapter -c adapter-vs-conf.toml"
sleep 6

docker exec web curl -fsS http://localhost:80 >/dev/null \
  && echo "[web] nginx serving :80" \
  || { echo "ERROR: nginx not serving in web" >&2; exit 1; }
launch web web-adapter "/app/bin/ph adapter -c adapter-web-conf.toml"
launch client client-adapter "/app/bin/ph adapter -c adapter-client-conf.toml"
# After the VS: the resolver's adapter registers zpr-dns's pinned address.
# CoreDNS itself is the dns container's entrypoint, already running.
launch dns dns-adapter "/app/bin/ph adapter -c adapter-dns-conf.toml"

cat <<EOF

Done. Local ZPR DNS demo env is up.
  Logs:   tail -f $LOGS_DIR/*.log
  Attach: docker exec -it <node|vs|web|client> tmux attach -t <session>   (Ctrl-b d to detach)
  Teardown: ${COMPOSE[*]} down
EOF
