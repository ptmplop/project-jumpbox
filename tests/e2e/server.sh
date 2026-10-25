#!/bin/bash
# OpenVPN test server: server.sh <n> [sso]
#   subnet 10.89.<n>.0/24, NAT out of eth0 so the client's tunnel reaches the
#   internet (connCheck pings 8.8.8.8, the display looks up the public IP).
#   sso: management-client-auth on 127.0.0.1:7505, answered by
#   sso-responder.sh (start it before the client connects).
n=${1:-0}
mkdir -p /dev/net; [[ -c /dev/net/tun ]] || mknod /dev/net/tun c 10 200
iptables -t nat -A POSTROUTING -s 10.89.$n.0/24 -o eth0 -j MASQUERADE
mgmt=()
[[ $2 == sso ]] && mgmt=(--management 127.0.0.1 7505 --management-client-auth --auth-user-pass-optional)
exec openvpn --dev tun --proto udp --port 1194 --topology subnet --server 10.89.$n.0 255.255.255.0 \
  --ca /t/e2e/pki/ca.crt --cert /t/e2e/pki/server.crt --key /t/e2e/pki/server.key --dh none \
  --push "redirect-gateway def1" --push "dhcp-option DNS 1.1.1.1" --keepalive 2 10 \
  --data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305 --verb 3 --log /tmp/server.log \
  --status /tmp/server-status.log 2 --script-security 2 --up /t/e2e/server-up.sh "${mgmt[@]}"
