#!/usr/bin/env bash
# End-to-end DNS test for dns-demo (zipline#38, master plan I1 Steps 2-4).
#
# Proves that a ZPR client resolves a ZPL service name over the overlay and
# gets the current provider's address, that resolution is live, and that both
# hops are policy-governed. Run after deploy-docker.sh; exits non-zero on the
# first failure (SUCCESS/FAILED banner style of zpt-test.sh).
#
#   local-compute/test-dns.sh
#
# Sections:
#   1. fixture sanity   — zpr-dns registered with its pinned address
#   2. resolution       — AAAA answer, resolv.conf path, NODATA/NXDOMAIN shapes
#   3. liveness         — stop web's adapter -> NXDOMAIN; restart -> resolves
#   4. negative controls
#      (a) hot-install a policy without `Allow zpr-dns to access vs-admin.`
#          -> SERVFAIL (never NXDOMAIN) + a recorded deny to [fd5a:5052::1]:8182,
#          then hot-install the original policy back
#      (b) resolve key on GET /admin/visas        -> 403 (least privilege)
#      (c) resolve key on GET /admin/services/web -> 200
#   5. machine names    — webhost.demo resolves via the hosts index, is
#      reachable (curl + ping6), and the unique-id alias resolves to the
#      same address (zipline#55)
#   6. collision        — a second machine claims webhost: first claim wins,
#      the loser records hostname_conflicts, the VS logs the rejection
#   7. precedence       — a machine claims a policy service name (web): the
#      claim is rejected and web.demo still resolves to the service
#   8. invalid name     — Not_A_Label is rejected, never transformed:
#      not-a-label.demo stays NXDOMAIN
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # local-compute/
DEMO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CMDS="$DEMO_DIR/commands"
ADMIN="$DEMO_DIR/zpr-conf/admin"
BIN_DIR="$DEMO_DIR/bin"
CONF_ROOT="$SCRIPT_DIR/conf"

RESOLVER="fd5a:5052:8888::53"
WEB_ADDR="fd5a:5052:8888::80"
VS_ADMIN_URL="https://[fd5a:5052::1]:8182"

# ttl 30 + negative_ttl 10 (Corefile) -> the issue expects liveness within
# ~40 s; the test allows 60 s and reports the observed latency.
LIVENESS_DEADLINE=60

FAILURES=0

banner() { echo; echo "==== $* ===="; }
ok()     { echo "  ok: $*"; }
fail()   { echo "  FAILED: $*" >&2; FAILURES=$((FAILURES + 1)); finish; }

finish() {
  echo
  if [ "$FAILURES" -eq 0 ]; then
    echo "SUCCESS"
    exit 0
  fi
  echo "FAILED"
  exit 1
}

# dig from the client container, against the resolver over the overlay.
# +time=5: on a policy deny the plugin only answers SERVFAIL after its
# 2 s HTTP timeout (the denied packets are silently dropped), so dig must
# wait longer than that or a real SERVFAIL reads as no-reply.
#   cdig <qtype> <name> [extra dig args...]
cdig() {
  local qtype="$1" name="$2"; shift 2
  docker exec client dig @"$RESOLVER" "$qtype" "$name" +time=5 +tries=1 "$@"
}

# DNS rcode of a query, e.g. NOERROR / NXDOMAIN / SERVFAIL. Network-level
# failure (no reply at all) reports NOREPLY.
rcode() {
  local out
  out="$(cdig "$1" "$2")" || { echo NOREPLY; return; }
  echo "$out" | sed -n 's/.*status: \([A-Z]*\).*/\1/p' | head -1
}

