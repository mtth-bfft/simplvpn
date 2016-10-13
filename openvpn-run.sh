#!/bin/bash

set -euo pipefail

# Setup for TUN interfaces
[ -d /dev/net ] || mkdir -p /dev/net
[ -c /dev/net/tun ] || mknod /dev/net/tun c 10 200

# Setup masquerading for all clients
iptables -t nat -F
iptables -t nat -A POSTROUTING -j MASQUERADE

openvpn --config /etc/openvpn/server.conf
