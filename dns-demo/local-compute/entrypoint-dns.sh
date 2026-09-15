#!/bin/sh
# dns: bring up tun9 (matches adapter-dns-conf.toml zpr_addr), then run CoreDNS
# (with the zpr plugin) in the foreground — it keeps the container alive.
# The `ph adapter` process is launched by deploy-docker.sh via `docker exec`
# after the VS is up; the plugin tolerates the adapter coming up later
# (Ready() is the probe, queries SERVFAIL until the overlay path works).
set -e

mkdir -p /var/run/zpr   # ph control socket lives here

ip tuntap add name tun9 mode tun multi_queue
ip link set tun9 mtu 1400
ip addr add fd5a:5052:8888::53/32 dev tun9
ip link set tun9 up

exec /app/bin/coredns -conf /conf/Corefile
