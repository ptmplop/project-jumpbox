#!/bin/bash

# Trap and cleanup on ctrl-c
trap ctrl_c INT

clear

[[ -z "$DCN" ]] && echo "You must specify a valid container name" && exit 1
[[ -z "$PORT" ]] && echo "You must specify a valid port" && exit 1

# Includes
source /config/inc.sh

# Our colour profiles made easy
BOLD=$(tput bold)
NORMAL=$(tput sgr0)
PURPLE='\033[35m'
GREEN='\033[92m'
RED='\033[31m'

echo -n -e "${GREEN} ➡ Starting...\n"
echo -n -e " ➡ Connect using: $JB\n"
echo -n -e " ➡ Connecting the tunnel, this can take a while...\n"

# -- Begin the setup

tun_device  # - Configure tun device
killswitch  # - Enable the VPN Killswitch

touch /var/log/openvpn.log
[[ -z "$OVPNFILE" ]] && echo "You must specify a valid ovpn file" && exit 1
connect_ovpn # - Connect the tunnel, sockd will start as part of the process

conn_check   # - Start connectivity checks
custom       # - If a custom config exists, run it
wait_conn    # - Wait for connectivy over the tunnel
display      # - Keep alive and display outputs
