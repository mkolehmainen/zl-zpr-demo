#!/bin/sh
# node: bring up tun9 (matches node-conf.toml zpr_addr), then idle.
# The `ph node` process is launched by deploy-docker.sh via `docker exec`.
set -e

mkdir -p /var/run/zpr   # ph control socket lives here

ip tuntap add name tun9 mode tun multi_queue
ip link set tun9 mtu 1400
ip addr add fd5a:5052:90de::10/32 dev tun9   # /32 matches the multinode working config
ip link set tun9 up

exec sleep infinity
