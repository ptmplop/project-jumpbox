#!/bin/sh

# Update the DNS options
./etc/openvpn/update-resolv-conf.sh $@ &> /var/log/update-resolv-conf.log

# Nasty hack as update-resolv-conf suddenly stopped working in Docker
cat $(for i in $(ls /etc/resolv.conf.*.openresolv); do echo $i; done | head -n 1) > /etc/resolv.conf

# Run Dante Socks5 proxy
pidof sockd $>/dev/null || sockd -D -f /etc/sockd.conf &>/var/log/sockd.log &

# Store the connect/reconnect time for the display
date +%s > /tmp/last
