#!/bin/bash

source /config/inc.sh
source /etc/profile 2>/dev/null

sfile="/.conn_check"

# One at a time. A second run deletes tun0 under the first one's new openvpn,
# which then logs "read from TUN/TAP" errors in a tight loop (a GB of log in
# under a minute). The lock goes when this script exits; connectOvpn below
# runs with fd 9 closed so the openvpn daemon doesn't hold it for good. A
# short wait rather than none: connCheck's watcher takes the lock for a
# moment to see whether vpn-restart is running.
exec 9>/run/vpn-restart.lock
if ! lockWait 9 2; then
  echo -e " ${violet}▸ ${rose}vpn-restart is already running${normal}"
  exit 1
fi

flag="${EMOJI:-🔄}"
echo -e " $flag ${bold}${violet}Project Jumpbox${normal}${dim} · ${white}VPN Restart${normal}\n"

# Stop OpenVPN using exact process match
echo -e " ${arrow} Stopping OpenVPN...${normal}"
vpn_pid=$(pgrep -x openvpn)
if [[ -n "$vpn_pid" ]]; then
  kill -TERM $vpn_pid 2>/dev/null
  sleep 2
  kill -9 $vpn_pid 2>/dev/null
  sleep 0.5
else
  echo -e " ${arrow} No running OpenVPN process found${normal}"
fi

# Fully remove tun0 so the new instance gets tun0 (not tun1)
# This is critical — the kill switch iptables rules only allow tun0
echo -e " ${arrow} Removing tun interface...${normal}"
ip link delete tun0 2>/dev/null
sleep 0.5

# Ensure tun device node exists
tunDevice

# Mark disconnected for the existing connCheck from start.sh
echo "1" > $sfile

# Restore public DNS — VPN-pushed DNS servers are unreachable with the tunnel down,
# so openvpn can't resolve the server hostname without this.
# The --up script (up.sh) will reset resolv.conf to VPN DNS once connected.
echo -e " ${arrow} Restoring public DNS...${normal}"
printf "nameserver 8.8.8.8\nnameserver 1.1.1.1\n" > /etc/resolv.conf

# Fetch a fresh OTP if this connection uses 2FA
if [[ "$OTP" == "true" ]]; then
  if command -v op &>/dev/null && [[ -n "$OPITEM" ]]; then
    echo -e " ${arrow} Fetching OTP from 1Password...${normal}"
    OTPIN=$(op read "$OPITEM")
  else
    echo -n -e " ${arrow} Enter Your OTP: ${normal}"
    read -r OTPIN
  fi

  if [[ -z "$OTPIN" ]]; then
    echo -e " ${violet}▸ ${rose}No OTP provided, aborting${normal}"
    exit 1
  fi
  export OTPIN
fi

# Reconnect
echo -e " ${arrow} Reconnecting OpenVPN...${normal}"
connectOvpn 9>&-

# Wait for the existing connCheck (from start.sh) to detect connectivity
# Do NOT call connCheck again — it's already running
count=60
ssoShown=""
why="Connection timed out"
echo -n -e " ${arrow} Waiting for connection${normal}"
while [[ $(cat $sfile) -eq "1" && $count -gt 0 ]]; do
  # A pending SSO sign-in holds the countdown, up to the server's own window
  ssoCheck "$normal"
  case $? in
    0) sleep 1; continue ;;
    2)
      # Stop it, or OpenVPN would carry on fetching new sign-in URLs. The
      # panel says why.
      pkill -x openvpn
      mkdir -p /run/jumpbox
      echo "SSO sign-in not completed in time" > /run/jumpbox/stopped
      why="The SSO sign-in was not completed in time, OpenVPN stopped (run vpn-restart to try again)"
      break ;;
  esac
  echo -n -e "."
  count=$((count-1))
  sleep 1
done

if [[ $(cat $sfile) -eq "1" ]]; then
  echo -e "\n\n ${violet}▸ ${rose}${why}. OpenVPN log:${normal}"
  tail -20 /var/log/openvpn.log
else
  ip=$(curl -s --max-time 5 ifconfig.me || curl -s --max-time 5 https://ipinfo.io/ip)
  echo -e "\n\n ${violet}▸ ${mint}VPN restarted successfully${normal}"
  echo -e " ${arrow} Public IP: ${cyan}${ip}${normal}"
fi
