#!/usr/bin/env bash
# Shared helpers for the demo-* operator commands. SOURCED, not executed.
#
# One name table for the ZPR `ph` processes in the dns-demo docker env, plus a
# single docker dispatch point (`on` / `on_tty`). Everything else in commands/
# is a thin wrapper over these. Copied from multinode-demo's lib.sh, pruned to
# docker-only dispatch: every process here runs in a local container.
#
# Names match the adapter CNs in the policy, so they read the same here and in
# the ph logs.
set -euo pipefail

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "lib.sh is a sourced library; run one of the demo-* commands" >&2
  exit 1
fi

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # dns-demo/
LOGS_DIR="$DEMO_DIR/local-compute/logs"

# --- the name table ---------------------------------------------------------
# TARGET  : container name
# SESSION : tmux session holding that ph (also the log basename)
# LOG     : path on THIS host (mounted volume)
# LAUNCH  : the command the deploy script used
# WD      : cwd for the tmux session
NAMES=(node vs web client)

declare -A TARGET=(
  [node]=node [vs]=vs [web]=web [client]=client
)
declare -A SESSION=(
  [node]=node [vs]=vs-adapter [web]=web-adapter [client]=client-adapter
)
declare -A LOG=(
  [node]="$LOGS_DIR/node.log"
  [vs]="$LOGS_DIR/vs-adapter.log"
  [web]="$LOGS_DIR/web-adapter.log"
  [client]="$LOGS_DIR/client-adapter.log"
)
declare -A LAUNCH=(
  [node]='/app/bin/ph node -c node-conf.toml'
  [vs]='/app/bin/ph adapter -c adapter-vs-conf.toml'
  [web]='/app/bin/ph adapter -c adapter-web-conf.toml'
  [client]='/app/bin/ph adapter -c adapter-client-conf.toml'
)
declare -A WD=(
  [node]=/conf [vs]=/conf [web]=/conf [client]=/conf
)

# resolve NAME -- sets N_* for the caller, or lists the valid names and exits 2.
resolve() {
  local n="${1:-}"
  if [ -z "$n" ] || [ -z "${TARGET[$n]:-}" ]; then
    echo "error: unknown name: ${n:-<none>}" >&2
    echo "valid names: ${NAMES[*]}" >&2
    exit 2
  fi
  N_NAME="$n"
  N_TARGET="${TARGET[$n]}"; N_SESSION="${SESSION[$n]}"
  N_LOG="${LOG[$n]}";   N_LAUNCH="${LAUNCH[$n]}"; N_WD="${WD[$n]}"
  # The same log as the container sees it: N_LOG is this host's side of the
  # mounted volume, but a tee inside the container writes /logs/<session>.
  N_TLOG="/logs/$N_SESSION.log"
}

# on NAME cmd... / on_tty NAME cmd... -- the docker dispatch point.
# Args after NAME are joined into one command run under a shell in the container.
on()     { _dispatch "" "$@"; }
on_tty() { _dispatch tty "$@"; }

_dispatch() {  # $1=tty|"" $2=NAME $3...=command
  local tty="$1" name="$2"; shift 2
  resolve "$name"
  docker exec ${tty:+-it} "$N_TARGET" bash -lc "$*"
}

# tail_log NAME <tail-args...> -- logs are tee'd to a host-mounted volume,
# so no docker needed at all.
tail_log() {
  local n="$1"; shift
  resolve "$n"
  [ -f "$N_LOG" ] || { echo "error: no log at $N_LOG — has deploy-docker.sh run?" >&2; exit 1; }
  tail "$@" "$N_LOG"
}
