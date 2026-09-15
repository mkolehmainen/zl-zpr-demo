# dns-demo policy (Contract 4 of docs/plans/2026-09-15-dns-integration.md).
#
# http://web.demo (resolvable as web.<zone> once I1 adds the resolver)
Define web as a service.

# The CoreDNS resolver (provider added by I1; declared now so the policy
# shape — a service as the *subject* of an Allow — is proved by this issue).
Define zpr-dns as a service.

# The visa service's admin API, provided by the VS adapter itself.
Define vs-admin as a service.

Allow users to access web.

Allow users to access zpr-dns.

Allow zpr-dns to access vs-admin.
