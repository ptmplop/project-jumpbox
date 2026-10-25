#!/bin/bash

[[ -t 1 ]] && clear

# Trap and cleanup on ctrl-c
# trap ctrlC INT
trap ctrlC INT TERM QUIT

source /config/inc.sh
touch /var/log/openvpn.log

[[ -z "$DCN" ]] && echo "You must specify a valid container name" && exit 1
[[ -z "$PORT" ]] && echo "You must specify a valid port" && exit 1
[[ -z "$OVPNFILE" ]] && echo "You must specify a valid ovpn file" && exit 1

# The resolvers the container started with (docker's), which work without the
# tunnel. pinRemotes looks the servers up through them: /etc/resolv.conf gets
# the pushed DNS on every connect, often only reachable through the tunnel.
mkdir -p /run/jumpbox
cp /etc/resolv.conf /run/jumpbox/underlay-resolv.conf

echo -n -e " ${arrow} Starting...\n"
echo -n -e " ${arrow} Connect using: ${cyan}$jb${white}\n"
echo -n -e " ${arrow} Connecting the tunnel, this can take a while...\n"

tunDevice    # - Configure tun device
killSwitch   # - Enable the VPN Killswitch
connectOvpn  # - Connect the tunnel, sockd will start as part of the process
sshdStart    # - Start the sshd service
connCheck    # - Start connectivity checks
custom       # - If a custom config exists, run it
waitConn     # - Wait for connectivity over the tunnel
display      # - Keep alive and display outputs

# display only comes back if it failed. Put the terminal back the way it was
# and throw away anything typed into the pane while the frame was up (none of
# it was echoed) before falling back to a shell.
[[ -n $ttyMode ]] && stty "$ttyMode" 2>/dev/null
printf '\e[?25h\e[?7h'
tput cnorm 2>/dev/null; tput smam 2>/dev/null
while read -rs -t 0.1 -n 1000 _; do :; done

exec /bin/bash -l