# Poll until `rcode <qtype> <name>` equals $3, up to $4 seconds.
# Prints the elapsed seconds on success; returns 1 on deadline.
wait_rcode() {
  local qtype="$1" name="$2" want="$3" deadline="$4"
  local start elapsed got
  start=$(date +%s)
  while :; do
    got="$(rcode "$qtype" "$name")"
    elapsed=$(( $(date +%s) - start ))
    if [ "$got" = "$want" ]; then echo "$elapsed"; return 0; fi
    if [ "$elapsed" -ge "$deadline" ]; then
      echo "  last rcode: $got after ${elapsed}s (wanted $want)" >&2
      return 1
    fi
    sleep 2
  done
}

# HTTP status of a curl from the dns container using the resolve key.
resolve_key_status() {  # $1 = URL path, e.g. /admin/visas
  docker exec dns sh -c \
    "curl -s -o /dev/null -w '%{http_code}' \
       --cacert /conf/include/admin-tls-cert.pem \
       -H \"X-API-Key: \$(cat /conf/vs-resolve.key)\" \
       '$VS_ADMIN_URL$1'"
}

# --- machine-name helpers (sections 6-8, zipline#55) ------------------------

MACHINES_SRC="$ADMIN/machines.json"          # committed original
MACHINES_LIVE="$CONF_ROOT/vs/machines.json"  # what the VS file store reads
VS_LOG="$SCRIPT_DIR/logs/vs.log"

# The client actor's ZPR address, discovered by CN. Unlike web/dns, the client
# has no pinned service address: the VS assigns its actor address at connect,
# so it cannot be hardcoded.
client_addr() {
  "$CMDS/demo-vs-admin" actors 2>/dev/null | tr -d ' \n' \
    | sed -n 's/.*{"zpr_addr":"\([^"]*\)","cn":"alice"}.*/\1/p'
}

# Force the VS to re-read the machines file and reconcile (the vs-admin
# `services --flush` subcommand drives DELETE /admin/services/machines/cache).
# The wrapper pipes through jq, which masks vs-admin's exit code, so callers
# assert on observed effects (poll helpers below), not on this return value.
flush_machines() {
  "$CMDS/demo-vs-admin" services --id machines --flush >/dev/null 2>&1
}

# The client actor's hostname_conflicts JSON array, as a compact one-liner
# (e.g. '"webhost"' or empty). Rewritten by the VS on every claim attempt.
client_conflicts() {
  "$CMDS/demo-vs-admin" actors -a "$CLIENT_ADDR" 2>/dev/null \
    | tr -d ' \n' | sed -n 's/.*"hostname_conflicts":\[\([^]]*\)\].*/\1/p'
}

# Section-6 prologue, called once before the controls: resolve the client's
# actor address. Failing here beats failing obscurely inside wait_conflict.
require_client_addr() {
  CLIENT_ADDR="$(client_addr)"
  [ -n "$CLIENT_ADDR" ] \
    || fail "could not discover the client (cn=alice) actor address"
  ok "client (cn=alice) actor address: $CLIENT_ADDR"
}

# Poll until client_conflicts contains ($3=yes) / no longer contains ($3=no)
# the name $1, up to $2 seconds. The reconcile after a flush is asynchronous.
wait_conflict() {
  local name="$1" deadline="$2" want="$3"
  local start elapsed got
  start=$(date +%s)
  while :; do
    got="$(client_conflicts)"
    case "$want" in
      yes) echo "$got" | grep -q "\"$name\"" && return 0 ;;
      no)  echo "$got" | grep -q "\"$name\"" || return 0 ;;
    esac
    elapsed=$(( $(date +%s) - start ))
    if [ "$elapsed" -ge "$deadline" ]; then
      echo "  last hostname_conflicts: [${got:-}] after ${elapsed}s (wanted $name: $want)" >&2
      return 1
    fi
    sleep 2
  done
}

# `hosts <name>` -> zpr_addr, empty when unresolved.
host_zpr_addr() {
  "$CMDS/demo-vs-admin" hosts "$1" 2>/dev/null \
    | sed -n 's/.*"zpr_addr": "\([^"]*\)".*/\1/p' | head -1
}

