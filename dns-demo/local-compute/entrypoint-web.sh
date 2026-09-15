#!/bin/sh
# web: bring up tun9 (matches adapter-web-conf.toml zpr_addr), then run nginx in
# the foreground (keeps the container alive). The `ph adapter` process is launched
# by deploy-docker.sh via `docker exec`.
set -e

mkdir -p /var/run/zpr   # ph control socket lives here

ip tuntap add name tun9 mode tun multi_queue
ip link set tun9 mtu 1400
ip addr add fd5a:5052:8888::80/32 dev tun9
ip link set tun9 up

# Live banner page: rewrite the docroot index every 0.2s (tools/regen-banner.sh,
# mounted at /tools). Backgrounded — nginx stays the exec target, and this dies
# with the container. A failure here is silent; a frozen timestamp on the served
# page is the symptom.
/tools/regen-banner.sh WEB /var/www/html/index.html &

exec nginx -g 'daemon off;'
