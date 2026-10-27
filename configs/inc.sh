#!/bin/bash

bold=$(tput bold 2>/dev/null)
normal=$(tput sgr0 2>/dev/null)
# No terminfo for this TERM (unset, dumb, not in the image): plain escapes
[[ -n $normal ]] || bold=$'\e[1m' normal=$'\e[0m'
purple='\033[35m'
green='\033[92m'
red='\033[31m'

# The Aurora palette for the startup and shutdown lines, 24-bit, for echo -e
# and printf %b like the colours above (display has its own copy as bytes)
violet='\033[38;2;180;132;255m'
cyan='\033[38;2;96;222;255m'
white='\033[38;2;234;236;245m'
dim='\033[38;2;125;131;160m'
mint='\033[38;2;96;245;170m'
rose='\033[38;2;255;96;120m'
# No terminal (docker run -d, or -i without -t): plain text, no escapes
if [[ ! -t 1 ]]; then
  bold="" normal="" purple="" green="" red=""
  violet="" cyan="" white="" dim="" mint="" rose=""
fi
arrow="${violet}▸${white}"

jb="docker exec -it $(cat /etc/hostname) sh -l"

function ctrlC() {
  # Restore cursor, autowrap, the tty modes display changed and clear screen.
  # Plain escapes as well as tput: the display set them with plain escapes,
  # and tput has nothing to send for a TERM without them (dumb, vt100)
  if [[ -t 1 ]]; then
    printf '\e[?25h\e[?7h\e[?5l\e[4l\e[20l\e[0m'
    tput cnorm 2>/dev/null
    tput smam 2>/dev/null
    [[ -n $ttyMode ]] && stty "$ttyMode" 2>/dev/null
    printf '\e[H\e[2J'
    clear 2>/dev/null
  fi

  # Display exit message
  source /etc/profile 2>/dev/null
  local exit_flag="${EMOJI:-🚪}"
  echo -e " $exit_flag ${bold}${violet}Project Jumpbox${normal}${dim} · ${white}Shutting down...${normal}\n"

  # Kill OpenVPN first (this is critical)
  echo -e " ${arrow} Stopping OpenVPN...${normal}"
  pkill -SIGTERM openvpn 2>/dev/null
  sleep 0.5
  pkill -SIGKILL openvpn 2>/dev/null

  # Kill other services
  echo -e " ${arrow} Stopping services...${normal}"
  pkill -SIGTERM sockd 2>/dev/null
  pkill -SIGTERM sshd 2>/dev/null
  [[ -f /.conn_check_pid ]] && kill $(cat /.conn_check_pid) 2>/dev/null

  # CRITICAL: Restore iptables to allow shutdown traffic
  echo -e " ${arrow} Restoring firewall...${normal}"
  iptables -P INPUT ACCEPT 2>/dev/null
  iptables -P OUTPUT ACCEPT 2>/dev/null
  iptables -P FORWARD ACCEPT 2>/dev/null
  iptables -F 2>/dev/null
  iptables -X 2>/dev/null

  ip6tables -P INPUT ACCEPT 2>/dev/null
  ip6tables -P OUTPUT ACCEPT 2>/dev/null
  ip6tables -P FORWARD ACCEPT 2>/dev/null
  ip6tables -F 2>/dev/null
  ip6tables -X 2>/dev/null

  # Remove tun device
  echo -e " ${arrow} Cleaning up network interfaces...${normal}"
  ip link set tun0 down 2>/dev/null

  echo -e "\n $exit_flag ${bold}${violet}Project Jumpbox${normal}${dim} · ${white}Exit complete${normal}\n"

  exit 0
}

custom() {
  if [[ -n "$CUSTOMCONF" ]]; then
    echo -n -e " ${arrow} A custom config file will be applied (${cyan}$CUSTOMCONF${white})${normal}\n"
    cat /vpn/$CUSTOMCONF | sh
  fi
}

tunDevice() {
  mkdir -p /dev/net
  [[ -c /dev/net/tun ]] || mknod -m 0666 /dev/net/tun c 10 200
}

#connCheck() {
#  sfile="/.conn_check"
#  echo "1" > $sfile
#  while true; do
#    if ! ping -q -c 1 -W 1 8.8.8.8 &>/dev/null && \
#       ! ping -q -c 1 -W 1 1.1.1.1 &>/dev/null; then
#      echo "1" > $sfile
#    else
#      echo "0" > $sfile
#    fi
#    sleep 5
#  done &
#}

connCheck() {
  sfile="/.conn_check"
  echo "1" > $sfile
  mkdir -p /run/jumpbox
  (
    trap 'exit 0' SIGTERM SIGINT
    local -i state downSince=0 pinnedAt=-60
    ssoShown=""
    while true; do
      if [[ "$CONNCHECK" == "tunnel" ]]; then
        # CONNCHECK=tunnel - for gateways that only route their own networks,
        # where a public ping never answers: up means OpenVPN says it's up
        if tunnelUp; then state=0; else state=1; fi
      elif ! ping -q -c 1 -W 1 8.8.8.8 &>/dev/null && \
         ! ping -q -c 1 -W 1 1.1.1.1 &>/dev/null; then
        state=1
      else
        state=0
      fi
      echo "$state" > $sfile
      vpnWatch "$state"
      sleep 5 || exit 0
    done
  ) &>/dev/null &
  echo $! > /.conn_check_pid
  # Keep bash job-death notices (e.g. "line 88: 1234 Killed ping ...") off the
  # TTY — they land mid-line in the display loop and corrupt the redraw
  disown
}

# connCheck's housekeeping, given the state it just wrote (0 up, 1 down), once
# the tunnel has been up at all (getting connected the first time is
# waitConn's job):
# - SSO=true: a re-auth sign-in that runs out its window unapproved stops
#   OpenVPN, as vpn-restart and waitConn do. Left alone, OpenVPN starts over
#   with a fresh sign-in URL every window, and the host's sso-url -f watcher
#   opens each one in a new browser tab. The margin covers this loop's
#   cadence twice over (5s plus up to 2s of pings, once to first see the URL
#   and once more to see the deadline), so it acts before the next URL.
# - After 30s down, the server names are re-pinned (at most once a minute):
#   a server back on a new address is never reached otherwise, since the
#   pins are all OpenVPN resolves. When all of a name's addresses changed,
#   OpenVPN is restarted onto the new ones. Not while a sign-in is pending,
#   which a restart would throw away.
# Neither while vpn-restart runs, which does both itself (the probe holds
# its lock only for a moment, and vpn-restart waits that out).
vpnWatch() {
  local -i rc
  if (( $1 == 0 )); then
    [[ -f /run/jumpbox/connected-once ]] || : > /run/jumpbox/connected-once
    ssoShown="" downSince=0
    return
  fi
  [[ -f /run/jumpbox/connected-once ]] || return
  (( downSince )) || downSince=$SECONDS
  flock -s -n /run/vpn-restart.lock true || return
  pgrep -x openvpn >/dev/null || return

  if [[ $SSO == true ]]; then
    ssoCheck "" 20
    rc=$?
    if (( rc == 2 )); then
      echo "SSO sign-in not completed in time" > /run/jumpbox/stopped
      vpnLog "the SSO sign-in window ran out unapproved, stopping OpenVPN"
      pkill -x openvpn
      ssoShown=""
      return
    fi
    (( rc == 0 )) && return
  fi

  if (( SECONDS - downSince >= 30 && SECONDS - pinnedAt >= 60 )); then
    pinnedAt=$SECONDS
    pinRemotes
    if [[ -n $pinMoved ]]; then
      vpnLog "$pinMoved moved to a new address, restarting OpenVPN"
      pkill -USR1 -x openvpn
    fi
  fi
}

# lockWait <fd> <seconds>: an exclusive flock on the fd, waiting up to that
# long for it (busybox flock has no -w)
lockWait() {
  local -i i
  for (( i = 0; i < $2 * 10; i++ )); do
    flock -n "$1" && return 0
    sleep 0.1
  done
  return 1
}

# vpnLog <message>: a line in /var/log/jumpbox.log. Not the OpenVPN log:
# OpenVPN writes that without O_APPEND, so other lines in it get overwritten.
vpnLog() {
  printf '%(%F %T)T %s\n' -1 "$*" >> /var/log/jumpbox.log
}

