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

finish
