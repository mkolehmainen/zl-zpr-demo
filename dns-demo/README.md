# dns-demo

A containerized single-node ZPR environment for the DNS integration
(master plan: `zl-zpr-dev-context/docs/plans/2026-09-15-dns-integration.md`).
This fixture stands up node + visa service + web service + client, with a
policy that already declares the `zpr-dns` resolver service and the `vs-admin`
service (provided by the VS adapter itself). The CoreDNS resolver container
and the `dig` walk-through are added by the follow-on integration issue (I1).

Copied and pruned from `multinode-demo/`: docker technique only, none of its
OCI/OpenTofu parts.

## Contents

| Path | What |
|---|---|
| `Makefile` | builds `ph`, `vs`, `vs-admin`, `vsapikey`, `zplc`, `zpdump` into `bin/` |
| `Dockerfile` | ubuntu:24.04 + valkey + dnsutils + the ZPR binaries (image `zpr-dns-demo`) |
| `docker-compose.yml` | `node` (172.30.1.10), `vs` (.11), `web` (.12), `client` (.13); `dns` (.14) reserved for I1 |
| `local-compute/deploy-docker.sh` | render templates → mint API key → compile policy → compose up → launch ZPR processes |
| `local-compute/entrypoint-*.sh` | per-container tun9 + static ZPR address setup |
| `zpr-conf/admin/` | `dns-demo.zpl`, `dns-demo.zplc.template`, `attrfile.json` (policy) |
| `zpr-conf/confs/` | node + adapter config templates |
| `zpr-conf/include/` | demo PKI (freshly generated, see below) |
| `commands/` | `demo-vs-admin`, `demo-status`, `demo-shell`, `demo-check-ph`, `lib.sh` |
| `tools/` | `regen-banner.sh` (web's live banner page) |

## Overlay addresses

| Who | ZPR address |
|---|---|
| visa service | `fd5a:5052::1` (well-known) |
| node | `fd5a:5052:90de::10` (`90de` = "node": N-ine + ode) |
| web service | `fd5a:5052:8888::80` (pinned service addr) |
| resolver (I1) | `fd5a:5052:8888::53` (pinned service addr) |
| client (alice) | `fd5a:5052:8888::13` |

`fd5a:5052:90de::/64` is reserved for nodes — nothing else may use it.

## Build

Sibling checkouts of `zpr-core`, `zpr-visaservice` and `zpr-compiler` are
required (the Rust toolchain builds them in place):

```sh
make ZPR_ROOT=/path/to/repos
# renamed checkouts (e.g. zl-zpr-core):
make ZPR_ROOT=/path/to/repos ZPR_REPO_PREFIX='zl-'

docker build -t zpr-dns-demo .
```

## Deploy

```sh
local-compute/deploy-docker.sh
```

Brings up the four containers, compiles and installs the policy, and launches
`ph node`, `vs`, and the vs/web/client adapters under tmux (logs land in
`local-compute/logs/`).

Verify:

```sh
commands/demo-status                            # every ph up
commands/demo-vs-admin services                 # lists vs-admin and web
commands/demo-vs-admin services --id vs-admin   # zpr_addr == "fd5a:5052::1"
commands/demo-vs-admin services --id zpr-dns    # 404 — declared, no provider yet
docker exec client curl -fsS 'http://[fd5a:5052:8888::80]/'   # overlay works
```

Teardown:

```sh
docker compose -f docker-compose.yml down
```

## DNS walk-through

Placeholder — added by I1 together with the `dns` container (CoreDNS with the
`zpr` plugin, resolving `web.demo` via the VS admin API).

## Policy notes

The ZPL qualifies its user rules with `access:all` (alice's value in
`attrfile.json`) rather than a bare `Allow users ...`: an unreferenced `file`
trusted service is pruned at compile time, so without an attribute reference
the attrfile store never loads, no `user.*` attribute is ever vended, and a
bare `users` condition can never match. `attrfile.json` is keyed by
`device.zpr.adapter.cn` (the file store's identity-key/value JSON shape).

## PKI (zpr-conf/include/)

All keys and certs are freshly generated for this demo — nothing is shared
with `multinode-demo`. X25519 identity keys and noise certs come from
`zpr-visaservice/tools/zpr-pki` (CNs: `node.demo`, `vs.zpr`, `web.demo`,
`dns.demo`, `alice`). The admin TLS cert is a plain openssl self-signed RSA
cert carrying `subjectAltName = DNS:vs.zpr, IP:fd5a:5052::1` — required
because Go's TLS verifier (the I1 CoreDNS plugin) ignores CN, and `zpr-pki
gensignedcert` cannot emit a SAN. Regenerate with `tools/regen-pki.sh`.

These are demo credentials for a private, local fixture; they are committed
on purpose, like `multinode-demo`'s.
