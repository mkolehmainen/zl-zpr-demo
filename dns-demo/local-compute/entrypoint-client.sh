#!/bin/sh
# client: bring up tun9 (matches adapter-client-conf.toml zpr_addr), then idle.
# Unlike multinode-demo's host-side alice/bob, the client here is containerized
# with its own tun + zpr_addr so it can curl (and later dig) over the overlay.
# The `ph adapter` process is launched by deploy-docker.sh via `docker exec`.
set -e

mkdir -p /var/run/zpr   # ph control socket lives here

ip tuntap add name tun9 mode tun multi_queue
ip link set tun9 mtu 1400
ip addr add fd5a:5052:8888::13/32 dev tun9
ip link set tun9 up

# Point DNS at the ZPR resolver so `curl http://web.demo` resolves over the
# overlay. Docker bind-mounts /etc/resolv.conf, so rewrite it in place
# (a rename would fail on the mount); the container loses non-overlay DNS,
# which is fine — the demo client only speaks to ZPR services.
echo "nameserver fd5a:5052:8888::53" > /etc/resolv.conf

exec sleep infinity
