# Multi-node demo: ZPR configuration

Both nodes and all adapters have RSA keys listed in policy.

The CA key (`include/auth-ca.key`) has passphrase `secret`.


host: "node 0"
- lives: OCI 
- zpr addr: `fd5a:5052:90de::10`
- CN: `node0.demo`

host: "web 0"
- lives: OCI
- zpr addr: `fd5a:5052:8888::8` (granted by the `addresses` trusted service, see `admin/addresses.json`)
- CN: `ociweb.demo`

host: "alice"  # previously called "admin"
- lives: OCI
- zpr addr: dynamic
- CN: `alice`  # previously called "admin.demo"

host: "vs"
- lives: local
- zpr addr: `fd5a:5052::1`
- CN: `vs.zpr`

host: "node 1"
- lives: local
- zpr addr: `fd5a:5052:90de::11`
- CN: `node1.demo`

host: "web 1"
- lives: local
- zpr addr: `fd5a:5052:8888::9` (granted by the `addresses` trusted service, see `admin/addresses.json`)
- CN: `premweb.demo`

host: "bob"   # previously "client"
- lives: local
- zpr addr: dynamic
- CN: `bob`   # previously "client.demo"

