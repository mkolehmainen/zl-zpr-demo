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

exec sleep infinity
