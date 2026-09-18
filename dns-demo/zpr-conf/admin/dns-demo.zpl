# dns-demo policy (Contract 4 of docs/plans/2026-09-15-dns-integration.md).
#
# http://web.demo (resolvable as web.<zone> once I1 adds the resolver)
Define web as a service.

# The CoreDNS resolver (provider added by I1; declared now so the policy
# shape — a service as the *subject* of an Allow — is proved by this issue).
Define zpr-dns as a service.

# The visa service's admin API, provided by the VS adapter itself.
Define vs-admin as a service.

# Deviation from Contract 4's bare `Allow users ...`, found by test: an
# unreferenced `file` trusted service is pruned by the compiler, so with no
# attribute reference anywhere in ZPL the attrfile store never loads, alice
# never receives a user.* attribute, and a bare `users` condition
# (user.zpr.authority presence) can never match. Qualifying with access:all
# (alice's value in attrfile.json) weaves the store — the same shape
# multinode-demo uses (`Allow access:all users to access services.`).
Allow access:all users to access web.

Allow access:all users to access zpr-dns.

Allow zpr-dns to access vs-admin.

# zipline#55: ICMP6 echo to the web machine. The object-side device spec
# references device.hostname (key-presence), which is what weaves the
# `machines` file store into the policy — same deviation as attrfile above:
# an unreferenced `file` trusted service is pruned by the compiler, and the
# hosts index only fills from a woven store. It also states the demo's point:
# you ping a *named* machine.
Define ping as a service.

Allow access:all users to access ping on hostname: devices.
