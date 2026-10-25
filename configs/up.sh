#!/bin/bash

# Includes
source /config/inc.sh

# Set the DNS from push options on start/restart
setdns

# Run Dante Socks5 proxy
./config/sockd.sh

# Store the connect/reconnect time for the display
date +%s > /tmp/last

exit 0
