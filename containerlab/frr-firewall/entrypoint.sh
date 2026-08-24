#!/bin/bash
set -e
# This box exists to forward between two tenants that have no other path to
# each other, so forwarding is the point, not an afterthought.
sysctl -w net.ipv4.ip_forward=1
mkdir -p /var/run/frr /var/log/frr
chown -R frr:frr /var/run/frr /var/log/frr
# A stale socket directory from a previous container life makes zebra refuse to
# start, with a confusing bind error.
rm -rf /var/tmp/frr
nft -f /etc/nftables.conf
exec /usr/lib/frr/watchfrr zebra bgpd