# Restore the committed machines.json, flush, and wait for the claim state to
# settle back to the happy path (client conflict-free, webhost held by web).
restore_machines() {
  cp "$MACHINES_SRC" "$MACHINES_LIVE"
  flush_machines
  wait_conflict "$1" 30 no \
    || fail "hostname_conflicts still lists $1 after restoring machines.json"
  [ "$(host_zpr_addr webhost)" = "$WEB_ADDR" ] \
    || fail "hosts webhost no longer $WEB_ADDR after restoring machines.json"
  ok "machines.json restored: conflicts clear, webhost -> $WEB_ADDR"
}

# ---------------------------------------------------------------------------
banner "1. fixture sanity: zpr-dns is registered with its pinned address"

# The dns adapter registers its provider record moments after deploy returns;
# poll rather than racing it.
got_addr=""
for _ in $(seq 1 15); do
  got_addr="$("$CMDS/demo-vs-admin" services --id zpr-dns 2>/dev/null | sed -n 's/.*"zpr_addr": "\([^"]*\)".*/\1/p' | head -1)"
  [ "$got_addr" = "$RESOLVER" ] && break
  sleep 2
done
[ "$got_addr" = "$RESOLVER" ] \
  && ok "zpr-dns zpr_addr == $RESOLVER" \
  || fail "zpr-dns zpr_addr is '${got_addr:-<none>}', wanted $RESOLVER"

# ---------------------------------------------------------------------------
banner "2. resolution: AAAA, resolv.conf path, NODATA and NXDOMAIN shapes"

# The resolver and client adapters may still be visa-handshaking right after
# deploy; allow the first query a short settle window.
if t=$(wait_rcode AAAA web.demo NOERROR 30); then
  ok "AAAA web.demo -> NOERROR (after ${t}s)"
else
  fail "AAAA web.demo did not reach NOERROR within 30s"
fi

answer="$(cdig AAAA web.demo +short | tr -d '[:space:]')"
[ "$answer" = "$WEB_ADDR" ] \
  && ok "AAAA web.demo -> $WEB_ADDR" \
  || fail "AAAA web.demo answered '${answer:-<none>}', wanted $WEB_ADDR"

# resolv.conf path: plain hostname, no @server (entrypoint-client.sh pointed
# /etc/resolv.conf at the resolver).
if docker exec client curl -fsS --max-time 10 http://web.demo/ >/dev/null; then
  ok "curl http://web.demo (via /etc/resolv.conf) -> 200"
else
  fail "curl http://web.demo failed (resolv.conf path)"
fi

# A for an existing name: NODATA (NOERROR, zero answers) — ZPR addrs are v6 only.
a_out="$(cdig A web.demo)"
if echo "$a_out" | grep -q 'status: NOERROR' && echo "$a_out" | grep -q 'ANSWER: 0'; then
  ok "A web.demo -> NODATA (NOERROR, 0 answers)"
else
  fail "A web.demo is not NODATA: $(echo "$a_out" | grep 'status:\|ANSWER:')"
fi

rc="$(rcode AAAA no-such-service.demo)"
[ "$rc" = "NXDOMAIN" ] \
  && ok "AAAA no-such-service.demo -> NXDOMAIN" \
  || fail "AAAA no-such-service.demo -> $rc, wanted NXDOMAIN"

rc="$(rcode AAAA a.b.demo)"
[ "$rc" = "NXDOMAIN" ] \
  && ok "AAAA a.b.demo (two labels) -> NXDOMAIN" \
  || fail "AAAA a.b.demo -> $rc, wanted NXDOMAIN"

# ---------------------------------------------------------------------------
banner "3. liveness: stop web's adapter -> NXDOMAIN; restart -> resolves"

"$CMDS/demo-stop-ph" web || fail "demo-stop-ph web failed"

if t=$(wait_rcode AAAA web.demo NXDOMAIN "$LIVENESS_DEADLINE"); then
  ok "web.demo -> NXDOMAIN ${t}s after stopping web's adapter (deadline ${LIVENESS_DEADLINE}s)"
  echo "LIVENESS_LATENCY_DOWN=${t}s"
else
  fail "web.demo still resolving ${LIVENESS_DEADLINE}s after adapter stop"
fi

"$CMDS/demo-restart-ph" web || fail "demo-restart-ph web failed"

if t=$(wait_rcode AAAA web.demo NOERROR "$LIVENESS_DEADLINE"); then
  ok "web.demo resolves again ${t}s after adapter restart"
  echo "LIVENESS_LATENCY_UP=${t}s"
else
  fail "web.demo did not resolve within ${LIVENESS_DEADLINE}s of adapter restart"
fi

# ---------------------------------------------------------------------------
banner "4a. policy deny: hot-install a policy without the resolver's allow"

# Variant ZPL: same policy minus `Allow zpr-dns to access vs-admin.` — compiled
# against the same (already rendered) .zplc config, then hot-installed via the
# vs-admin install subcommand (no VS restart, no --clear-state).
[ -f "$ADMIN/dns-demo.zplc" ] || fail "no rendered $ADMIN/dns-demo.zplc — run deploy-docker.sh first"
grep -v '^Allow zpr-dns to access vs-admin\.' "$ADMIN/dns-demo.zpl" > "$ADMIN/dns-demo-novsadmin.zpl"
grep -q 'Allow zpr-dns' "$ADMIN/dns-demo-novsadmin.zpl" \
  && fail "variant ZPL still contains the zpr-dns allow"

( cd "$ADMIN" && "$BIN_DIR/zplc" --config dns-demo.zplc dns-demo-novsadmin.zpl ) \
  || fail "zplc failed on the variant policy"
mv "$ADMIN/dns-demo-novsadmin.bin2" "$CONF_ROOT/vs/dns-demo-novsadmin.bin2"
rm -f "$ADMIN/dns-demo-novsadmin.zpl"

"$CMDS/demo-vs-admin" install /conf/dns-demo-novsadmin.bin2 >/dev/null \
  || fail "vs-admin install (variant policy) failed"
ok "variant policy hot-installed"

# The resolver loses its visa to vs-admin; its VS lookups now fail, which must
# surface as SERVFAIL (infrastructure failure), never NXDOMAIN. The positive
# cache may serve web.demo for up to ttl seconds first.
if t=$(wait_rcode AAAA web.demo SERVFAIL "$LIVENESS_DEADLINE"); then
  ok "web.demo -> SERVFAIL ${t}s after policy swap"
else
  fail "web.demo never went SERVFAIL after removing the resolver's allow"
fi

rc="$(rcode AAAA web.demo)"
[ "$rc" != "NXDOMAIN" ] \
  && ok "deny is SERVFAIL, not NXDOMAIN" \
  || fail "policy deny surfaced as NXDOMAIN — clients would cache 'does not exist'"

denies="$("$CMDS/demo-vs-admin" visas --denies --last 2m 2>/dev/null)"
if echo "$denies" | grep -q '8182' && echo "$denies" | grep -q 'fd5a:5052::1'; then
  ok "demo-vs-admin visas --denies shows the resolver denied to [fd5a:5052::1]:8182"
else
  fail "no recorded deny to [fd5a:5052::1]:8182 in: $(echo "$denies" | head -20)"
fi

# Restore the original policy (also a hot install) and prove recovery.
"$CMDS/demo-vs-admin" install /conf/dns-demo.bin2 >/dev/null \
  || fail "vs-admin install (restore original policy) failed"

if t=$(wait_rcode AAAA web.demo NOERROR "$LIVENESS_DEADLINE"); then
  ok "web.demo resolves again ${t}s after restoring the policy"
else
  fail "web.demo did not recover within ${LIVENESS_DEADLINE}s of policy restore"
fi

# ---------------------------------------------------------------------------
banner "4b/4c. least privilege: the resolve key on the admin API"

code="$(resolve_key_status /admin/visas)"
[ "$code" = "403" ] \
  && ok "resolve key on GET /admin/visas -> 403" \
  || fail "resolve key on GET /admin/visas -> ${code:-<none>}, wanted 403"

code="$(resolve_key_status /admin/services/web)"
[ "$code" = "200" ] \
  && ok "resolve key on GET /admin/services/web -> 200" \
  || fail "resolve key on GET /admin/services/web -> ${code:-<none>}, wanted 200"

# ---------------------------------------------------------------------------
banner "5. machine names: webhost resolves, reachable, alias (zipline#55)"

# The hosts index: the web machine's trusted-service hostname claim, resolved
# through the admin API (GET /admin/hosts/webhost).
host_addr="$("$CMDS/demo-vs-admin" hosts webhost 2>/dev/null | sed -n 's/.*"zpr_addr": "\([^"]*\)".*/\1/p' | head -1)"
[ "$host_addr" = "$WEB_ADDR" ] \
  && ok "hosts webhost -> zpr_addr == $WEB_ADDR" \
  || fail "hosts webhost -> '${host_addr:-<none>}', wanted $WEB_ADDR"

# DNS: the machine name resolves from the client, same path as a service name.
if t=$(wait_rcode AAAA webhost.demo NOERROR 30); then
  ok "AAAA webhost.demo -> NOERROR (after ${t}s)"
else
  fail "AAAA webhost.demo did not reach NOERROR within 30s"
fi

answer="$(cdig AAAA webhost.demo +short | tr -d '[:space:]')"
[ "$answer" = "$WEB_ADDR" ] \
  && ok "AAAA webhost.demo -> $WEB_ADDR" \
  || fail "AAAA webhost.demo answered '${answer:-<none>}', wanted $WEB_ADDR"

# Reachability: a hostname names, policy still authorizes. http is already
# allowed; ping6 needs the ICMP6 ping service this issue adds.
if docker exec client curl -fsS --max-time 10 http://webhost.demo/ >/dev/null; then
  ok "curl http://webhost.demo (via /etc/resolv.conf) -> 200"
else
  fail "curl http://webhost.demo failed (resolv.conf path)"
fi

# First ICMP packets can be dropped while the visa is negotiated: retry
# single-packet pings for up to ~20 s rather than trusting the first one.
ping_ok=""
for _ in $(seq 1 10); do
  if docker exec client ping6 -c 1 -W 2 webhost.demo >/dev/null 2>&1; then
    ping_ok=1; break
  fi
  sleep 2
done
[ -n "$ping_ok" ] \
  && ok "ping6 -c1 webhost.demo succeeds" \
  || fail "ping6 -c1 webhost.demo failed (no reply within retries)"

# Alias: the machine's unique-id value resolves to the same address as its
# friendly name.
alias_answer="$(cdig AAAA m-7f3a2b.demo +short | tr -d '[:space:]')"
[ -n "$alias_answer" ] && [ "$alias_answer" = "$answer" ] \
  && ok "AAAA m-7f3a2b.demo -> same address as webhost.demo ($alias_answer)" \
  || fail "AAAA m-7f3a2b.demo answered '${alias_answer:-<none>}', wanted '$answer'"

# ---------------------------------------------------------------------------
banner "6. collision control: a second machine claims webhost (first claim wins)"

require_client_addr
vs_log_mark=$(wc -l < "$VS_LOG")

# The client's machine also claims webhost. The web machine claimed it first,
# so the claim must be refused, recorded, and logged — never reassigned.
cat > "$MACHINES_LIVE" <<'EOF'
{
  "device.zpr.adapter.cn": {
    "web.demo": { "hostnames": ["webhost", "m-7f3a2b"] },
    "alice": { "hostnames": ["alicebox", "webhost"] }
  }
}
EOF
flush_machines

if wait_conflict webhost 30 yes; then
  ok "actors get $CLIENT_ADDR lists webhost under hostname_conflicts"
else
  fail "webhost never appeared in the client's hostname_conflicts"
fi

got_addr="$(host_zpr_addr webhost)"
[ "$got_addr" = "$WEB_ADDR" ] \
  && ok "hosts webhost still -> $WEB_ADDR (first claim wins)" \
  || fail "hosts webhost -> '${got_addr:-<none>}' after collision, wanted $WEB_ADDR"

if tail -n "+$((vs_log_mark + 1))" "$VS_LOG" | grep -q 'claim rejected, name held by another actor'; then
  ok "VS log carries the rejection at error! (name held by another actor)"
else
  fail "no 'claim rejected, name held by another actor' in VS log after mark $vs_log_mark"
fi

restore_machines webhost

# ---------------------------------------------------------------------------
banner "7. precedence control: a machine claims a policy service name (web)"

vs_log_mark=$(wc -l < "$VS_LOG")

cat > "$MACHINES_LIVE" <<'EOF'
{
  "device.zpr.adapter.cn": {
    "web.demo": { "hostnames": ["webhost", "m-7f3a2b"] },
    "alice": { "hostnames": ["alicebox", "web"] }
  }
}
EOF
flush_machines

if wait_conflict web 30 yes; then
  ok "actors get $CLIENT_ADDR lists web under hostname_conflicts (policy name wins)"
else
  fail "web never appeared in the client's hostname_conflicts"
fi

if tail -n "+$((vs_log_mark + 1))" "$VS_LOG" | grep -q 'claim rejected, name is a policy service'; then
  ok "VS log carries the rejection at error! (name is a policy service)"
else
  fail "no 'claim rejected, name is a policy service' in VS log after mark $vs_log_mark"
fi

answer="$(cdig AAAA web.demo +short | tr -d '[:space:]')"
[ "$answer" = "$WEB_ADDR" ] \
  && ok "AAAA web.demo still -> $WEB_ADDR (service provider unaffected)" \
  || fail "AAAA web.demo answered '${answer:-<none>}' after service-name claim, wanted $WEB_ADDR"

restore_machines web

# ---------------------------------------------------------------------------
banner "8. invalid-name control: Not_A_Label is rejected, never transformed"

vs_log_mark=$(wc -l < "$VS_LOG")

cat > "$MACHINES_LIVE" <<'EOF'
{
  "device.zpr.adapter.cn": {
    "web.demo": { "hostnames": ["webhost", "m-7f3a2b"] },
    "alice": { "hostnames": ["alicebox", "Not_A_Label"] }
  }
}
EOF
flush_machines

# Invalid values are rejected before the claim pass, so they never reach
# hostname_conflicts — the observable trace is the VS error log. Poll it.
log_ok=""
for _ in $(seq 1 15); do
  if tail -n "+$((vs_log_mark + 1))" "$VS_LOG" | grep -q 'invalid device.hostname value rejected'; then
    log_ok=1; break
  fi
  sleep 2
done
[ -n "$log_ok" ] \
  && ok "VS log carries the rejection at error! (not a lowercase DNS label)" \
  || fail "no 'invalid device.hostname value rejected' in VS log after mark $vs_log_mark"

# No transformed form may resolve: the claim side stores values untransformed
# and the lookup queries the same way, so the lowercased/dashed spelling must
# be NXDOMAIN — that is what proves no mangling happened.
rc="$(rcode AAAA not-a-label.demo)"
[ "$rc" = "NXDOMAIN" ] \
  && ok "AAAA not-a-label.demo -> NXDOMAIN (no transformed form resolves)" \
  || fail "AAAA not-a-label.demo -> $rc, wanted NXDOMAIN"

got_addr="$(host_zpr_addr Not_A_Label)"
[ -z "$got_addr" ] \
  && ok "hosts Not_A_Label does not resolve" \
  || fail "hosts Not_A_Label resolved to '$got_addr', wanted nothing"

restore_machines no-such-conflict

finish
