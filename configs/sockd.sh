#!/bin/sh
pidof sockd $>/dev/null || sockd -D -f /etc/sockd.conf &>/var/log/sockd.log &
