#!/bin/bash

[[ -t 1 ]] && clear

# Trap and cleanup on ctrl-c
# trap ctrlC INT
trap ctrlC INT TERM QUIT

source /config/inc.sh
touch /var/log/openvpn.log
# Down until connCheck finds otherwise: after a docker restart these still
# hold how the last run ended, which a shell's motd would show till then
# (and the watcher's PID could be anyone's by now)
echo 1 > /.conn_check
rm -f /.conn_check_pid

# Starting, till OpenVPN runs: a shell's motd says so, and vpn-restart
# waits for this lock and then gives up - it would start a second OpenVPN
# beside the one connectOvpn starts. connectOvpn runs with fd 9 closed so
# the openvpn daemon doesn't hold it for good, as in vpn-restart, and it's
# let go before anything that stays starts: connCheck's watcher would keep
# it otherwise.
mkdir -p /run/jumpbox
: > /run/jumpbox/starting
exec 9>/run/vpn-restart.lock
flock -n 9

[[ -z "$DCN" ]] && echo "You must specify a valid container name" && exit 1
[[ -z "$PORT" ]] && echo "You must specify a valid port" && exit 1
[[ -z "$OVPNFILE" ]] && echo "You must specify a valid ovpn file" && exit 1
# OTP is on only as "true": any other spelling would send the AUTHFILE's
# password without the code, retried every 2s
[[ -n "$OTP" && "$OTP" != "true" && "$OTP" != "false" ]] && echo "OTP must be true or false" && exit 1

# The resolvers the container started with (docker's), which work without the
# tunnel. pinRemotes looks the servers up through them: /etc/resolv.conf gets
# the pushed DNS on every connect, often only reachable through the tunnel.
cp /etc/resolv.conf /run/jumpbox/underlay-resolv.conf

echo -n -e " ${arrow} Starting...\n"
echo -n -e " ${arrow} Connect using: ${cyan}$jb${white}\n"
echo -n -e " ${arrow} Connecting the tunnel, this can take a while...\n"

tunDevice    # - Configure tun device
killSwitch   # - Enable the VPN Killswitch
connectOvpn 9>&-  # - Connect the tunnel, sockd will start as part of the process
exec 9>&-; rm -f /run/jumpbox/starting  # - Started: vpn-restart can run now
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