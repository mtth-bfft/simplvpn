#!/bin/bash

set -euo pipefail

# Check that the user mounted a valid directory in /etc/openvpn/
if ! [ -r /etc/openvpn/server.conf ]; then
    echo "Error: you need to run this container with option" >&2
    echo "       docker run [...] -v /your/config/dir:/etc/openvpn [...]" >&2
    echo "       (with /your/config/dir/ a valid simplvpn-generated" >&2
    echo "       directory. See https://github.com/mtth-bfft/simplvpn )" >&2
    exit 1
fi

# Setup for TUN interfaces
[ -d /dev/net ] || mkdir -p /dev/net
[ -c /dev/net/tun ] || mknod /dev/net/tun c 10 200

# Setup masquerading for all clients
iptables -t nat -F
iptables -t nat -A POSTROUTING -j MASQUERADE

exec openvpn --config /etc/openvpn/server.conf --management 127.0.0.1 8000

