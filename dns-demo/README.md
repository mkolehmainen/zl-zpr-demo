# dns-demo

A containerized single-node ZPR environment for the DNS integration
(master plan: `zl-zpr-dev-context/docs/plans/2026-09-15-dns-integration.md`).
This fixture stands up node + visa service + web service + client + a CoreDNS
resolver (`dns`), with a policy governing both DNS hops: a ZPR client `dig`s a
ZPL service name (`web.demo`) over the overlay and gets the current provider's
address from the VS admin API.

Copied and pruned from `multinode-demo/`: docker technique only, none of its
OCI/OpenTofu parts.

## Contents

| Path | What |
|---|---|
| `Makefile` | builds `ph`, `vs`, `vs-admin`, `vsapikey`, `zplc`, `zpdump`, `coredns` into `bin/` |
| `Dockerfile` | ubuntu:24.04 + valkey + dnsutils + the ZPR binaries (image `zpr-dns-demo`) |
| `docker-compose.yml` | `node` (172.30.1.10), `vs` (.11), `web` (.12), `client` (.13), `dns` (.14) |
| `local-compute/deploy-docker.sh` | render templates → mint API keys → compile policy → compose up → launch ZPR processes |
| `local-compute/entrypoint-*.sh` | per-container tun9 + static ZPR address setup |
| `local-compute/test-dns.sh` | the end-to-end DNS acceptance test (see below) |
| `zpr-conf/admin/` | `dns-demo.zpl`, `dns-demo.zplc.template`, `attrfile.json`, `machines.json` (policy) |
| `zpr-conf/confs/` | node + adapter config templates, `Corefile` |
| `zpr-conf/include/` | demo PKI (freshly generated, see below) |
| `commands/` | `demo-vs-admin`, `demo-status`, `demo-shell`, `demo-check-ph`, `demo-stop-ph`, `demo-restart-ph`, `lib.sh` |
| `tools/` | `regen-banner.sh` (web's live banner page) |

## Overlay addresses

| Who | ZPR address |
|---|---|
| visa service | `fd5a:5052::1` (well-known) |
| node | `fd5a:5052:90de::10` (`90de` = "node": N-ine + ode) |
| web service | `fd5a:5052:8888::80` (pinned service addr) |
| resolver | `fd5a:5052:8888::53` (pinned service addr) |
| client (alice) | `fd5a:5052:8888::13` |

`fd5a:5052:90de::/64` is reserved for nodes — nothing else may use it.

## Build

Sibling checkouts of `zpr-core`, `zpr-visaservice`, `zpr-compiler` and
`zl-zpr-coredns` are required (the Rust toolchain builds the first three in
place; Go ≥ the version in `zl-zpr-coredns/go.mod` builds the resolver):

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

Brings up the five containers, compiles and installs the policy, and launches
`ph node`, `vs`, and the vs/web/client/dns adapters under tmux (logs land in
`local-compute/logs/`). CoreDNS itself is the `dns` container's entrypoint.

Verify:

```sh
commands/demo-status                            # every ph up
commands/demo-vs-admin services                 # lists vs-admin, web, zpr-dns
commands/demo-vs-admin services --id vs-admin   # zpr_addr == "fd5a:5052::1"
commands/demo-vs-admin services --id zpr-dns    # zpr_addr == "fd5a:5052:8888::53"
docker exec client curl -fsS 'http://[fd5a:5052:8888::80]/'   # overlay works
```

Teardown:

```sh
docker compose -f docker-compose.yml down
```

## DNS walk-through

Everything below is what `local-compute/test-dns.sh` asserts unattended; run
it after deploy for the full end-to-end check (prints `SUCCESS` and exits 0).

**Resolution.** The `dns` container runs CoreDNS with the `zpr` plugin
(zone `demo.`, see `zpr-conf/confs/Corefile`). The plugin answers
`AAAA <service>.demo` by calling `GET /admin/services/<service>` on the VS
admin API with a least-privilege `resolve` key, over the overlay — both the
client→resolver and resolver→VS hops are policy-governed visas.

```sh
docker exec client dig @fd5a:5052:8888::53 AAAA web.demo +short
# fd5a:5052:8888::80

# entrypoint-client.sh points /etc/resolv.conf at the resolver, so plain
# names work too:
docker exec client curl -fsS http://web.demo/
```

Shape of the negative answers: `A web.demo` is NODATA (NOERROR, no answer —
ZPR addresses are IPv6-only), an unknown service and a two-label name
(`a.b.demo`) are NXDOMAIN.

**Liveness.** Resolution tracks the *current* provider:

```sh
commands/demo-stop-ph web        # kill web's adapter
# within ttl+negative_ttl (~40 s): dig web.demo -> NXDOMAIN
commands/demo-restart-ph web     # relaunch it
# dig web.demo -> fd5a:5052:8888::80 again
```

**Policy deny.** Removing `Allow zpr-dns to access vs-admin.` and
hot-installing the variant (`commands/demo-vs-admin install <bundle.bin2>`,
no VS restart) cuts the resolver off from the VS: `dig` returns **SERVFAIL**
(never NXDOMAIN — clients must not cache "does not exist" because the
resolver lost its visa), and `commands/demo-vs-admin visas --denies` shows
the resolver's deny to `[fd5a:5052::1]:8182`. Hot-installing the original
bundle restores resolution.

**Least privilege.** The resolver's `resolve` key only reaches
`GET /admin/services*` (and `GET /admin/hosts/{name}`, below):

```sh
docker exec dns sh -c 'curl -s -o /dev/null -w "%{http_code}" \
  --cacert /conf/include/admin-tls-cert.pem \
  -H "X-API-Key: $(cat /conf/vs-resolve.key)" \
  https://[fd5a:5052::1]:8182/admin/visas'          # 403
# same with /admin/services/web                      # 200
```

## Machine names (zipline#55)

Services are not the only things with names: a **machine** (an adapter's
device) can be named too, by a trusted service acting as the naming
authority. `zpr-conf/admin/machines.json` is that authority's data here —
the `machines` file store vends it as the `device.hostname` attribute:

```toml
[trusted_services.machines]
api = "file"
returns_attributes = ["hostnames -> device.hostname{}"]
expiration_seconds = 3600
```

```json
{ "device.zpr.adapter.cn": { "web.demo": { "hostnames": ["webhost", "m-7f3a2b"] },
                             "alice":    { "hostnames": ["alicebox"] } } }
```

The key is the machine's CN — its cryptographic identity — and the values are
the names it answers to; the two are deliberately unrelated strings. The
naming authority returns a unique-by-construction id (`m-7f3a2b`) alongside
the friendly name, so a lost alias never costs reachability. Claimed names
land in the VS hosts index (`GET /admin/hosts/{name}`), which the resolver
consults when a name is not a service — services and hosts share the one
`.demo` namespace, services first.

```sh
commands/demo-vs-admin hosts webhost            # zpr_addr == fd5a:5052:8888::80
docker exec client dig AAAA webhost.demo +short  # fd5a:5052:8888::80
docker exec client curl -fsS http://webhost.demo/
docker exec client ping6 -c1 webhost.demo
```

That `ping6` works only because the policy declares it: a hostname **names**,
it does not authorize. The demo adds an ICMP6 `ping` protocol/service
(provided by `web.demo`) and
`Allow access:all users to access ping on hostname: devices.` — the
`hostname:` reference is also what keeps the `machines` store woven (see
Policy notes).

**Negative controls** (`test-dns.sh` sections 6–8). Each mutates the live
`local-compute/conf/vs/machines.json`, forces a re-read with
`commands/demo-vs-admin services --id machines --flush` (the admin API's
`DELETE /admin/services/machines/cache`), and restores the original after:

- **Collision** — a second machine also claims `webhost`: first claim wins,
  `hosts webhost` still answers the web machine, the loser's refused claim is
  listed in its `hostname_conflicts` (`actors -a <addr>`), and the VS logs the
  rejection at `error!`. Never reassigned, never renamed.
- **Precedence** — a machine claims `web`, a declared policy service name:
  rejected the same way, and `web.demo` keeps resolving to the service's
  provider. Policy names always win.
- **Invalid name** — `Not_A_Label` is not a lowercase DNS label: rejected and
  never transformed, so no mangled spelling resolves — `not-a-label.demo`
  stays NXDOMAIN.

## Policy notes

The ZPL qualifies its user rules with `access:all` (alice's value in
`attrfile.json`) rather than a bare `Allow users ...`: an unreferenced `file`
trusted service is pruned at compile time, so without an attribute reference
the attrfile store never loads, no `user.*` attribute is ever vended, and a
bare `users` condition can never match. `attrfile.json` is keyed by
`device.zpr.adapter.cn` (the file store's identity-key/value JSON shape).

The `machines` store is woven the same way: the `ping` rule's object-side
device spec `on hostname: devices` (key-presence on `device.hostname`) is the
reference that keeps it from being pruned. `machines.json` uses the same
identity-key/value JSON shape.

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
