#!/bin/bash

source /config/inc.sh

# Update the DNS options
setdns

# Run Dante Socks5 proxy
pidof sockd $>/dev/null || sockd -D -f /etc/sockd.conf &>/var/log/sockd.log &

# Store the connect/reconnect time for the display
date +%s > /tmp/last