getFlagEmoji() {
  local countryCode=${1^^}
  local emoji=""

  for (( i=0; i<${#countryCode}; i++ )); do
    char=${countryCode:i:1}
    codePoint=$((127397 + $(printf "%d" "'$char")))
    emoji+=$(printf "\\U$(printf "%08x" $codePoint)")
  done

  echo -e "$emoji"
}

killSwitch() {
  dockerNet=$(ip -o addr show dev eth0 | awk '$3 == "inet" {print $4}')
  iptables -F
  iptables -X
  iptables -P INPUT DROP
  iptables -P FORWARD DROP
  iptables -P OUTPUT DROP

  ip6tables -P INPUT DROP
  ip6tables -P FORWARD DROP
  ip6tables -P OUTPUT DROP

  # Allow loopback (critical for container internals and docker exec)
  iptables -A INPUT -i lo -j ACCEPT
  iptables -A OUTPUT -o lo -j ACCEPT

  # Allow established connections
  iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  # Allow all traffic from/to Docker network (for docker exec and SSH)
  iptables -A INPUT -s $dockerNet -j ACCEPT
  iptables -A OUTPUT -d $dockerNet -j ACCEPT

  # Allow VPN traffic
  iptables -A OUTPUT -o tun0 -j ACCEPT
  iptables -A INPUT -i tun0 -j ACCEPT

  # Allow VPN user to establish connections (for OpenVPN daemon)
  iptables -A OUTPUT -m owner --gid-owner vpn -j ACCEPT
}

# Pin the profile's server hostnames in /etc/hosts. OpenVPN re-resolves the
# remote on every reconnect, and with the tunnel down the pushed DNS servers
# are often unreachable (provider-internal resolvers), leaving it looping on
# "Could not determine IPv4/IPv6 protocol". Looked up as the vpn group so the
# kill switch lets the query out, with dig so the old pins in /etc/hosts
# don't answer for themselves, and through the resolvers the container
# started with first: those are docker's and don't need the tunnel, where
# /etc/resolv.conf gets the pushed DNS on every connect (start.sh keeps a
# copy). A lookup that fails keeps the old pin. Sets pinMoved to the names
# whose addresses all changed. /etc/hosts is a docker bind mount, so it's
# rewritten in place rather than with sed -i (rename would fail), only when
# the pins changed, one writer at a time (connCheck re-pins while the tunnel
# is down), and never without the file's own entries.
pinRemotes() {
  local host ip ips old kept now pins="" ns nl=$'\n'
  local -a hosts servers
  pinMoved=""
  mkdir -p /run/jumpbox

  mapfile -t hosts < <(tr -d '\r' < "/vpn/$OVPNFILE" \
                       | awk '$1 == "remote" && $2 !~ /^[0-9.]+$/ {print $2}' | sort -u)
  (( ${#hosts[@]} )) || return 0
  [[ -r /run/jumpbox/underlay-resolv.conf ]] && \
    mapfile -t servers < <(awk '$1 == "nameserver" && $2 ~ /^[0-9.]+$/ {print $2}' /run/jumpbox/underlay-resolv.conf)

  for host in "${hosts[@]}"; do
    [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] || continue
    ips=""
    for ns in "${servers[@]}" ""; do
      ips=$(timeout 5 sg vpn -c "dig ${ns:+@$ns} +short +time=2 +tries=1 A $host" 2>/dev/null \
            | grep -E '^[0-9]+(\.[0-9]+){3}$' | sort -u)
      [[ -n "$ips" ]] && break
    done
    old=$(grep -F " $host # jumpbox-pin" /etc/hosts)
    if [[ -n "$ips" ]]; then
      for ip in $ips; do pins+="$ip $host # jumpbox-pin"$'\n'; done
      # Moved: it was pinned, and none of the old addresses is still among the new
      if [[ -n "$old" ]] && ! awk '{print $1}' <<<"$old" | grep -qxF -f <(printf '%s\n' $ips); then
        pinMoved+="${pinMoved:+ }$host"
      fi
    else
      # Lookup failed (no network yet, e.g. vpn-restart after sleep) - keep the old pin
      [[ -n "$old" ]] && pins+="$old"$'\n'
    fi
  done

  {
    lockWait 8 10
    kept=$(grep -v ' # jumpbox-pin$' /etc/hosts)
    now=$(grep ' # jumpbox-pin$' /etc/hosts)
    if [[ $kept == *localhost* && "${now:+$now$nl}" != "$pins" ]]; then
      printf '%s\n%s' "$kept" "$pins" > /etc/hosts
    fi
  } 8>/run/jumpbox/pins.lock
  return 0
}

connectOvpn() {
  # Why the last OpenVPN stopped, for the panel - over once it starts again
  rm -f /run/jumpbox/stopped
  pinRemotes

  # Options that go after --config so they win over the profile
  local extra=""

  # SSO=true - OpenVPN Access Server SAML (browser sign-in). Advertising
  # web auth makes the server answer with AUTH_PENDING and a sign-in URL, which
  # ssoPending picks out of the log (logged at verb 3, so make sure we have it).
  # Without IV_SSO the server refuses: "This profile requires web based SAML
  # authentication".
  if [[ "$SSO" == "true" ]]; then
    echo -n -e " ${arrow} Using SSO (browser sign-in)${normal}\n"
    extra+=" --setenv IV_SSO webauth,openurl"
    # A rejected sign-in must stop, not retry: every retry is a fresh URL, and
    # an IdP that signs in without a click would open tabs every few seconds.
    # Expired session tokens still reconnect - OpenVPN handles those first.
    extra+=" --auth-retry none"
    grep -qE '^[[:space:]]*verb[[:space:]]+([3-9]|1[01])([[:space:]]|$)' "/vpn/$OVPNFILE" \
      || extra+=" --verb 3"
  fi

  # ROUTEALL=true - send everything down the tunnel for split-tunnel profiles,
  # instead of editing redirect-gateway into the downloaded profile
  if [[ "$ROUTEALL" == "true" ]]; then
    extra+=" --redirect-gateway def1"
  fi

  # OTP is on only as "true" (as the next branch has it): OTP=false must not
  # drop the AUTHFILE
  if [[ -n "$AUTHFILE" && "$OTP" != "true" ]]; then
    echo -n -e " ${arrow} Using specified authfile (${cyan}$AUTHFILE${white})${normal}\n"
    sg vpn -c "openvpn --auth-nocache --daemon openvpn-client \
      --persist-tun --persist-key --log /var/log/openvpn.log \
      --connect-retry 2 0 --script-security 2 --up /config/up.sh --up-restart \
      --auth-retry nointeract --data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305:AES-256-CBC \
      --config /vpn/$OVPNFILE --auth-user-pass /vpn/$AUTHFILE $extra"

  elif [[ "$OTP" == "true" ]]; then
    if [[ -z "$OTPIN" ]]; then
      # Waiting on the console: start.sh's marker says so meanwhile, for a
      # shell's motd and vpn-restart
      [[ -e /run/jumpbox/starting ]] && echo otp > /run/jumpbox/starting
      echo -n -e " ${arrow} Enter Your OTP: ${normal}"
      read -r OTPIN
      [[ -s /run/jumpbox/starting ]] && : > /run/jumpbox/starting
    fi

    # --askpass only with a passphrase: OpenVPN 2.7 stops at an empty one,
    # key encrypted or not
    local ask=""
    [[ -n "$PRIVKEY" ]] && ask="--askpass <(echo \"$PRIVKEY\")"
    echo -n -e " ${arrow} Using specified authfile (${cyan}$AUTHFILE${white})${normal}\n"
    sg vpn -c "openvpn --auth-nocache --daemon openvpn-client \
      --persist-tun --persist-key --log /var/log/openvpn.log \
      --connect-retry 2 0 --script-security 2 --up /config/up.sh --up-restart \
      --auth-retry nointeract --config /vpn/$OVPNFILE $ask \
      --auth-user-pass <(cat /vpn/$AUTHFILE; echo \"$OTPIN\") $extra"

  else
    [[ "$SSO" == "true" ]] || echo -n -e " ${arrow} No authfile was specified...${normal}\n"
    sg vpn -c "openvpn --auth-nocache --daemon openvpn-client \
      --persist-tun --persist-key --log /var/log/openvpn.log \
      --connect-retry 2 0 --script-security 2 --up /config/up.sh --up-restart \
      --auth-retry nointeract --config /vpn/$OVPNFILE $extra"
  fi
}

# Print the sign-in URL if OpenVPN is currently waiting on an SSO login.
# The server sends it as INFO_PRE,WEB_AUTH::<url> (or OPEN_URL:<url>) and
# OpenVPN logs it; any later handshake, auth-failure or restart line in the
# log means it's no longer the one being waited on. Only the end of the log
# is read: a sign-in being waited on is the last thing OpenVPN logged, and
# all of a log that grew for days (a refused password retried every 2s)
# takes seconds - for every shell's motd, and every 3s in the panel.
ssoPending() {
  local url
  pgrep -x openvpn >/dev/null || return 0
  url=$(tail -c 2000000 /var/log/openvpn.log 2>/dev/null \
        | grep -E "Info command was pushed by server \('(WEB_AUTH|OPEN_URL):|PUSH_REPLY|Initialization Sequence Completed|AUTH_FAILED|SIG(HUP|USR1|TERM)\[|Restart pause" \
        | tail -n1 \
        | sed -nE "s/.*pushed by server \('(WEB_AUTH:[^:]*:|OPEN_URL:)([^']+)'\).*/\2/p")
  # Only ever hand on a plain https URL - it's printed to the TTY with echo -e
  # and opened on the host, so URL characters only (no backslash escapes)
  local re='^https://[A-Za-z0-9._~:/?#@!$&()*+,;=%-]+$'
  [[ "$url" =~ $re ]] && echo "$url"
  return 0
}

# Is the tunnel up right now? The last connect/restart event in the log
# decides - tun0 alone isn't enough, --persist-tun keeps it across reconnects
tunnelUp() {
  pgrep -x openvpn >/dev/null && ip link show tun0 &>/dev/null || return 1
  grep -E "Initialization Sequence Completed|SIG(HUP|USR1|TERM)\[|Restart pause|AUTH_FAILED" \
    /var/log/openvpn.log 2>/dev/null | tail -n1 | grep -q "Initialization Sequence Completed"
}

# Why OpenVPN isn't running, when that's known, into stopWhy as plain text:
# what stopped it (an SSO sign-in that ran out its window, under vpn-restart
# or the watcher), or the server's AUTH_FAILED as the last word in
# OpenVPN's log
stoppedWhy() {
  stopWhy=""
  { read -r stopWhy < /run/jumpbox/stopped; } 2>/dev/null
  if [[ -z $stopWhy ]] && tail -n 200 /var/log/openvpn.log 2>/dev/null \
       | grep -E 'AUTH_FAILED|Initialization Sequence Completed' | tail -n1 | grep -q AUTH_FAILED; then
    stopWhy="The server refused the sign-in"
  fi
  plainText stopWhy "$stopWhy"
}

# sshHostPort <var>: the host port published for SSH (docker run -p).
# SSHPORT when it maps ssh to something other than PORT+2000, ? when
# neither is a number. 10#: a leading zero would otherwise make it octal
# (or an error).
sshHostPort() {
  if [[ $SSHPORT =~ ^[0-9]+$ ]]; then
    printf -v "$1" '%d' $(( 10#$SSHPORT ))
  elif [[ $PORT =~ ^[0-9]+$ ]]; then
    printf -v "$1" '%d' $(( 10#$PORT + 2000 ))
  else
    printf -v "$1" '%s' '?'
  fi
}

# Seconds the server gave us to finish signing in (from the AUTH_PENDING line)
ssoTimeout() {
  local t
  t=$(sed -nE 's/.*AUTH_PENDING received, extending handshake timeout from [0-9]+s to ([0-9]+)s.*/\1/p' \
        /var/log/openvpn.log 2>/dev/null | tail -n1)
  echo "${t:-300}"
}

# Called once a second by the connection wait loops. While an SSO sign-in is
# pending it prints each new URL and returns 0 so the caller holds its
# countdown; returns 1 when nothing is pending and 2 once the sign-in window
# (taken from the first URL) has run out. Callers reset ssoShown first.
# $1 is the colour to go back to after the URL (default white, as in start.sh),
# $2 how far inside the server's window to call it run out (default 5s, for
# loops that check every second).
ssoCheck() {
  local url t resume=${1:-$white} margin=${2:-5}

  # Checked before looking for a URL: when the window lapses OpenVPN restarts,
  # and for that moment there's no URL in the log to trip the check below
  [[ -n "$ssoShown" && $(date +%s) -ge $ssoDeadline ]] && return 2

  url=$(ssoPending)
  [[ -z "$url" ]] && return 1

  if [[ "$url" != "$ssoShown" ]]; then
    if [[ -z "$ssoShown" ]]; then
      # A little inside the server's window, which started just before we saw
      # the URL: the margin in, or half of a window too short for it
      t=$(ssoTimeout)
      if (( t > margin + 5 )); then t=$(( t - margin )); else t=$(( t / 2 )); fi
      ssoDeadline=$(( $(date +%s) + t ))
    fi
    ssoShown=$url
    # URL as data (%s), only the colours get escape processing
    printf '\n %b▸%b Finish the SSO sign-in in your browser:\n %b▸ %b%s%b\n %b▸%b Waiting for sign-in' \
      "$violet" "$resume" "$violet" "$cyan" "$url" "$resume" "$violet" "$resume"
  fi

  [[ $(date +%s) -ge $ssoDeadline ]] && return 2
  return 0
}

sockdStart() {
  echo -n -e " ${arrow} Starting socks5 process...${normal}\n"
  sockd -D -f /etc/sockd.conf &>/var/log/sockd.log &
}

sshdStart() {
  ssh-keygen -A &>/dev/null
  /usr/sbin/sshd &>/dev/null
}

waitConn() {
  count=40
  ssoShown=""
  local why=""
  echo -n -e " ${arrow} Waiting for connection"
  while [[ $(cat $sfile) -eq "1" && $count -ge "0" ]]; do
    # A pending SSO sign-in holds the countdown, up to the server's own window
    ssoCheck
    case $? in
      0) sleep 1; continue ;;
      2) count=0; why="The SSO sign-in was not completed in time" ;;
      *) echo -n -e "."; count=$((count-1)); sleep 1 ;;
    esac

    if [[ $count -eq "0" ]]; then
      clear
      cat /var/log/openvpn.log
      [[ -n "$why" ]] && echo -e "\n ${violet}▸ ${rose}${why}${normal}"
      exit 1
    fi
  done
  # End the "Waiting for connection...." line: without a terminal the status
  # lines follow it in the log
  echo
}

# Thanks to https://github.com/alfredopalhares/openvpn-update-resolv-conf
setdns() {
    for optionname in ${!foreign_option_*} ; do
        option="${!optionname}"
        part1=$(echo "$option" | cut -d " " -f 1)
        if [ "$part1" == "dhcp-option" ] ; then
            part2=$(echo "$option" | cut -d " " -f 2)
            part3=$(echo "$option" | cut -d " " -f 3)

            if [ "$part2" == "DNS" ] ; then
                IF_DNS_NAMESERVERS="$IF_DNS_NAMESERVERS $part3"
            fi

            if [[ "$part2" == "DOMAIN" || "$part2" == "DOMAIN-SEARCH" ]] ; then
                IF_DNS_SEARCH="$IF_DNS_SEARCH $part3"
            fi
        fi
    done

    R=""
    if [ "$IF_DNS_SEARCH" ]; then
        R="search "

        for DS in $IF_DNS_SEARCH ; do
            R="${R} $DS"
        done
        # No indent after the newline: musl only reads nameserver lines that
        # start at column 0, so an indented first one left no DNS at all
        R="${R}"$'\n'
    fi

    for NS in $IF_DNS_NAMESERVERS ; do
        R="${R}nameserver $NS
        "
    done

    # Nothing pushed (common with split-tunnel profiles) - an empty resolv.conf
    # would leave the container and the socks proxy without DNS. Prepended so
    # the lines start at column 0, musl ignores indented ones.
    if [ -z "$IF_DNS_NAMESERVERS" ]; then
        R="nameserver 1.1.1.1
nameserver 9.9.9.9
${R}"
    fi
    echo "$R" > /etc/resolv.conf
}

# The status display (Aurora) is one fixed frame - a rounded panel - built
# five times a second and painted with absolute cursor addressing. Once a
# second (and after a resize) the paint rewrites all of it; in between only
# the rows that changed (the heartbeat, the pulsing badge, the spinners), so
# the TTY stream - which is also what `docker logs` keeps - stays small. No
# newline is ever written, so the loop can't scroll the terminal, and
# anything that disturbs the screen (a resize, stray output, a cleared
# terminal) is painted over within a second. Never rewriting the rows above
# the status rows is what used to leave stale copies of the status line
# stacked up and header lines pushed off the top: once the screen had
# scrolled (an echoed Enter on the bottom row, a pane shorter than the
# frame), nothing redrew them until the next resize.
#
# Two layouts. The full panel is 66x10. A pane narrower than 66 or shorter
# than 10 gets a compact 7-row panel as wide as the pane (up to 66 columns;
# laid out for 40, workable down to 20), and a pane under 7 rows gives up
# rows of that in a fixed order.
#
# Every glyph used is one cell wide except the country flag, which is two
# characters (regional indicators) drawn as two cells - so ${#s} is a plain
# string's width in cells. Rows are put together with the row* helpers,
# which keep that width (rw) alongside the escaped string (row); fitText
# must only ever be given plain text. The helpers that hand back a result in
# a variable named by the caller use _-prefixed locals, so a caller's
# variable can't be shadowed (that blanks the result without an error).

# One-off setup for display: the colours as escape bytes, the border
# gradients and the animation frames. Kept out of the top level, which
# up.sh, sso-url and vpn-restart source as well.
auroraInit() {
  printf -v cWht '\e[38;2;234;236;245m'
  printf -v cDim '\e[38;2;125;131;160m'
  printf -v cFnt '\e[38;2;62;66;88m'
  printf -v cVio '\e[38;2;180;132;255m'
  printf -v cCyn '\e[38;2;96;222;255m'
  printf -v cGrn '\e[38;2;96;245;170m'
  printf -v cRed '\e[38;2;255;96;120m'
  printf -v cAmb '\e[38;2;255;198;86m'
  printf -v cInk '\e[38;2;14;16;26m'
  cBold=$'\e[1m' cOff=$'\e[0m'

  # Connected: violet, blue, cyan, green. Down: reds. SSO pending: ambers.
  auroraGradient gradConn 24 160 96 255  70 140 255  60 220 245  90 245 175
  auroraGradient gradDown 32 255 70 95   255 140 70  150 40 60
  auroraGradient gradSso  32 255 200 80  255 140 50  255 230 140

  ekgBeat=(▁ ▁ ▁ ▁ ▂ ▁ █ ▃ ▁ ▂ ▁ ▁ ▁ ▁ ▁ ▁ ▁ ▁)
  spinner=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
}

# auroraGradient <array> <steps> <r g b>...: a cyclic gradient through the
# colours, <steps> escape strings from each one to the next
auroraGradient() {
  local -n _g=$1
  local -i _st=$2 _n _i _j _k
  local _e
  shift 2
  local -a _c=("$@")
  _n=$(( ${#_c[@]} / 3 ))
  _g=()
  for (( _i = 0; _i < _n; _i++ )); do
    _j=$(( (_i + 1) % _n ))
    for (( _k = 0; _k < _st; _k++ )); do
      printf -v _e '\e[38;2;%d;%d;%dm' \
        $(( _c[_i*3]   + (_c[_j*3]   - _c[_i*3])   * _k / _st )) \
        $(( _c[_i*3+1] + (_c[_j*3+1] - _c[_i*3+1]) * _k / _st )) \
        $(( _c[_i*3+2] + (_c[_j*3+2] - _c[_i*3+2]) * _k / _st ))
      _g+=("$_e")
    done
  done
}

rowStart() { row=""; rw=0; }

# rowAdd <colour> <text>
rowAdd() { row+="$1$2"; rw+=${#2}; }

# rowPad <cells>: that many spaces
rowPad() {
  (( $1 > 0 )) || return 0
  local _s
  printf -v _s '%*s' "$1" ''
  row+=$_s
  rw+=$1
}

# rowTo <column>: spaces up to that column
rowTo() { rowPad $(( $1 - rw )); }

# rowGrad <text>: border text in the state's gradient, each character
# coloured by its place in the frame, so the colours drift slowly along the
# border, a step each second ($phase)
rowGrad() {
  local -n _p=$grad
  local _s=$1
  local -i _i _n=${#_p[@]}
  for (( _i = 0; _i < ${#_s}; _i++ )); do
    row+="${_p[(rw + _i + gr * 2 + phase) % _n]}${_s:_i:1}"
  done
  rw+=${#_s}
}

# fitText <var> <text> <cells>: the text, cut to fit with an ellipsis
fitText() {
  local _f=$2
  if (( $3 <= 0 )); then
    _f=""
  elif (( ${#_f} > $3 )); then
    _f="${_f:0:$3-1}…"
  fi
  printf -v "$1" '%s' "$_f"
}

# repeatText <var> <count> <text>
repeatText() {
  local _r=""
  (( $2 > 0 )) && printf -v _r '%*s' "$2" ''
  printf -v "$1" '%s' "${_r// /$3}"
}

# plainText <var> <text>: anything that isn't plain text one cell wide in
# every terminal - control characters, CJK, combining marks, emoji -
# replaced with ?, so data can't move the cursor or the borders. Latin
# letters (ü, ł) stay.
plainText() {
  local _pt=$2
  printf -v "$1" '%s' "${_pt//[^ -~À-ÖØ-öø-ſ]/?}"
}

# humanBytes <var> <bytes>: 66.0 MiB. Moves up a unit at 1000 so the figure
# never takes more than 9 cells.
humanBytes() {
  local -i _x=$(( ${2:-0} * 10 )) _u=0
  local -a _units=(B KiB MiB GiB TiB PiB)
  while (( _x >= 10000 && _u < 5 )); do _x=_x/1024; _u+=1; done
  if (( _u == 0 )); then
    printf -v "$1" '%d B' "${2:-0}"
  else
    printf -v "$1" '%d.%d %s' $(( _x / 10 )) $(( _x % 10 )) "${_units[_u]}"
  fi
}

# fmtDuration <var> <seconds> [compact]: 03h 52m 43s, or 03h52m43s.
# Plain arithmetic rather than date +%H, which wrapped at 24 hours.
fmtDuration() {
  local -i _s=$2
  local _f='%02dh %02dm %02ds'
  [[ $3 == compact ]] && _f='%02dh%02dm%02ds'
  printf -v "$1" "$_f" $(( _s / 3600 )) $(( _s % 3600 / 60 )) $(( _s % 60 ))
}

# log2i <var> <n>: the whole part of log2(n), 0 for n <= 1
log2i() {
  local -i _lgn=$2 _lgr=0
  while (( _lgn > 1 )); do _lgn=_lgn/2; _lgr+=1; done
  printf -v "$1" '%d' "$_lgr"
}

# sparkline <var> <array> <cells> <rate|ms>: the newest samples as bars,
# oldest first, blank where there's no sample yet. Rates are on a log scale
# from 64 B/s up to at least 16 KiB/s, so idle keepalives stay at the bottom
# and a burst still stands out. Ping is scaled from its lowest to its
# highest, over at least 10ms so jitter doesn't look like a spike.
sparkline() {
  local -n _a=$2
  local -i _n=$3 _len=${#_a[@]} _from _i _v _l _lo _hi _span
  local -a _vals=() _bars=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
  local _o=""

  _from=$(( _len > _n ? _len - _n : 0 ))
  for (( _i = _from; _i < _len; _i++ )); do
    if [[ $4 == rate ]]; then
      _v=0
      if (( _a[_i] > 0 )); then
        log2i _l "${_a[_i]}"
        _v=$(( _l > 5 ? _l - 5 : 0 ))
      fi
    else
      _v=${_a[_i]}
    fi
    _vals+=("$_v")
  done

  if [[ $4 == rate ]]; then
    _lo=0 _hi=9
    for _v in "${_vals[@]}"; do (( _v > _hi )) && _hi=_v; done
  else
    _lo=999999 _hi=0
    for _v in "${_vals[@]}"; do
      (( _v < _lo )) && _lo=_v
      (( _v > _hi )) && _hi=_v
    done
    (( _hi - _lo < 10 )) && _hi=$(( _lo + 10 ))
  fi
  _span=$(( _hi - _lo ))

  (( _n > ${#_vals[@]} )) && printf -v _o '%*s' $(( _n - ${#_vals[@]} )) ''
  for _v in "${_vals[@]}"; do _o+=${_bars[(_v - _lo) * 7 / _span]}; done
  printf -v "$1" '%s' "$_o"
}

# ekgTrace <var> <cells>: a heartbeat trace scrolling left one cell a tick,
# the older two thirds fading out. Flat with a sweep while disconnected, the
# odd blip while an SSO sign-in is pending.
ekgTrace() {
  local -i _n=$2 _i _k _len=${#ekgBeat[@]}
  local _o="" _c _ch _last=""
  for (( _i = 0; _i < _n; _i++ )); do
    _k=$(( (_i + tick) % _len ))
    case $view in
      conn) _ch=${ekgBeat[_k]} ;;
      sso)  _ch=▁; (( (_i + tick) % 9 == 0 )) && _ch=▃ ;;
      *)    _ch=▁ ;;
    esac
    if [[ $view == down ]]; then
      # Flat, with one lit cell sweeping along it: still watching
      _c=$cFnt
      (( _i == _n - 1 - tick % _n )) && _c=$stateFg
    elif (( _i < _n / 3 )); then
      _c=$cFnt
    elif (( _i < _n * 2 / 3 )); then
      _c=$cDim
    else
      _c=$stateFg
    fi
    # A colour only where it changes: this row is repainted every tick
    [[ $_c == "$_last" ]] || _o+=$_c
    _last=$_c
    _o+=$_ch
  done
  printf -v "$1" '%s' "$_o"
}

# The state's colours, badge text (and a short one for narrow panes) and
# border gradient. The badge dot pulses.
auroraState() {
  case $view in
    conn)
      stateFg=$cGrn grad=gradConn badge=" ● CONNECTED " badgeShort=" ● UP "
      printf -v stateBg '\e[48;2;80;235;160m'
      (( tick % 6 < 3 )) && badge=" ◉ CONNECTED " badgeShort=" ◉ UP " ;;
    down)
      stateFg=$cRed grad=gradDown badge=" ✕ DISCONNECTED " badgeShort=" ✕ DOWN "
      printf -v stateBg '\e[48;2;255;96;120m' ;;
    sso)
      stateFg=$cAmb grad=gradSso badge=" ◈ SIGN-IN PENDING " badgeShort=" ◈ SSO "
      printf -v stateBg '\e[48;2;255;198;86m'
      (( tick % 6 < 3 )) && badge=" ◇ SIGN-IN PENDING " badgeShort=" ◇ SSO " ;;
  esac
}

# The full 66x10 panel: auroraFull [row...] builds the rows given (all of
# them by default) into frame[]
auroraFull() {
  local -i W=66 ew r
  local s fill rule
  local -a rows=("$@")
  (( ${#rows[@]} )) || { rows=(0 1 2 3 4 5 6 7 8 9); frame=(); }

  for r in "${rows[@]}"; do
    gr=$r; rowStart
    case $r in
      0) # Flag and name on the top border, the versions at its right
        rowGrad "╭─ "
        [[ -n $flag ]] && rowAdd "" "$flag "
        rowAdd "$cBold$cWht" "PROJECT JUMPBOX"; rowAdd "$cOff" " "
        s=" $vpnVer · Alpine $osVer "
        if (( W - rw - ${#s} - 2 >= 1 )); then
          repeatText fill $(( W - rw - ${#s} - 2 )) ─
          rowGrad "$fill"
          rowAdd "$cDim" " $vpnVer "; rowAdd "$cFnt" "·"; rowAdd "$cDim" " Alpine $osVer "
        else
          fitText s "$s" $(( W - rw - 3 ))
          rowGrad "─"; rowAdd "$cDim" "$s"
        fi
        rowTo $(( W - 2 )); rowGrad "─╮" ;;

      1) # State badge, what it's doing, and the heartbeat
        rowGrad "│"; rowPad 2
        rowAdd "$stateBg$cInk$cBold" "$badge"; rowAdd "$cOff" ""; rowPad 3
        case $view in
          conn) rowAdd "$cDim" "last reconnect "; rowAdd "$cWht" "$agoText" ;;
          down)
            if (( ovpnUp )); then
              rowAdd "$cDim" "retrying "; rowAdd "$cRed" "${spinner[tick % 10]}"
            else
              rowAdd "$cDim" "openvpn stopped"
            fi ;;
          sso)  rowAdd "$cDim" "waiting for browser "; rowAdd "$cAmb" "${spinner[tick % 10]}" ;;
        esac
        # The trace keeps a 2-cell gap from the text
        ew=$(( W - 5 - rw )); (( ew > 16 )) && ew=16
        if (( ew >= 4 )); then
          ekgTrace s "$ew"
          rowTo $(( W - 3 - ew )); row+=$s; rw+=ew
        fi
        rowTo $(( W - 1 )); rowGrad "│" ;;

      2|7)
        repeatText rule $(( W - 6 )) ─
        rowGrad "│"; rowPad 2; rowAdd "$cFnt" "$rule"; rowPad 2; rowGrad "│" ;;

      3)
        rowGrad "│"; rowPad 2; rowAdd "$cVio" "EXIT    "
        if [[ -n $ipShown ]]; then
          [[ -n $flag ]] && rowAdd "" "$flag "
          [[ -n $ctn ]] && rowAdd "$cWht" "$ctn  "
          rowAdd "$cCyn" "$ipShown"
        else
          rowAdd "$cWht" "$ipNote"
        fi
        rowTo $(( W - 1 )); rowGrad "│" ;;

      4)
        rowGrad "│"; rowPad 2; rowAdd "$cVio" "SOCKS5  "
        rowAdd "$cWht" "127.0.0.1:"; rowAdd "$cCyn" "$portShown"
        rowTo $(( W - 1 )); rowGrad "│" ;;

      5)
        rowGrad "│"; rowPad 2; rowAdd "$cVio" "SSH     "
        rowAdd "$cWht" "ssh jumpbox@127.0.0.1 -p "; rowAdd "$cCyn" "$sshPort"
        rowAdd "$cDim" "   password "; rowAdd "$cWht" "jumpbox"
        rowTo $(( W - 1 )); rowGrad "│" ;;

      6)
        rowGrad "│"; rowPad 2; rowAdd "$cVio" "SHELL   "
        rowAdd "$cWht" "docker exec -it "; rowAdd "$cCyn" "$hostShown"; rowAdd "$cWht" " sh -l"
        rowTo $(( W - 1 )); rowGrad "│" ;;

      8) # Transfer totals with the rates over the last 7 seconds, and ping
         # with its last 7 results (one every 5 seconds)
        rowGrad "│"; rowPad 2
        case $view in
          conn)
            if (( ifUp )); then
              rowAdd "$cCyn" "▼ "; rowAdd "$cWht" "$rxText"; rowTo 15; rowAdd "$cCyn" "$rxSpark"; rowPad 2
              rowAdd "$cVio" "▲ "; rowAdd "$cWht" "$txText"; rowTo 36; rowAdd "$cVio" "$txSpark"; rowPad 2
              rowAdd "$cDim" "ping "
              if [[ -n $latText ]]; then rowAdd "$cWht" "$latText"; else rowAdd "$cFnt" "-"; fi
              rowTo 56; rowAdd "$cGrn" "$latSpark"
            else
              rowAdd "$cAmb" "◌ "; rowAdd "$cWht" "Transfer stats: "; rowAdd "$cDim" "interface is down"
            fi ;;
          down)
            if (( ovpnUp )); then
              rowAdd "$cRed" "✕ "; rowAdd "$cWht" "Waiting for outbound connectivity"
            else
              rowAdd "$cRed" "✕ "; rowAdd "$cWht" "${stopWhy:-OpenVPN is not running}"; rowAdd "$cDim" ", run vpn-restart"
            fi ;;
          sso)
            rowAdd "$cAmb" "◈ "; rowAdd "$cWht" "SSO sign-in pending"
            rowAdd "$cDim" ", check your browser (or sso-url)" ;;
        esac
        rowTo $(( W - 1 )); rowGrad "│" ;;

      9) # The config file on the bottom border
        rowGrad "╰─ "
        fitText s "$ovpnShown" $(( W - 7 ))
        rowAdd "$cDim" "$s "
        repeatText fill $(( W - rw - 1 )) ─
        rowGrad "$fill╯" ;;
    esac
    frame[r]=$row
  done
}

# The compact 7-row panel, as wide as the pane: auroraCompact <width>
# [row...] builds the rows given (all of them by default) into frame[].
# Laid out for 40 columns and up; on narrower panes each row keeps its most
# important part (the state, the IP, the ports, the container) and the rest
# gives way or is cut with an ellipsis.
auroraCompact() {
  local -i W=$1 room r pw
  local s msg fill name lbl val addr
  local -a rows=("${@:2}")
  (( ${#rows[@]} )) || { rows=(0 1 2 3 4 5 6); frame=(); }

  for r in "${rows[@]}"; do
    gr=$r; rowStart
    case $r in
      0) # Flag, name and the state on the top border. The name gives way
         # first, then the badge shortens, so the state always shows.
        rowGrad "╭─ "
        [[ -n $flag ]] && rowAdd "" "$flag "
        room=$(( W - rw - 3 ))
        s=$badge name=""
        (( ${#s} > room )) && s=$badgeShort
        if (( W >= 52 && 16 + ${#s} <= room )); then
          name="PROJECT JUMPBOX"
        elif (( 8 + ${#s} <= room )); then
          name="JUMPBOX"
        fi
        if [[ -n $name ]]; then rowAdd "$cBold$cWht" "$name"; rowAdd "$cOff" " "; fi
        fitText s "$s" $(( W - rw - 3 ))
        repeatText fill $(( W - rw - ${#s} - 2 )) ─
        rowGrad "$fill"; rowAdd "$cBold$stateFg" "$s"; rowAdd "$cOff" ""
        rowTo $(( W - 2 )); rowGrad "─╮" ;;

      1) # Exit country and IP, the time since the last reconnect at the
         # right as long as it leaves room for the whole IP
        rowGrad "│"; rowPad 1
        lbl="" val=""
        if [[ $view == conn ]]; then
          if (( W >= 58 )); then lbl="last reconnect " val=$agoText; else lbl="↻ " val=$agoCompact; fi
          s=${ipShown:-$ipNote}
          (( ${#s} > 20 )) && s=${s:0:20}
          # The time ends 2 cells in from the border and keeps a 2-cell gap
          (( ${#s} + ${#lbl} + ${#val} > W - 7 )) && lbl="" val=""
        fi
        if [[ -n $val ]]; then room=$(( W - 7 - ${#lbl} - ${#val} )); else room=$(( W - 3 )); fi
        if [[ -n $ipShown ]]; then
          if (( ${#ctn} && ${#ctn} + 1 + ${#ipShown} <= room )); then
            rowAdd "$cWht" "$ctn "
          fi
          fitText s "$ipShown" "$room"; rowAdd "$cCyn" "$s"
        else
          fitText s "$ipNote" "$room"; rowAdd "$cWht" "$s"
        fi
        if [[ -n $val ]]; then
          rowTo $(( W - 3 - ${#lbl} - ${#val} )); rowAdd "$cDim" "$lbl"; rowAdd "$cWht" "$val"
        fi
        rowTo $(( W - 1 )); rowGrad "│" ;;

      2) # Transfer totals and ping (as many of the three as fit), or what
         # it's waiting for
        rowGrad "│"; rowPad 1
        case $view in
          conn)
            if (( ifUp )); then
              rowAdd "$cCyn" "▼ "; rowAdd "$cWht" "$rxText"
              if (( 16 + ${#txText} <= W - 2 )); then
                rowTo 14; rowAdd "$cVio" "▲ "; rowAdd "$cWht" "$txText"
                if (( 32 + (${#latText} ? ${#latText} : 1) <= W - 2 )); then
                  rowTo 27; rowAdd "$cDim" "ping "
                  if [[ -n $latText ]]; then rowAdd "$cWht" "$latText"; else rowAdd "$cFnt" "-"; fi
                fi
              fi
            else
              fitText s "Transfer stats: interface is down" $(( W - 5 ))
              rowAdd "$cAmb" "◌ "; rowAdd "$cWht" "$s"
            fi ;;
          down)
            if (( ovpnUp )); then
              fitText s "Waiting for outbound connectivity" $(( W - 7 ))
              rowAdd "$cRed" "✕ "; rowAdd "$cWht" "$s "; rowAdd "$cRed" "${spinner[tick % 10]}"
            else
              fitText s "${stopWhy:-OpenVPN is not running}, run vpn-restart" $(( W - 5 ))
              rowAdd "$cRed" "✕ "; rowAdd "$cWht" "$s"
            fi ;;
          sso)
            if (( W >= 58 )); then
              rowAdd "$cAmb" "◈ "; rowAdd "$cWht" "SSO sign-in pending"; rowAdd "$cDim" ", check your browser (or sso-url)"
            else
              fitText msg "SSO sign-in pending" $(( W - 5 ))
              fitText s ", check browser" $(( W - 24 ))
              rowAdd "$cAmb" "◈ "; rowAdd "$cWht" "$msg"; rowAdd "$cDim" "$s"
            fi ;;
        esac
        rowTo $(( W - 1 )); rowGrad "│" ;;

      3) # The ssh password comes here when the ssh row has no room for it,
         # labelled, and only while the ssh row is on screen. 127.0.0.1 gives
         # way to it first.
        rowGrad "│"; rowPad 1
        rowAdd "$cVio" "socks5 "
        pw=$(( W < 45 && termRows >= 5 ))
        addr="127.0.0.1:"
        (( W < 37 || (pw && rw + 10 + ${#portShown} + 15 > W - 1) )) && addr=":"
        rowAdd "$cWht" "$addr"; rowAdd "$cCyn" "$portShown"
        if (( pw && rw + 15 <= W - 1 )); then rowAdd "$cDim" " ssh pw "; rowAdd "$cWht" "jumpbox"; fi
        rowTo $(( W - 1 )); rowGrad "│" ;;

      4) # Narrower than the command: the port goes first, so a cut leaves it showing
        rowGrad "│"; rowPad 1
        if (( W >= 33 )); then
          rowAdd "$cWht" "ssh jumpbox@127.0.0.1 -p "; rowAdd "$cCyn" "$sshPort"
          if (( W >= 45 )); then rowAdd "$cDim" "  pw "; rowAdd "$cWht" "jumpbox"; fi
        else
          fitText s " jumpbox@127.0.0.1" $(( W - 10 - ${#sshPort} ))
          rowAdd "$cWht" "ssh -p "; rowAdd "$cCyn" "$sshPort"; rowAdd "$cWht" "$s"
        fi
        rowTo $(( W - 1 )); rowGrad "│" ;;

      5) # The container keeps its place; " sh -l" goes first, then the name is cut
        rowGrad "│"; rowPad 1
        rowAdd "$cWht" "docker exec -it "
        if (( 22 + ${#hostShown} <= W - 3 )); then
          rowAdd "$cCyn" "$hostShown"; rowAdd "$cWht" " sh -l"
        elif (( 18 + ${#hostShown} <= W - 3 )); then
          rowAdd "$cCyn" "$hostShown"; rowAdd "$cWht" " …"
        else
          fitText s "$hostShown" $(( W - 19 )); rowAdd "$cCyn" "$s"
        fi
        rowTo $(( W - 1 )); rowGrad "│" ;;

      6) # The config file on the bottom border, and the versions when there's room
        rowGrad "╰─ "
        fitText s "$ovpnShown" $(( W - 7 ))
        rowAdd "$cDim" "$s "
        s=" $vpnVer · Alpine $osVer "
        if (( W - rw - ${#s} - 2 >= 2 )); then
          repeatText fill $(( W - rw - ${#s} - 2 )) ─
          rowGrad "$fill"; rowAdd "$cDim" "$s"; rowGrad "─╯"
        else
          repeatText fill $(( W - rw - 1 )) ─
          rowGrad "$fill╯"
        fi ;;
    esac
    frame[r]=$row
  done
}

# Build the frame for this tick. Everything once a second, and whenever the
# state, the layout or the pane size changes; on the ticks in between only
# the rows that animate (the full panel's badge and heartbeat row; the
# compact panel's badge row, or its spinner row while retrying), which saves
# rebuilding borders nothing has changed.
auroraBuild() {
  local layout
  if (( termCols >= 66 && termRows >= 10 )); then
    layout=full
  else
    layout="compact $(( termCols < 20 ? 20 : termCols > 66 ? 66 : termCols ))"
  fi

  if (( fullDue || now != builtAt )) || [[ $view$ovpnUp != "$builtView" || $layout != "$builtLayout" ]]; then
    builtAt=$now builtView=$view$ovpnUp builtLayout=$layout
    if [[ $layout == full ]]; then
      dropOrder=()
      auroraFull
    else
      # Bottom border, shell, ssh and socks rows go first, then the exit
      # row; the state badge and the status row stay longest
      dropOrder=(6 5 4 3 1 2 0)
      auroraCompact "${layout#compact }"
    fi
  elif [[ $layout == full ]]; then
    auroraFull 1
  elif [[ $view == down ]]; then
    (( ovpnUp )) && auroraCompact "${layout#compact }" 2
  else
    auroraCompact "${layout#compact }" 0
  fi
}

# The pane size, re-read once a second and on a resize. Left as it was if
# stty can't tell (no tty).
termSize() {
  local size
  size=$(stty size 2>/dev/null)
  if [[ $size =~ ^([0-9]+)\ ([0-9]+)$ ]] && (( BASH_REMATCH[1] > 0 && BASH_REMATCH[2] > 0 )); then
    termRows=${BASH_REMATCH[1]} termCols=${BASH_REMATCH[2]}
  fi
}

# Once a second: the tunnel's byte counters (straight from sysfs, no forks),
# the rates and their history, the time since the last reconnect, and the
# result of the last ping, once it has finished.
auroraSample() {
  local rxNow="" txNow="" last="" out=""
  local -i dt ago

  { read -r rxNow < /sys/class/net/tun0/statistics/rx_bytes
    read -r txNow < /sys/class/net/tun0/statistics/tx_bytes; } 2>/dev/null
  if [[ $rxNow =~ ^[0-9]+$ && $txNow =~ ^[0-9]+$ ]]; then
    ifUp=1
    # A counter that went backwards is a new tun0 (vpn-restart deletes the
    # old one): no rate for that second, and the old tunnel's history goes
    if [[ -n $rxPrev ]] && (( rxNow < rxPrev || txNow < txPrev )); then
      rxHist=() txHist=()
    elif [[ -n $rxPrev ]]; then
      dt=$(( now - prevT ))
      (( dt < 1 )) && dt=1
      rxHist+=($(( (rxNow - rxPrev) / dt )))
      txHist+=($(( (txNow - txPrev) / dt )))
      (( ${#rxHist[@]} > 16 )) && rxHist=("${rxHist[@]:1}")
      (( ${#txHist[@]} > 16 )) && txHist=("${txHist[@]:1}")
    fi
    rxPrev=$rxNow txPrev=$txNow prevT=$now
    humanBytes rxText "$rxNow"
    humanBytes txText "$txNow"
    sparkline rxSpark rxHist 7 rate
    sparkline txSpark txHist 7 rate
  else
    ifUp=0 rxPrev="" txPrev="" rxHist=() txHist=()
  fi

  { read -r last < /tmp/last; } 2>/dev/null
  if [[ $last =~ ^[0-9]+$ ]]; then
    # 10#: a leading zero would otherwise make it octal (or an error)
    ago=$(( now - 10#$last ))
    (( ago < 0 )) && ago=0
    fmtDuration agoText "$ago"
    fmtDuration agoCompact "$ago" compact
  else
    agoText="???" agoCompact="???"
  fi

  if [[ -n $pingPid ]] && ! kill -0 "$pingPid" 2>/dev/null; then
    { IFS= read -r -d '' out < "$pingFile"; } 2>/dev/null
    if [[ $out =~ (round-trip|rtt)[^=]*=\ *[0-9.]+/([0-9]+) ]]; then
      latency=$(( 10#${BASH_REMATCH[2]} ))
      # At most 5 cells: 107ms, <1ms, 1.2s
      if (( latency >= 1000 )); then
        printf -v latText '%d.%ds' $(( latency / 1000 )) $(( latency % 1000 / 100 ))
      elif (( latency == 0 )); then
        latText="<1ms"
      else
        latText="${latency}ms"
      fi
      latHist+=("$latency")
      (( ${#latHist[@]} > 16 )) && latHist=("${latHist[@]:1}")
    else
      latency="" latText=""
    fi
    pingPid=""
    sparkline latSpark latHist 7 ms
  fi

  # The public IP and country, once the background lookup has them
  if [[ -n $lookupFile && -f $lookupFile ]]; then
    auroraGeo
    lookupFile=""
  fi
}

# The public IP and its country, looked up in the background so the panel
# keeps going (each curl can take its full 5s on a split-tunnel gateway,
# where the kill switch drops these hosts silently) and a docker stop isn't
# held up behind them. auroraLookup <file> writes the IP, the country name
# and the country code there, one a line, when it's done.
auroraLookup() {
  local ip geo ctn="" cc="" geoUrl
  ip=$(curl -s -m 5 ifconfig.me || curl -s -m 5 https://ipinfo.io/ip)
  if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    geoUrl="https://api.ip2location.io/?key=${GEOAPIKEY}&ip=$ip"
    geo=$(curl -s -m 5 "$geoUrl" | tr -d '\0')
    ctn=$(jq -r '.country_name // empty' <<<"$geo" 2>/dev/null)
    cc=$(jq -r '.country_code // empty' <<<"$geo" 2>/dev/null)
    if [[ -z $ctn && -z $cc ]]; then
      geo=$(curl -s -m 5 "$geoUrl" | tr -d '\0')
      ctn=$(jq -r '.country_name // empty' <<<"$geo" 2>/dev/null)
      cc=$(jq -r '.country_code // empty' <<<"$geo" 2>/dev/null)
    fi
  else
    ip=""
  fi
  printf '%s\n%s\n%s\n' "$ip" "${ctn//[[:cntrl:]]/ }" "${cc//[[:cntrl:]]/ }" > "$1.tmp" && mv -f "$1.tmp" "$1"
}

# Take in what auroraLookup found: what the panel shows, and the exports in
# /etc/profile, which ctrlC, vpn-restart and the motd read
auroraGeo() {
  local -a words
  { read -r ip; read -r ctn; read -r cc; } < "$lookupFile"
  if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ipShown=$ip
  else
    ip="" ipShown="" ipNote="Unable to determine from API call"
  fi

  # Country names come long ("United Kingdom of Great Britain and Northern
  # Ireland", "Korea (Republic of)"): the first two words, or three when the
  # second is a joining word (Isle of Man, Bosnia and Herzegovina). Only
  # letters (Latin ones too, as in Türkiye) and plain punctuation: it has to
  # be one cell a character, and it's written into /etc/profile.
  ctn=${ctn%% (*}
  ctn=${ctn//[^A-Za-z0-9 .,\'À-ÖØ-öø-ſ-]/}
  read -ra words <<<"$ctn"
  if [[ ${words[1],,} =~ ^(and|of|the)$ ]]; then ctn="${words[*]:0:3}"; else ctn="${words[*]:0:2}"; fi
  fitText ctn "$ctn" 24
  [[ $cc =~ ^[A-Za-z]{2}$ ]] || cc=""
  flag=""
  [[ -n $cc ]] && flag=$(getFlagEmoji "$cc")

  echo "export IP=\"$ip\"" >> /etc/profile
  echo "export CC=\"$cc\"" >> /etc/profile
  echo "export CTN=\"$ctn\"" >> /etc/profile
  echo "export EMOJI=\"$flag\"" >> /etc/profile
  fullDue=1
}

# Paint the rows in $frame with a single printf: each row is erased and
# rewritten in place. A full paint (once a second, after a resize, when the
# layout changes) rewrites every row and clears everything below the frame;
# the paints in between rewrite only the rows that changed since. The cursor
# is left parked top-left, where stray output can't scroll anything. A
# window shorter than the frame gives up the rows listed in $dropOrder,
# first ones first.
paintFrame() {
  local r i row n=${#frame[@]} at=0 full=0 sig
  local -a keep
  # First put back any terminal state stray output could have changed: ST
  # ends an unterminated control string (which would swallow the paint), then
  # origin mode off and full-screen margins (or the rows land inside a scroll
  # region), SI and G0=ASCII (no line-drawing charset), plain SGR, normal
  # (not reverse) video, replace (not insert) mode, LF without CR, autowrap
  # off (a row wider than the window clips instead of wrapping onto the next)
  # and the cursor hidden
  local out=$'\e\\\e[?6l\e[r\017\e(B\e[0m\e[?5l\e[4l\e[20l\e[?7l\e[?25l' last=-1

  for (( r = 0; r < n; r++ )); do keep[r]=1; done
  for (( i = 0; i < n - termRows && i < ${#dropOrder[@]}; i++ )); do keep[dropOrder[i]]=0; done
  for (( r = 0; r < n; r++ )); do (( keep[r] )) && last=r; done

  sig="$n ${keep[*]} $termRows $termCols"
  if (( fullDue || now != paintedAt )) || [[ $sig != "$paintedSig" ]]; then
    full=1 fullDue=0 paintedAt=$now paintedSig=$sig
    painted=()
  fi

  for (( r = 0; r < n; r++ )); do
    (( keep[r] )) || continue
    (( ++at ))
    (( full )) || [[ ${frame[r]} != "${painted[r]}" ]] || continue
    painted[r]=${frame[r]}
    # A control character in the data would move the cursor off the row
    row=${frame[r]//[$'\n\r\t\b\v\f']/ }
    # Plain SGR before the erase, so it doesn't fill the row with a colour.
    # A full paint clears the last row together with everything below it
    # before writing it, rather than clearing after it: with autowrap off
    # the cursor stays on the row's last cell, and an erase from there would
    # take the panel's corner with it (the panel fills the pane's width).
    # Clearing from the row itself also never moves the cursor below the
    # panel - a move past the bottom of the window is clamped onto the last
    # row, and the window can be smaller than the tty size says (while
    # another docker client is attached at a different size).
    if (( full && r == last )); then
      out+=$'\e['"$at"$';1H\e[0m\e[J'"$row"
    else
      out+=$'\e['"$at"$';1H\e[0m\e[2K'"$row"
    fi
    # With autowrap off, the overflow of a row wider than the window is all
    # written into the last column, so its final character is what shows
    # there. A panel row ends in its border, which then closes the panel at
    # the window's edge; any other row gets a space, so it is cut cleanly.
    [[ $row == *[│╮╯] ]] || out+=" "
  done

  printf '%s\e[0m\e[H' "$out"
}

# Headless: the state as one plain line, written to the log when it changes
statusLine() {
  local line
  case $view in
    conn) line="connected${ipShown:+, public IP $ipShown}${ctn:+ ($ctn)}" ;;
    sso)  line="SSO sign-in pending: $sso" ;;
    down)
      if (( ovpnUp )); then
        line="disconnected, waiting for outbound connectivity"
      else
        line="disconnected: ${stopWhy:-OpenVPN is not running}, run vpn-restart"
      fi ;;
  esac
  [[ $line == "$lastLine" ]] && return
  lastLine=$line
  printf '%(%F %T)T %s\n' -1 "$line"
}

display() {
  trap ctrlC SIGTERM SIGINT SIGQUIT

  # now: the clock for this tick, read once so sampling, building and painting
  # agree on which second it is
  local -i now=$EPOCHSECONDS rw=0 gr=0 tick=0 phase=$EPOCHSECONDS termRows=10 termCols=66 st=1 \
    shown=-1 since=0 next=0 lastSec=0 ifUp=0 fullDue=1 paintedAt=0 builtAt=0
  local row view grad badge badgeShort stateFg stateBg cs ccPid route pip="" pingPid="" sso=""
  local paintedSig="" builtView="" builtLayout="" priv pingFile lookupFile stopWhy="" lastLine=""
  local -i ovpnUp=1 d headless=0
  local latency="" latText="" rxPrev="" txPrev="" prevT=0
  local rxText="" txText="" rxSpark="" txSpark="" latSpark="" agoText="???" agoCompact="???"
  local ip="" ipShown="" ipNote="Looking up the public IP..." ctn="" cc="" flag=""
  local host="" hostShown osVer vpnVer sshPort portShown ovpnShown
  local -a frame dropOrder painted rxHist txHist latHist

  auroraInit

  # Everything shown that comes from outside as plain text (see plainText)
  plainText osVer "$(cat /etc/alpine-release)"
  plainText vpnVer "$(openvpn --version | head -n1 | awk '{print $1 " " $2}')"
  plainText portShown "$PORT"
  plainText ovpnShown "$OVPNFILE"
  sshHostPort sshPort
  { read -r host < /etc/hostname; } 2>/dev/null
  plainText host "$host"
  fitText hostShown "$host" 31

  # Files only root can get at for the ping and lookup results: /tmp is
  # writable by the ssh user, who could plant a FIFO or a symlink there
  priv=$(mktemp -d /tmp/jumpbox.XXXXXX 2>/dev/null) || priv=""
  pingFile=$priv/ping lookupFile=$priv/lookup

  # No terminal on stdout (docker run -d, or -i without -t): there's no panel
  # to paint. The loop still keeps house once a second (connCheck, /.stop),
  # and the log gets a plain line whenever the state changes.
  [[ -t 1 ]] || headless=1

  winch=0
  if (( ! headless )); then
    # Nothing reads the keyboard while the frame is up, so keys shouldn't be
    # able to touch it: no echo (an echoed Enter on the bottom row scrolls the
    # terminal), no Ctrl-S output stop, and no Ctrl-Z, which stopped this loop
    # for good since nothing in the container would ever continue it. Ctrl-C
    # still works. ctrlC and the /.stop exit put the saved modes back.
    ttyMode=$(stty -g 2>/dev/null)
    stty -echo -ixon susp undef 2>/dev/null

    # A resize gets the size re-read on the next tick, within 0.2s
    trap 'winch=1' WINCH

    # Anything bash itself has to say from here on - an error, a job notice
    # such as "Quit sleep 0.2" when Ctrl-\ takes the nap down with it - goes
    # to a log rather than over the panel. (Headless, it stays in docker
    # logs, which is where anyone will look.)
    exec 2>>/var/log/jumpbox-display.log
    termSize
  fi

  # The panel goes up straight away, while the public IP is looked up
  now=$EPOCHSECONDS lastSec=$now
  auroraSample
  { read -r cs < "$sfile"; } 2>/dev/null
  [[ $cs == [01] ]] && st=$cs
  if (( st == 0 )); then view=conn; else view=down; fi
  if (( ! headless )); then
    auroraState
    auroraBuild
    paintFrame
  fi

  auroraLookup "$lookupFile" </dev/null >/dev/null 2>&1 &
  disown "$!" 2>/dev/null

  while true; do
    # Check if we should exit. The frame is cleared (scrollback kept) so the
    # host's prompt doesn't land on top of it, at the parked cursor.
    if [[ -f "/.stop" ]]; then
      if (( ! headless )); then
        printf '\e[0m\e[H\e[2J\e[?25h\e[?7h\e[?5l\e[4l\e[20l'
        [[ -n $ttyMode ]] && stty "$ttyMode" 2>/dev/null
        tput cnorm 2>/dev/null
        tput smam 2>/dev/null
      fi
      exit 0
    fi

    # Throw away anything typed or pasted. Nothing reads the keyboard, and
    # once the tty's input buffer is full of unread lines a Ctrl-C waits
    # behind them for good.
    for (( d = 0; d < 200; d++ )); do
      read -r -t 0 || break
      read -r -t 0.05 _ || break
    done

    # Connection state as connCheck last wrote it. A read that lands while the
    # file is being rewritten comes back empty - keep the previous state then.
    cs=""
    { read -r cs < "$sfile"; } 2>/dev/null
    [[ $cs == [01] ]] && st=$cs
    now=$EPOCHSECONDS

    # A resize also gets a full paint: the terminal may have reflowed or
    # cleared what was there
    if (( headless )); then
      :
    elif (( winch )); then
      winch=0 fullDue=1
      termSize
    elif (( now != lastSec )); then
      termSize
    fi
    if (( now != lastSec )); then
      lastSec=$now
      auroraSample
    fi

    # Connectivity details every 5s while connected and every 3s while not,
    # and straight away when the state flips. A refresh due more than 5s out
    # means the clock stepped back (e.g. resynced after the Mac slept).
    if (( st != shown || now >= next || next - now > 5 )); then
      # Respawn the connectivity checker if it died, otherwise $sfile goes stale
      # and the status freezes on the last known state
      ccPid=""
      { read -r ccPid < /.conn_check_pid; } 2>/dev/null
      kill -0 "$ccPid" 2>/dev/null || connCheck

      if (( st == 0 )); then
        sso="" ovpnUp=1 stopWhy=""
        # Ping the tunnel's gateway, in the background so the animation
        # doesn't stall on it. No 0.0.0.0/1 route on split tunnels, so
        # nothing to measure latency to. -W1: busybox ping otherwise waits
        # 10s for a reply that may never come.
        route=$(ip route show 0.0.0.0/1 2>/dev/null)
        pip=""
        [[ $route =~ via\ ([0-9.]+) ]] && pip=${BASH_REMATCH[1]}
        if (( ! headless )) && [[ -n $pip && -z $pingPid ]]; then
          ping -q -c1 -W1 "$pip" > "$pingFile" 2>/dev/null &
          pingPid=$!
          # Off the job table, so its exit never prints a notice over the frame
          disown "$pingPid" 2>/dev/null
        fi
      elif pgrep -x openvpn >/dev/null; then
        ovpnUp=1 sso=$(ssoPending)
      else
        # Nothing is retrying (it gave up after a failed or lapsed sign-in,
        # was stopped by vpn-restart, or died): say so rather than spin, and
        # why when that's known
        ovpnUp=0 sso=""
        stoppedWhy
      fi

      shown=$st
      since=$now
      next=$(( since + (st == 0 ? 5 : 3) ))
    fi

    if (( st == 0 )); then
      view=conn
    elif [[ -n $sso ]]; then
      view=sso
    else
      view=down
    fi
    if (( headless )); then
      statusLine
      sleep 1
      continue
    fi

    phase=$now
    auroraState
    auroraBuild
    paintFrame
    tick+=1

    # A foreground nap rather than a backgrounded sleep and `wait`: bash
    # longjmps out of `wait` for a trapped signal, so a resize landing
    # together with a docker stop (SIGTERM) or Ctrl-C lost the other signal.
    # A foreground child just holds both traps until it exits.
    sleep 0.2
  done
}
