#!/bin/sh

# The motd: what a root shell in the container shows before its first
# prompt (docker exec -it <container> sh -l, or bash -l). The state of the
# tunnel and its details, the ways in, the aliases a CUSTOMCONF script set
# up and where to look when something's wrong, in the status panel's
# colours, laid out for the size of the terminal. ~/.profile runs it for
# interactive shells only. It only reads the container: nothing over the
# network, and some two dozen short-lived processes.

# ~/.profile starts it with sh (busybox ash); the rest is bash
[ -n "$BASH_VERSION" ] || exec bash "$0" "$@"
# Ctrl-C ends it and nothing more. Killed by the signal, it would take the
# rest of ~/.profile with it, and the aliases set up there.
trap 'exit 0' INT

# motdCollect reads everything the motd shows from the container itself
# into the variables below; anything that isn't known is left empty.
# Everything that comes from outside (the environment, the OpenVPN log,
# /etc/profile, resolv.conf, mount points, alias names) is checked against
# what it should look like and passed through plainText, so it can't move
# the cursor or break a border.
#
# view        conn | down | sso, decided as the status panel decides it
# ovpnUp      1 while an openvpn process runs
# starting    1 while start.sh is still on its way to starting OpenVPN (view
#             down), 2 while it waits there for the one-time code (OTP=true)
# stopWhy     why OpenVPN stopped, when it did and that's known
# ssoUrl      the pending SSO sign-in URL (view sso)
# upSecs      seconds since the tunnel last came up; upText "3h 52m"
# ageSecs     seconds since the container started; ageText "1d 20h"
# ip          the public (exit) IP the panel looked up at startup
# ipNote      why there's no ip: "Looking up the public IP..." or "Unable to determine"
# cc ctn flag the exit country: code, name (24 cells at most), flag (2 cells)
# dcn host    the DCN display name; the hostname, which docker exec takes
# port        the SOCKS5 host port (PORT); sshPort the SSH host port
# ovpn        the profile's file name (OVPNFILE)
# auth        sso | otp | password | certificate
# server      the VPN server's address:port, or the name:port that didn't
#             resolve; proto UDP | TCP
# logWhole    1 when all of the OpenVPN log was read (it's under the 2 MB read)
# cipher      the data channel cipher, e.g. AES-256-GCM
# tlsVer      the control channel's TLS version, e.g. TLSv1.3
# kex         the TLS key agreement, e.g. X25519MLKEM768; pq 1 when post-quantum
# tunIp       tun0's IPv4 address/prefix; gw the gateway of a full-tunnel route
# tunnelMode  full (all traffic) | split; routeCount: tun0 routes when split
# dns         the nameservers in resolv.conf (array); dnsSearch its search domains
# rxBytes txBytes, rxText txText   tun0's byte counters, raw and "1.2 GiB"
# killSwitch  on | off (IPv4 OUTPUT policy; empty when not root)
# v6Blocked   1 | 0 (IPv6 OUTPUT policy; empty when not root)
# socksUp sshUp   1 when something listens on 1080 / 22
# watcherUp   1 while the connection watcher (connCheck) runs
# vpnVer osVer    "OpenVPN 2.7.7", "3.24.2"
# aliases     the alias names defined in ~/.profile (array)
# mounts      directories mounted from outside the image, "path ro|rw" (array)

# fmtAgo <var> <seconds>: the two largest units - 2d 4h, 3h 52m, 5m 12s, 40s
fmtAgo() {
  local -i _s=$2
  if (( _s >= 86400 )); then
    printf -v "$1" '%dd %dh' $(( _s / 86400 )) $(( _s % 86400 / 3600 ))
  elif (( _s >= 3600 )); then
    printf -v "$1" '%dh %dm' $(( _s / 3600 )) $(( _s % 3600 / 60 ))
  elif (( _s >= 60 )); then
    printf -v "$1" '%dm %ds' $(( _s / 60 )) $(( _s % 60 ))
  else
    printf -v "$1" '%ds' "$_s"
  fi
}

motdCollect() {
  local cs="" last="" l k v rest p la st mp opts upt pid1="" seen="" peer
  local -a f lv
  local -i now=$EPOCHSECONDS

  # The connection state, as the panel works it out, but never connected
  # with no OpenVPN running: the watcher can take 5s to see it's gone. No
  # OpenVPN yet while start.sh still has its marker is starting, not
  # stopped (and the last run's reason no longer stands); 2 while it waits
  # for the one-time code on its console (the marker says otp).
  view=down ovpnUp=0 starting=0 ssoUrl="" stopWhy=""
  { read -r cs < /.conn_check; } 2>/dev/null
  pgrep -x openvpn >/dev/null && ovpnUp=1
  if [[ $cs == 0 ]] && (( ovpnUp )); then
    view=conn
  elif (( ovpnUp )); then
    ssoUrl=$(ssoPending)
    [[ -n $ssoUrl ]] && view=sso
  elif [[ -e /run/jumpbox/starting ]]; then
    starting=1 l=""
    { read -r l < /run/jumpbox/starting; } 2>/dev/null
    [[ $l == otp ]] && starting=2
  else
    stoppedWhy
  fi

  # Since the tunnel last came up (up.sh stamps it on every connect), and
  # since the container started (PID 1's start, in clock ticks after boot)
  upSecs="" upText="" ageSecs="" ageText=""
  { read -r last < /tmp/last; } 2>/dev/null
  if [[ $last =~ ^[0-9]+$ ]]; then
    upSecs=$(( now - 10#$last ))
    (( upSecs < 0 )) && upSecs=0
    fmtAgo upText "$upSecs"
  fi
  { read -r upt _ < /proc/uptime; read -r pid1 < /proc/1/stat; } 2>/dev/null
  read -ra f <<<"${pid1##*) }"
  if [[ ${upt%%.*} =~ ^[0-9]+$ && ${f[19]} =~ ^[0-9]+$ ]]; then
    ageSecs=$(( ${upt%%.*} - f[19] / 100 ))
    (( ageSecs < 0 )) && ageSecs=0
    fmtAgo ageText "$ageSecs"
  fi

  # The exit IP and country the panel wrote to /etc/profile once its lookup
  # finished. Read rather than sourced: nothing in there gets to run. No IP
  # line yet means the lookup is still going; an empty one that it failed.
  ip="" cc="" ctn="" flag="" ipNote=""
  while IFS= read -r l; do
    [[ $l =~ ^export\ (IP|CC|CTN)=\"(.*)\"$ ]] || continue
    case ${BASH_REMATCH[1]} in
      IP)  ip=${BASH_REMATCH[2]} seen=1 ;;
      CC)  cc=${BASH_REMATCH[2]} ;;
      CTN) ctn=${BASH_REMATCH[2]} ;;
    esac
  done < /etc/profile
  [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || ip=""
  if [[ -z $ip ]]; then
    if [[ -n $seen ]]; then ipNote="Unable to determine"; else ipNote="Looking up the public IP..."; fi
  fi
  [[ $cc =~ ^[A-Za-z]{2}$ ]] || cc=""
  cc=${cc^^}
  [[ -n $cc ]] && flag=$(getFlagEmoji "$cc")
  plainText ctn "$ctn"
  fitText ctn "$ctn" 24

  # How to reach it, as docker run set it up
  plainText dcn "${DCN:-}"
  host=""
  { read -r host < /etc/hostname; } 2>/dev/null
  plainText host "$host"
  plainText port "${PORT:-}"
  [[ -n $port ]] || port="?"
  sshHostPort sshPort
  plainText ovpn "${OVPNFILE:-}"
  if [[ $SSO == true ]]; then
    auth=sso
  elif [[ $OTP == true ]]; then
    auth=otp
  elif [[ -n $AUTHFILE ]]; then
    auth=password
  else
    auth=certificate
  fi

  # The server, the ciphers and the key agreement, as OpenVPN last logged
  # them: the current connection's, or the last one's while it reconnects.
  # The server from its link line, else from each try at a TCP one (that
  # line comes only once it's connected), else the name that didn't
  # resolve - those two only when they look like one, as a route's name
  # that didn't resolve is logged the same way ("name:[AF_INET]"). And
  # whether that was all of the log: a server that isn't in it isn't logged
  # yet, rather than further back than is read.
  server="" proto="" cipher="" tlsVer="" kex="" pq=0 logWhole=0
  mapfile -t lv < <(tail -c 2000000 /var/log/openvpn.log 2>/dev/null | awk -v q="'" '
    { n += length($0) + 1 }
    / link remote: \[AF_INET/ {
      s = $0; sub(/.* link remote: \[AF_INET6?\]/, "", s); server = s
      proto = ""; if (match($0, /(UDP|TCP)v[46]/)) proto = substr($0, RSTART, 3)
    }
    / Attempting to establish TCP connection with \[AF_INET/ {
      s = $0; sub(/.* connection with \[AF_INET6?\]/, "", s); sub(/ .*/, "", s)
      if (s ~ /^[0-9A-Fa-f.:]+$/) { server = s; proto = "TCP" }
    }
    /RESOLVE: Cannot resolve host address: / {
      s = $0; sub(/.*RESOLVE: Cannot resolve host address: /, "", s); sub(/ .*/, "", s)
      if (s ~ /^[A-Za-z0-9.-]+:[0-9]+$/) { server = s; proto = "" }
    }
    /Data Channel: [Cc]ipher / {
      if (match($0, "[Cc]ipher " q "[^" q "]+" q)) cipher = substr($0, RSTART + 8, RLENGTH - 9)
    }
    /Control Channel: TLSv/ {
      if (match($0, /Control Channel: TLSv[0-9.]+/)) tls = substr($0, RSTART + 17, RLENGTH - 17)
      k = ""
      if (match($0, /key agreement: [A-Za-z0-9_-]+/)) k = substr($0, RSTART + 15, RLENGTH - 15)
      else if (match($0, /peer temporary key: [0-9]+ bits [A-Za-z0-9_-]+/)) { k = substr($0, RSTART, RLENGTH); sub(/.* /, "", k) }
      kex = k
    }
    END { print server; print proto; print cipher; print tls; print kex; print n + 0 }')
  [[ ${lv[0]} =~ ^[0-9A-Fa-f.:]+$ || ${lv[0]} =~ ^[A-Za-z0-9.-]+:[0-9]+$ ]] && server=${lv[0]}
  # An IPv6 address in brackets, so its port reads as one: [2001:db8::10]:1194
  [[ $server == *:*:* ]] && server="[${server%:*}]:${server##*:}"
  [[ ${lv[1]} =~ ^(UDP|TCP)$ ]] && proto=${lv[1]}
  [[ ${lv[2]} =~ ^[A-Za-z0-9-]+$ ]] && cipher=${lv[2]^^}
  [[ ${lv[3]} =~ ^TLSv[0-9.]+$ ]] && tlsVer=${lv[3]}
  if [[ ${lv[4]} =~ ^[A-Za-z0-9_-]+$ ]]; then
    kex=${lv[4]}
    [[ ${kex,,} =~ ^x(25519|448)$ ]] && kex=${kex^^}
    [[ ${kex^^} == *MLKEM* || ${kex^^} == *KYBER* ]] && pq=1
  fi
  [[ ${lv[5]} =~ ^[0-9]+$ ]] && (( lv[5] < 2000000 )) && logWhole=1

  # The tunnel's own address, and whether everything goes down it (the
  # def1 pair or a default route) or only some networks
  tunIp="" gw="" tunnelMode="" routeCount=0 peer=""
  l=$(ip -4 -o addr show dev tun0 2>/dev/null)
  # "inet 10.8.0.6/24", or on a point-to-point tunnel (topology net30, the
  # default before OpenVPN 2.7, and p2p) "inet 10.78.0.6 peer 10.78.0.5/32"
  if [[ $l =~ inet\ ([0-9.]+)(\ peer\ ([0-9.]+))?/([0-9]+) ]]; then
    tunIp=${BASH_REMATCH[1]}/${BASH_REMATCH[4]} peer=${BASH_REMATCH[3]}
  fi
  while IFS= read -r l; do
    [[ $l == *" dev tun0"* ]] || continue
    case $l in
      "0.0.0.0/1 "*|"128.0.0.0/1 "*|"default "*)
        tunnelMode=full
        [[ $l =~ via\ ([0-9.]+) ]] && gw=${BASH_REMATCH[1]} ;;
      *" via "*)
        # Not what a net30 server pushes for its own end of the tunnel (its
        # address, or with client-to-client the whole pool): a route into
        # the tunnel's own /24 via the peer, the /24 standing in for a pool
        # whose size isn't known here. One the admin pushed into it goes
        # uncounted with it, and from a pool wider than that, the server's
        # own route still counts.
        [[ -n $peer && $l == "${tunIp%.*}."* && $l == *" via $peer "* ]] && continue
        (( routeCount += 1 )) ;;
    esac
  done < <(ip -4 route show 2>/dev/null)
  [[ -z $tunnelMode && -n $tunIp ]] && tunnelMode=split

  # DNS as resolv.conf has it (up.sh writes the pushed servers there), read
  # as musl reads it: only lines that start in the first column and are
  # under 255 bytes (it skips longer ones); the first three nameservers
  # that are addresses (an IPv6 one's %scope left off); the last search (or
  # domain) line, a bare one clearing it. Addresses and domain names,
  # nothing else.
  dns=() dnsSearch=""
  while IFS= read -r l || [[ -n $l ]]; do
    (( ${#l} < 255 )) || continue
    l=${l%$'\r'}
    if [[ $l =~ ^nameserver[[:space:]]+([^[:space:]]+) ]]; then
      v=${BASH_REMATCH[1]%%\%*}
      [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || ( $v == *:*:* && $v =~ ^[0-9A-Fa-f.:]+$ ) ]] \
        && (( ${#dns[@]} < 3 )) && dns+=("$v")
    elif [[ $l =~ ^(search|domain)([[:space:]](.*))?$ ]]; then
      dnsSearch=""
      read -ra f <<<"${BASH_REMATCH[3]}"
      for v in "${f[@]}"; do
        [[ $v =~ ^[A-Za-z0-9._-]+$ ]] && dnsSearch+="${dnsSearch:+ }$v"
      done
    fi
  done 2>/dev/null < /etc/resolv.conf

  rxBytes="" txBytes="" rxText="" txText=""
  { read -r rxBytes < /sys/class/net/tun0/statistics/rx_bytes
    read -r txBytes < /sys/class/net/tun0/statistics/tx_bytes; } 2>/dev/null
  if [[ $rxBytes =~ ^[0-9]+$ && $txBytes =~ ^[0-9]+$ ]]; then
    humanBytes rxText "$rxBytes"
    humanBytes txText "$txBytes"
  else
    rxBytes="" txBytes=""
  fi

  # The kill switch is the OUTPUT policies killSwitch set: only root can
  # read them
  killSwitch="" v6Blocked=""
  if (( EUID == 0 )); then
    l=""
    { read -r l; } < <(iptables -S OUTPUT 2>/dev/null)
    case $l in "-P OUTPUT DROP") killSwitch=on ;; "-P OUTPUT ACCEPT") killSwitch=off ;; esac
    l=""
    { read -r l; } < <(ip6tables -S OUTPUT 2>/dev/null)
    case $l in "-P OUTPUT DROP") v6Blocked=1 ;; "-P OUTPUT ACCEPT") v6Blocked=0 ;; esac
  fi

  # Listening sockets, straight from the kernel: the sshd listener renames
  # itself, so busybox pgrep -x can't find it
  socksUp=0 sshUp=0
  for p in /proc/net/tcp /proc/net/tcp6; do
    [[ -r $p ]] || continue
    while read -r _ la _ st _; do
      [[ $st == 0A ]] || continue
      case ${la##*:} in
        0438) socksUp=1 ;;
        0016) sshUp=1 ;;
      esac
    done < "$p"
  done

  # Its process still there (not kill -0, which another user can't send to
  # root's processes)
  watcherUp=0 p=""
  { read -r p < /.conn_check_pid; } 2>/dev/null
  [[ $p =~ ^[0-9]+$ && -d /proc/$p ]] && watcherUp=1

  osVer=""
  { read -r osVer < /etc/alpine-release; } 2>/dev/null
  plainText osVer "$osVer"
  k="" v=""
  { read -r k v _; } < <(openvpn --version 2>/dev/null)
  plainText vpnVer "$k $v"
  [[ $vpnVer == "OpenVPN "* ]] || vpnVer=""

  # Aliases a CUSTOMCONF script added to ~/.profile (they're defined after
  # this runs, so the file is all there is to go on): every name= on an
  # alias line, after any options (alias -- x=..., alias a='...' b='...'),
  # in the alias commands chained on after it (; alias b=..., && alias
  # ...), and quoted along with its value ('ll=ls -la') too; each name
  # once, as a script run on every start adds its lines again each time (a
  # line seen before is passed over whole). A value is quoted and plain
  # stretches, with backslash escapes, ending where the line does, a blank
  # begins or the shell's ; & | < > ( ) would, so it can't be taken for less
  # or more than it is.
  aliases=()
  local -A known=() lseen=()
  local q="'" val tail next
  val="(${q}[^${q}]*${q}|\"([^\"\\\\]|\\\\.)*\"|[^[:space:]${q}\"\\\\;&|<>()]|\\\\.)*"
  tail='(([[:space:];&|<>()].*)?)$'
  next='^[[:space:]]*(;|&&)[[:space:]]*alias(([[:space:]].*)?)$'
  if [[ -r $HOME/.profile ]]; then
    while IFS= read -r l || [[ -n $l ]]; do
      [[ $l =~ ^[[:space:]]*alias([[:space:]].*)$ ]] || continue
      rest=${BASH_REMATCH[1]}
      [[ -n ${lseen[$l]} ]] && continue
      lseen[$l]=1
      while [[ $rest =~ ^[[:space:]]+(-[^[:space:]=]*)(([[:space:]].*)?)$ ]]; do
        rest=${BASH_REMATCH[2]}
        [[ ${BASH_REMATCH[1]} == -- ]] && break
      done
      while :; do
        [[ $rest =~ ^([[:space:]]+)([${q}\"])([A-Za-z0-9_.:+@%-]+=)(.*)$ ]] \
          && rest=${BASH_REMATCH[1]}${BASH_REMATCH[3]}${BASH_REMATCH[2]}${BASH_REMATCH[4]}
        [[ $rest =~ ^[[:space:]]+([A-Za-z0-9_.:+@%-]+)=$val$tail ]] || break
        k=${BASH_REMATCH[1]} rest=${BASH_REMATCH[4]}
        [[ $rest =~ $next ]] && rest=${BASH_REMATCH[2]}
        [[ -n ${known[$k]} ]] && continue
        known[$k]=1
        aliases+=("$k")
      done
    done < "$HOME/.profile"
  fi

  # Directories mounted in from outside the image: /vpn, and anything else
  # given with -v. mountinfo escapes a space, tab, newline and backslash in
  # a path (\040 \011 \012 \134), so those come back first, the backslash
  # last.
  mounts=()
  while read -r _ _ _ _ mp opts _; do
    case $mp in
      /|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/etc/hostname|/etc/hosts|/etc/resolv.conf) continue ;;
    esac
    mp=${mp//\\040/ } mp=${mp//\\011/$'\t'} mp=${mp//\\012/$'\n'} mp=${mp//\\134/\\}
    [[ -d $mp ]] || continue
    plainText mp "$mp"
    if [[ ,$opts, == *,ro,* ]]; then mounts+=("$mp ro"); else mounts+=("$mp rw"); fi
  done < /proc/self/mountinfo
}

# The welcome screen (motd): the status panel (Aurora) grown into a full
# screen. JUMPBOX in big letters inside a panel-style frame, both in the
# state's border gradient, the panel's badge beside it, then rounded cards
# with the same gradient borders: violet labels, white values, cyan for what
# gets typed, dim for what's out of date. Printed once, top to bottom, as
# plain lines: no cursor movement, so it scrolls away like any other output.
#
# Four layouts, the first that fits is used: wide (100 columns and up,
# never more than 116 used) has the big banner and ACCESS and TUNNEL side
# by side; medium (60 and up) a small logo and a card a row; compact one
# panel like the status panel's compact one, 14 rows at most; tiny three
# lines. The height they get (budget) is the pane's less the prompt's rows
# - more than one when it wraps - and a spare, so the top never scrolls
# away; 30 at most. Each layout has knobs for what it shows and one list of
# steps, each giving one thing up, in priority order: the richest
# arrangement that fits is used (auroraMotdFit; the lists are where each
# layout calls it).
#
# The banner's state block is made of parts (auroraMotdUnit): the badge and
# what it's doing, CAUTION's line or why it's down and what to run, what's
# wrong, the exit, the checks, the traffic. They go beside the logo, but an
# alert line - CAUTION's, why it's down and what to run, what's wrong -
# that would wrap there goes under the logo, across the banner, as the
# panel's alert row runs across the panel; the exit, the checks and the
# traffic go on under it too, once the rows beside the logo are filled,
# when that's no taller or the height needs it (auroraMotdState).
#
# Connected with a protection known to be off - the kill switch, IPv6, a
# listener, the watcher - is CAUTION: the panel's CONNECTED badge, an amber
# line saying how many checks need attention, and the frame in amber.
#
# The data comes from motdCollect (above) as plain text, one cell a
# character (the flag is two), so ${#s} is a width in cells. Rows are put
# together with inc.sh's row* helpers, and nothing is wider than the room it
# was given: a value too long for its card wraps where it may, a list that
# doesn't fit ends in "+N more", and only what still can't fit is cut with
# an ellipsis. The gradient is coloured as rowGrad colours the panel's
# border (by column and row, so it runs on from card to card), but from
# rings worked out once, as rowGrad's per-character loop was most of the
# time. Helpers that fill a caller's variable use _-prefixed locals.

# auroraMotdPiece <piece> [<end>]: one piece of a value onto the row. Every
# value here is a list of pieces, each a one-letter code and its text:
#   w d f    white, dim, faint        v c    violet (labels), cyan (typed)
#   g r a    green, red, amber        F      the flag (two cells)
#   S R C P Q  chips, on a background: the state's badge, a problem, an
#            alias, post-quantum, post-quantum from a connection that's gone
# A piece "|<code><text>" is a place the value may wrap, <text> the
# separator written when it doesn't (auroraMotdItem); "|n" always wraps.
# Pieces that travel as one, a token (auroraMotdFlow, auroraMotdSpread),
# are joined by newlines. With <end>, the text is cut with an ellipsis so
# the row stops by that column (the flag, which can't be cut in half, is
# left out instead).
auroraMotdPiece() {
  local _k=${1:0:1} _t=${1:1}
  if [[ -n $2 ]] && (( rw + ${#_t} > $2 )); then
    [[ $_k == F ]] && return 0
    fitText _t "$_t" $(( $2 - rw ))
  fi
  # Chips end their background (and bold) where they end (pieceEnd)
  row+=${pieceColour[$_k]}$_t${pieceEnd[$_k]} rw+=${#_t}
  return 0
}

# auroraMotdToken <pieces> [<end>]: newline-joined pieces onto the row
auroraMotdToken() {
  local _t=$1 _p _k
  while :; do
    # auroraMotdPiece, inlined: every row goes through here
    _p=${_t%%$'\n'*}
    _k=${_p:0:1} _p=${_p:1}
    if [[ -n $2 ]] && (( rw + ${#_p} > $2 )); then
      if [[ $_k == F ]]; then _p=""; else fitText _p "$_p" $(( $2 - rw )); fi
    fi
    row+=${pieceColour[$_k]}$_p${pieceEnd[$_k]} rw+=${#_p}
    [[ $_t == *$'\n'* ]] || break
    _t=${_t#*$'\n'}
  done
}

# auroraMotdFill <cells>: that many ─ in the gradient, a slice of the ring
# of coloured dashes (dashRing, the gradient three times over)
auroraMotdFill() {
  (( $1 > 0 )) || return 0
  local IFS=
  row+="${dashRing[*]:(rw + gr * 2 + phase) % ringN:$1}"
  rw+=$1
}

# auroraMotdGlyph <text>: border glyphs in the gradient, one by one
auroraMotdGlyph() {
  local -i _i
  for (( _i = 0; _i < ${#1}; _i++ )); do
    row+="${gradRef[(rw + gr * 2 + phase) % ringN]}${1:_i:1}"
    rw+=1
  done
}

# auroraMotdItem <cells> <label cells> <label> <piece>...: a label piece
# and its value as rows <cells> wide, onto the caller's cRows[] and cW[]. A
# piece "|<code><text>" is a place the value may wrap: when the rest, up to
# the next such place, doesn't fit, a new row starts under the value
# instead of <text> (the separator) being written; "|n" always starts one.
# A first stretch too long to go beside its label gets a row of its own at
# the full width when that holds it whole - a command stays whole, so it
# can be copied - else it stays beside the label and is cut there.
auroraMotdItem() {
  local -i _iw=$1 _in=$2 _i _j _ww=0 _n=$(( $# - 3 )) _all=0
  local _pc _k _t _s
  local -a _pcs=("${@:4}")
  for (( _j = 0; _j < _n; _j++ )); do
    [[ ${_pcs[_j]} == '|'* ]] && break
    _ww+=$(( ${#_pcs[_j]} - 1 ))
  done
  # All of it on the one row, its label's too: no place to wrap is needed
  _all=_ww
  for (( ; _j < _n; _j++ )); do
    _pc=${_pcs[_j]}
    if [[ $_pc != '|'* ]]; then
      _all+=$(( ${#_pc} - 1 ))
    elif [[ $_pc == '|n' ]]; then
      _all=_iw+1
      break
    else
      _all+=$(( ${#_pc} - 2 ))
    fi
  done
  if (( (${#3} ? (${#3} - 1 > _in ? ${#3} - 1 : _in) : _in) + _all <= _iw )); then
    row="" rw=0
    [[ -n $3 ]] && auroraMotdPiece "$3"
    if (( _in > rw )); then printf -v _s '%*s' $(( _in - rw )) ''; row+=$_s rw=_in; fi
    for _pc in "${_pcs[@]}"; do
      _pc=${_pc#|} _k=${_pc:0:1}
      row+=${pieceColour[$_k]}${_pc:1}${pieceEnd[$_k]}
    done
    rw+=_all
    cRows+=("$row"); cW+=("$rw")
    return 0
  fi
  row="" rw=0
  if [[ -n $3 ]]; then
    auroraMotdPiece "$3" "$_iw"
    if (( _in + _ww > _iw && _ww <= _iw )); then
      cRows+=("$row"); cW+=("$rw")
      row="" rw=0 _in=0
    fi
  fi
  if (( _in > rw )); then printf -v _s '%*s' $(( _in - rw )) ''; row+=$_s rw=_in; fi
  for (( _i = 0; _i < _n; _i++ )); do
    _pc=${_pcs[_i]}
    if [[ $_pc == '|'* ]]; then
      if [[ $_pc == '|n' ]]; then
        _ww=_iw+1
      else
        _ww=$(( ${#_pc} - 2 ))
        for (( _j = _i + 1; _j < _n; _j++ )); do
          [[ ${_pcs[_j]} == '|'* ]] && break
          _ww+=$(( ${#_pcs[_j]} - 1 ))
        done
      fi
      if (( rw + _ww > _iw )); then
        if (( rw > _in )); then
          cRows+=("$row"); cW+=("$rw")
          printf -v row '%*s' "$_in" ''; rw=_in
        fi
        continue
      fi
      _pc=${_pc:1}
    fi
    # auroraMotdPiece, inlined: this is the hot loop
    _k=${_pc:0:1} _t=${_pc:1}
    if (( rw + ${#_t} > _iw )); then
      [[ $_k == F ]] && continue
      fitText _t "$_t" $(( _iw - rw ))
    fi
    row+=${pieceColour[$_k]}$_t${pieceEnd[$_k]} rw+=${#_t}
  done
  cRows+=("$row"); cW+=("$rw")
}

# auroraMotdOne <cells> <label cells> <label> <piece>...: an item on one
# row only: from the first stretch that doesn't fit (or a |n), the rest is
# left off whole rather than cut, and so is a separator with no room left
# after it
auroraMotdOne() {
  local -i _iw=$1 _i _j _ww _n=$(( $# - 3 ))
  local _pc _k _t _s
  local -a _pcs=("${@:4}")
  row="" rw=0
  [[ -n $3 ]] && auroraMotdPiece "$3" "$_iw"
  if (( $2 > rw )); then printf -v _s '%*s' $(( $2 - rw )) ''; row+=$_s rw=$2; fi
  for (( _i = 0; _i < _n; _i++ )); do
    _pc=${_pcs[_i]}
    if [[ $_pc == '|'* ]]; then
      [[ $_pc == '|n' ]] && break
      _ww=$(( ${#_pc} - 2 ))
      for (( _j = _i + 1; _j < _n; _j++ )); do
        [[ ${_pcs[_j]} == '|'* ]] && break
        _ww+=$(( ${#_pcs[_j]} - 1 ))
      done
      (( rw + _ww <= _iw )) || break
      _pc=${_pc:1}
    elif [[ $_pc == f* ]] && (( _i + 1 < _n && rw + ${#_pc} - 1 >= _iw )); then
      break
    fi
    _k=${_pc:0:1} _t=${_pc:1}
    if (( rw + ${#_t} > _iw )); then
      [[ $_k == F ]] && continue
      fitText _t "$_t" $(( _iw - rw ))
    fi
    row+=${pieceColour[$_k]}$_t${pieceEnd[$_k]} rw+=${#_t}
  done
  cRows+=("$row"); cW+=("$rw")
}

# auroraMotdAdd <label> <piece>...: an item for auroraMotdGrid, onto the
# caller's gP[] (all the pieces), gS[] (where each item starts) and gN[]
auroraMotdAdd() {
  gS+=("${#gP[@]}"); gN+=("$#"); gP+=("$@")
}

# auroraMotdLine <item> <end> [<leave>]: item number <item> on one line
# from here, its value lw cells in, the places to wrap only separators, cut
# at <end>; <leave> pieces left off its end
auroraMotdLine() {
  local -i _st=$rw _i _s=${gS[$1]} _e=$(( gS[$1] + gN[$1] - ${3:-0} ))
  local _pc _k _t
  auroraMotdPiece "${gP[_s]}" "$2"
  rowTo $(( _st + lw ))
  for (( _i = _s + 1; _i < _e; _i++ )); do
    _pc=${gP[_i]#|}
    [[ $_pc == n ]] && continue
    _k=${_pc:0:1} _t=${_pc:1}
    if (( rw + ${#_t} > $2 )); then
      [[ $_k == F ]] && continue
      fitText _t "$_t" $(( $2 - rw ))
    fi
    row+=${pieceColour[$_k]}$_t${pieceEnd[$_k]} rw+=${#_t}
  done
}

# auroraMotdGrid <cells> <one|two> [<item>...]: the items (auroraMotdAdd)
# one to a row, wrapped as auroraMotdItem wraps them, or - with "two", when
# every pair fits - two to a row, paired in the order given (item numbers;
# as added by default), the second column lined up and an odd one out on a
# row of its own. Onto cRows[] and cW[]; gridTwo set when it was two to a
# row. gridNeed (the caller's) gets the narrowest width that cuts nothing:
# the label and the widest stretch between two places to wrap (with 0
# cells, that's all it does).
auroraMotdGrid() {
  local -i _iw=$1 _n=${#gS[@]} _i _j _e _run _l=0 _r=0
  local -ai _w=()
  local -a _o=("${@:3}")
  # One to a row: nothing to measure
  if [[ $2 == one ]] && (( _iw > 0 )); then
    for (( _i = 0; _i < _n; _i++ )); do auroraMotdItem "$_iw" "$lw" "${gP[@]:gS[_i]:gN[_i]}"; done
    return 0
  fi
  gridNeed=0
  for (( _i = 0; _i < _n; _i++ )); do
    _w[_i]=lw _run=lw _e=$(( gS[_i] + gN[_i] ))
    for (( _j = gS[_i] + 1; _j < _e; _j++ )); do
      if [[ ${gP[_j]} == '|'* ]]; then
        (( _run > gridNeed )) && gridNeed=_run
        _w[_i]+=$(( ${#gP[_j]} - 2 )) _run=lw
      else
        _w[_i]+=$(( ${#gP[_j]} - 1 )) _run+=$(( ${#gP[_j]} - 1 ))
      fi
    done
    (( _run > gridNeed )) && gridNeed=_run
  done
  # 0 cells: only measuring
  (( _iw > 0 )) || return 0
  if [[ $2 == two ]] && (( _n > 1 )); then
    (( ${#_o[@]} )) || for (( _i = 0; _i < _n; _i++ )); do _o+=("$_i"); done
    for (( _i = 0; _i + 1 < ${#_o[@]}; _i += 2 )); do
      (( _w[_o[_i]] > _l )) && _l=_w[_o[_i]]
      (( _w[_o[_i+1]] > _r )) && _r=_w[_o[_i+1]]
    done
    if (( _l + 3 + _r <= _iw )); then
      gridTwo=1
      for (( _i = 0; _i < ${#_o[@]}; _i += 2 )); do
        if (( _i + 1 < ${#_o[@]} )); then
          rowStart
          auroraMotdLine "${_o[_i]}" "$_l"
          rowTo $(( _l + 3 ))
          auroraMotdLine "${_o[_i+1]}" "$_iw"
          cRows+=("$row"); cW+=("$rw")
        else
          # The odd one out, as it would be on its own (a chip right after
          # the value it's about)
          auroraMotdItem "$_iw" "$lw" "${gP[@]:gS[_o[_i]]:gN[_o[_i]]}"
        fi
      done
      return 0
    fi
  fi
  for (( _i = 0; _i < _n; _i++ )); do
    auroraMotdItem "$_iw" "$lw" "${gP[@]:gS[_i]:gN[_i]}"
  done
}

# auroraMotdWords <code> <text>: the text's words onto the caller's pcs[],
# with a place to wrap between each (split by hand, as data must not go
# through pathname expansion)
auroraMotdWords() {
  local _s=$2 _w _sep=""
  while [[ -n $_s ]]; do
    _w=${_s%% *}
    if [[ $_s == *' '* ]]; then _s=${_s#* }; else _s=""; fi
    [[ -n $_w ]] || continue
    [[ -n $_sep ]] && pcs+=("|w ")
    pcs+=("$1$_w")
    _sep=1
  done
}

# auroraMotdFlow <cells> <rows> <gap> <more> <token>...: tokens onto the
# row being built, <gap> cells apart, starting new ones (onto cRows[] and
# cW[]) as they fill, at most <rows> more. What doesn't fit is counted at
# the end (room for the count is kept on the last row unless the rest
# fits): <more> is the count as pieces, %s for "+N" ("N" when none of
# them fit), and goes on a row of its own rather than be left out; after a
# |, a shorter count, for a token alone on its row that would otherwise be
# cut to make room for the long one. A token is newline-joined pieces; one
# too wide even for a row to itself is cut. The last row is left in row for
# the caller.
auroraMotdFlow() {
  local -i _iw=$1 _rows=$2 _gap=$3 _i _n=$(( $# - 4 )) _put=0 _tw _g _res _mw _sh=0
  local _t _p _m
  local -a _tk=("${@:5}") _fmt=("${4%%|*}" "${4#*|}") _wd=() _sf=() _fx=() _fv=()
  local _sp
  printf -v _sp '%*s' "$_gap" 
  # Each token's width, and what it and the ones after it take
  for (( _i = _n - 1; _i >= 0; _i-- )); do
    if [[ ${_tk[_i]} == *$'\n'* ]]; then
      _p=${_tk[_i]//[!$'\n']/}
      _wd[_i]=$(( ${#_tk[_i]} - 2 * ${#_p} - 1 ))
    else
      _wd[_i]=$(( ${#_tk[_i]} - 1 ))
    fi
    _sf[_i]=$(( _wd[_i] + (_i < _n - 1 ? _gap + _sf[_i+1] : 0) ))
  done
  # Each count's width without it being made: its format's, less the %s
  # and the code (and the newlines), and the number's
  for _i in 0 1; do
    _p=${_fmt[_i]//[!$'\n']/} _fv[_i]=0
    [[ ${_fmt[_i]} == *%s* ]] && _fv[_i]=1
    _fx[_i]=$(( ${#_fmt[_i]} - 2 * ${#_p} - 1 - 2 * _fv[_i] ))
  done
  _i=0
  while (( _i < _n )); do
    _t=${_tk[_i]} _tw=${_wd[_i]}
    _g=$(( rw ? _gap : 0 ))
    # On the last row, keep room for the count of the tokens after this one
    # (unless they all fit)
    _res=0
    if (( ! _rows && _i < _n - 1 && rw + _g + _sf[_i] > _iw )); then
      _m="+$(( _n - _i - 1 ))"
      _res=$(( _gap + _fx[_sh] + _fv[_sh] * ${#_m} ))
      if (( ! _sh && ! rw && _tw + _res > _iw )); then
        _mw=$(( _gap + _fx[1] + _fv[1] * ${#_m} ))
        (( rw + _g + _tw + _mw <= _iw )) && _sh=1 _res=_mw
      fi
    fi
    if (( rw + _g + _tw + _res <= _iw )); then
      # A token of one piece (a chip) written here: this is the hot loop
      if [[ $_t == *$'\n'* ]]; then
        rowPad "$_g"
        auroraMotdToken "$_t"
      else
        (( _g )) && row+=${_sp:0:_g} rw+=_g
        row+=${pieceColour[${_t:0:1}]}${_t:1}${pieceEnd[${_t:0:1}]} rw+=_tw
      fi
      _i+=1 _put+=1
      continue
    fi
    if (( rw && _rows )); then
      cRows+=("$row"); cW+=("$rw"); rowStart
      _rows+=-1
      continue
    fi
    if (( ! rw && _iw - _res >= 4 )); then
      auroraMotdToken "$_t" $(( _iw - _res ))
      _i+=1 _put+=1
      continue
    fi
    # Out of room: the rest is counted
    if (( _put )); then
      printf -v _m "${_fmt[_sh]}" "+$(( _n - _i ))"
    else
      printf -v _m "${_fmt[_sh]}" "$(( _n - _i ))"
    fi
    _p=${_m//[!$'\n']/}
    _mw=$(( ${#_m} - 2 * ${#_p} - 1 ))
    if (( rw && rw + _gap + _mw > _iw )); then
      cRows+=("$row"); cW+=("$rw"); rowStart
    fi
    (( rw )) && rowPad "$_gap"
    auroraMotdToken "$_m" "$_iw"
    break
  done
  return 0
}

# auroraMotdWrap <array> <cells> <word>...: the words wrapped at <cells>
# into the named array, a row of text each
auroraMotdWrap() {
  local -n _o=$1
  local _x _ln=""
  _o=()
  for _x in "${@:3}"; do
    if [[ -n $_ln ]] && (( ${#_ln} + 1 + ${#_x} > $2 )); then
      _o+=("$_ln") _ln=$_x
    else
      _ln+=${_ln:+ }$_x
    fi
  done
  [[ -n $_ln ]] && _o+=("$_ln")
}

# auroraMotdMsg <cells> <mark> <code> <text>: a sentence after its mark,
# onto cRows[] and cW[]: on as few rows as it takes, broken where they come
# out most even - the narrowest width that takes no more rows - a word
# like "not" or "for" ending a row moved on to the next (with what it goes
# with: "SSO sign-in / not completed in time") when that costs a few cells
# of evenness at most, and a last word alone given another from the row
# above
auroraMotdMsg() {
  local -i _iw=$(( $1 - 2 )) _k _l _i _m=0
  local -a _w _rows
  local _x
  local IFS=' '
  read -ra _w <<< "$4"
  auroraMotdWrap _rows "$_iw" "${_w[@]}"
  _k=${#_rows[@]}
  if (( _k > 1 )); then
    for (( _l = (${#4} + _k - 1) / _k; _l < _iw; _l++ )); do
      auroraMotdWrap _rows "$_l" "${_w[@]}"
      (( ${#_rows[@]} <= _k )) && break
    done
    (( _l < _iw )) || auroraMotdWrap _rows "$_iw" "${_w[@]}"
    _k=${#_rows[@]}
    for _x in "${_rows[@]}"; do (( ${#_x} > _m )) && _m=${#_x}; done
    for (( _i = 0; _i < _k - 1; _i++ )); do
      _x=${_rows[_i]##* }
      case $_x in
        not|for|to|of|in|after|before|with|the|a|an|and|or) ;;
        *) continue ;;
      esac
      [[ ${_rows[_i]} == *' '*' '* ]] || continue
      (( ${#_x} + 1 + ${#_rows[_i+1]} <= _iw && ${#_x} + 1 + ${#_rows[_i+1]} <= _m + 6 )) || continue
      _rows[_i]=${_rows[_i]% *} _rows[_i+1]="$_x ${_rows[_i+1]}"
    done
    # A last word alone takes another from the row above, if that keeps two
    if [[ ${_rows[_k-1]} != *' '* && ${_rows[_k-2]} == *' '*' '* ]]; then
      _x=${_rows[_k-2]##* }
      if (( ${#_x} + 1 + ${#_rows[_k-1]} <= _iw )); then
        _rows[_k-2]=${_rows[_k-2]% *} _rows[_k-1]="$_x ${_rows[_k-1]}"
      fi
    fi
  fi
  auroraMotdItem "$1" 2 "$2" "$3${_rows[0]}"
  for (( _i = 1; _i < ${#_rows[@]}; _i++ )); do
    auroraMotdItem "$1" 2 "" "$3${_rows[_i]}"
  done
}

# auroraMotdArt <k>: row k of the banner art (art[]) onto the row, in the
# gradient, coloured as the border is. The row becomes a printf format with
# a conversion per cell - %s before a block or a stroke, %.0s for a space -
# fed a slice of gradRing, so a row takes one printf rather than a loop. The
# strokes are artGlyphs; with artShadow they're the font's shadow and take
# the faint colour instead. Cells are marked first, with control bytes
# (which art can't hold), then % and \ in the rest are escaped, then the
# marks become the conversions: whatever the art holds, none of it is read
# as format. A row with a character the glyphs don't list (it comes out
# short of a mark a cell) is marked again the slow way, every character
# that isn't a space or a block a stroke. A row at a time: bash's
# replacements slow down faster than the string grows.
auroraMotdArt() {
  local _a=${art[$1]} _f _g=$artGlyphs _m _c
  local -i _i
  _f=${_a// /$'\1 '} _f=${_f//█/$'\2█'} _f=${_f//▀/$'\2▀'} _f=${_f//▄/$'\2▄'}
  for (( _i = 0; _i < ${#_g}; _i++ )); do
    _c=${_g:_i:1}
    # Each glyph once, and not a space or a block: marked already
    [[ $_c == [' '█▀▄] || ${_g:0:_i} == *"$_c"* ]] && continue
    _f=${_f//"$_c"/$'\3'"$_c"}
  done
  if (( ${#_f} != 2 * ${#_a} )); then
    _m=${_a// /} _m=${_m//█/} _m=${_m//▀/} _m=${_m//▄/}
    _f=${_a// /$'\1 '} _f=${_f//█/$'\2█'} _f=${_f//▀/$'\2▀'} _f=${_f//▄/$'\2▄'}
    while [[ -n $_m ]]; do
      _c=${_m:0:1}
      _f=${_f//"$_c"/$'\3'"$_c"} _m=${_m//"$_c"/}
    done
  fi
  [[ $_f == *[%\\]* ]] && _f=${_f//'\'/'\\'} _f=${_f//'%'/'%%'}
  _f=${_f//$'\1'/'%.0s'} _f=${_f//$'\2'/'%s'}
  if [[ -n $artShadow ]]; then _f=${_f//$'\3'/"%.0s$cFnt"}; else _f=${_f//$'\3'/'%s'}; fi
  printf -v _f "$_f" "${gradRing[@]:(rw + gr * 2 + phase) % ringN:${#_a}}"
  row+=$_f
  rw+=${#_a}
}

# auroraMotdDots <text>: dim text with its " · " separators faint, the way
# the panel writes its versions
auroraMotdDots() {
  local _s=$1
  while [[ $_s == *" · "* ]]; do
    rowAdd "$cDim" "${_s%% · *}"; rowAdd "$cFnt" " · "
    _s=${_s#* · }
  done
  rowAdd "$cDim" "$_s"
}

# auroraMotdTop <width> <flag> <title> [<right>...]: a top border with the
# title on it, as the panel has its name, and the first of the right-hand
# texts (dim) there's room for
auroraMotdTop() {
  local -i _end=$(( rw + $1 ))
  local _t=$3 _r
  auroraMotdGlyph "╭─"; rowPad 1
  [[ -n $2 ]] && rowAdd "" "$2 "
  fitText _t "$_t" $(( _end - rw - 3 ))
  rowAdd "$cBold$cWht" "$_t"; rowAdd "$cOff" " "
  for _r in "${@:4}"; do
    [[ -n $_r ]] && (( _end - rw - ${#_r} - 4 >= 2 )) || continue
    auroraMotdFill $(( _end - rw - ${#_r} - 4 ))
    rowPad 1; auroraMotdDots "$_r"; rowPad 1
    break
  done
  auroraMotdFill $(( _end - rw - 1 ))
  auroraMotdGlyph "╮"
}

# auroraMotdBottom <width> [<left> [<right>]]: a bottom border with text on
# it, as the panel has the profile on its: the right-hand text only whole
# and with a run of border before it, the left one cut to fit
auroraMotdBottom() {
  local -i _end=$(( rw + $1 ))
  local _l=$2 _r=$3
  if [[ -z $_l ]]; then
    auroraMotdGlyph "╰"; auroraMotdFill $(( $1 - 2 )); auroraMotdGlyph "╯"
    return 0
  fi
  auroraMotdGlyph "╰─"; rowPad 1
  [[ -n $_r ]] && (( ${#_l} + ${#_r} + 10 > $1 )) && _r=""
  fitText _l "$_l" $(( _end - rw - 3 ))
  auroraMotdDots "$_l"; rowPad 1
  if [[ -n $_r ]]; then
    auroraMotdFill $(( _end - rw - ${#_r} - 4 ))
    rowPad 1; auroraMotdDots "$_r"; rowPad 1
  fi
  auroraMotdFill $(( _end - rw - 1 ))
  auroraMotdGlyph "╯"
}

# auroraMotdHeroFoot <width>: the banner's bottom border: the profile and
# how it signs in at the left, the container and its age at the right.
# Whole words or none: the sign-in goes first, then the container's name -
# its age then says whose it is - then the age; only after that is the
# profile's name cut.
auroraMotdHeroFoot() {
  local -i _w=$1
  local _au="" _a="" _l1 _l2 _r1 _r2 _c=${dcn:-$host}
  case $auth in
    sso) _au="SSO sign-in" ;;
    otp) _au="password + one-time code" ;;
    password) _au="password auth" ;;
    certificate) _au="certificate auth" ;;
  esac
  [[ -n $ageText ]] && _a="started $ageText ago"
  _l1=$ovpn _l2=${ovpn:-$_au}
  [[ -n $ovpn && -n $_au ]] && _l1+=" · $_au"
  _r1=$_c _r2=$_c
  if [[ -n $_a ]]; then
    _r2="container $_a"
    if [[ -n $_c ]]; then _r1+=" · $_a"; else _r1=$_r2; fi
  fi
  if [[ -n $_r1 ]] && (( ${#_l1} + ${#_r1} + 10 <= _w )); then
    auroraMotdBottom "$_w" "$_l1" "$_r1"
  elif [[ -n $_r1 ]] && (( ${#_l2} + ${#_r1} + 10 <= _w )); then
    auroraMotdBottom "$_w" "$_l2" "$_r1"
  elif [[ -n $_r2 ]] && (( ${#_l2} + ${#_r2} + 10 <= _w )); then
    auroraMotdBottom "$_w" "$_l2" "$_r2"
  else
    auroraMotdBottom "$_w" "$_l2"
  fi
}

# auroraMotdSide <width> <content> <cells>: a card's content row between
# its side borders
auroraMotdSide() {
  local _p=""
  row+="${gradRef[(rw + gr * 2 + phase) % ringN]}│ "
  rw+=2
  (( $1 - 3 - $3 > 0 )) && printf -v _p '%*s' $(( $1 - 3 - $3 )) ''
  row+=$2$_p
  rw+=$(( $1 - 3 > $3 ? $1 - 3 : $3 ))
  row+="${gradRef[(rw + gr * 2 + phase) % ringN]}│"
  rw+=1
}

# auroraMotdCard <width> <title> <key> <height> <k> [<note>...]: row k of
# a card <height> rows tall, borders included, holding a part kept under
# <key> (auroraMotdNeed); the note (dim, the first that fits) on its top
# border at the right. Rows it doesn't have, beside a taller card, are
# left blank.
auroraMotdCard() {
  local -i _k=$5
  if (( _k == 0 )); then
    auroraMotdTop "$1" "" "$2" "${@:6}"
  elif (( _k == $4 - 1 )); then
    auroraMotdBottom "$1"
  else
    auroraMotdSide "$1" "${vR[$3/$(( _k - 1 ))]}" "${vW[$3/$(( _k - 1 ))]:-0}"
  fi
}

# auroraMotdPut: the row as the next line out
auroraMotdPut() { out+=("$row$cOff"); }

# auroraMotdBox <width> <title> <key> [<note>...]: a whole card, one line
# per row, the gradient running on from the lines above
auroraMotdBox() {
  local -i _h=$(( ${cnt[$3]:-0} + 2 )) _k
  for (( _k = 0; _k < _h; _k++ )); do
    gr=${#out[@]}; rowStart; rowPad 1
    auroraMotdCard "$1" "$2" "$3" "$_h" "$_k" "${@:4}"
    auroraMotdPut
  done
}

# auroraMotdFoot <key>: lines under the cards, their values lined up with
# the cards' values
auroraMotdFoot() {
  local -i _k
  for (( _k = 0; _k < ${cnt[$1]:-0}; _k++ )); do
    row="   ${vR[$1/$_k]}"
    auroraMotdPut
  done
}

# auroraMotdHealth: the protections into the caller's bad[] (known to be
# off: red chips), unk[] (unknown - only root can read the firewall: amber)
# and fw[], sv[] (what's fine: the firewall's, the services')
auroraMotdHealth() {
  if [[ -z $killSwitch && -z $v6Blocked ]]; then
    unk+=("a◌ firewall unknown")
  else
    case $killSwitch in
      on)  fw+=("kill switch") ;;
      off) bad+=("R ✕ kill switch off ") ;;
      *)   unk+=("a◌ kill switch unknown") ;;
    esac
    case $v6Blocked in
      1) fw+=("IPv6 blocked") ;;
      0) bad+=("R ✕ IPv6 open ") ;;
      *) unk+=("a◌ IPv6 unknown") ;;
    esac
  fi
  if (( socksUp )); then sv+=(SOCKS5); else bad+=("R ✕ SOCKS5 down "); fi
  if (( sshUp )); then sv+=(SSH); else bad+=("R ✕ SSH down "); fi
  if (( watcherUp )); then sv+=(watcher); else bad+=("R ✕ watcher down "); fi
}

# auroraMotdOkText <var> <cells>: what's fine (okN checks) in at most
# <cells>, for where the ticks are folded into one: "all 5 checks ok" when
# nothing is wrong or unknown, else "5 checks ok", else "5 ok"; a single
# one by its name (a count would be no shorter); empty when none is fine
auroraMotdOkText() {
  local _okt=""
  if (( okN == 1 )); then
    _okt=${fw[0]}${sv[0]}
  elif (( okN > 1 )); then
    _okt="$okN checks ok"
    (( ! ${#bad[@]} && ! ${#unk[@]} && 4 + ${#_okt} <= $2 )) && _okt="all $_okt"
    (( ${#_okt} <= $2 )) || _okt="$okN ok"
  fi
  printf -v "$1" '%s' "$_okt"
}

# auroraMotdSpread <cells> <rows> <token>...: the tokens (auroraMotdToken)
# onto cRows[] and cW[], 2 cells apart, on as few rows as they take and
# evened out: two rows split where they come out most even; on more, a
# last row of one token takes another from the row above while that keeps
# two there. 1, with nothing written, when they need more than <rows>.
auroraMotdSpread() {
  local -i _iw=$1 _n=$(( $# - 2 )) _i _x=0 _r=1 _s=0 _a=0 _l _bw _k=0 _lb=0 _pb=0
  local -a _t=("${@:3}") _tw=() _br=()
  local _p
  for (( _i = 0; _i < _n; _i++ )); do
    _p=${_t[_i]//[!$'\n']/}
    _tw[_i]=$(( ${#_t[_i]} - 2 * ${#_p} - 1 ))
    (( _tw[_i] <= _iw )) || return 1
    _s+=$(( _tw[_i] + (_i ? 2 : 0) ))
    if (( _i && _x + 2 + _tw[_i] <= _iw )); then
      _x+=$(( 2 + _tw[_i] ))
    else
      (( _i )) && { _r+=1; _br[_i]=1; _pb=_lb _lb=_i; }
      _x=_tw[_i]
    fi
  done
  (( _r <= $2 )) || return 1
  if (( _r == 2 )); then
    _br=() _bw=_iw+1
    for (( _i = 0; _i < _n - 1; _i++ )); do
      _a+=$(( _tw[_i] + (_i ? 2 : 0) ))
      _l=$(( _s - _a - 2 ))
      if (( _a <= _iw && _l <= _iw && (_a > _l ? _a : _l) < _bw )); then
        _bw=$(( _a > _l ? _a : _l )) _k=_i+1
      fi
    done
    _br[_k]=1
  elif (( _r > 2 && _lb == _n - 1 && _lb - _pb >= 3 && _tw[_lb-1] + 2 + _tw[_lb] <= _iw )); then
    unset '_br[_lb]'
    _br[_lb-1]=1
  fi
  rowStart
  for (( _i = 0; _i < _n; _i++ )); do
    if [[ -n ${_br[_i]} ]]; then
      cRows+=("$row"); cW+=("$rw"); rowStart
    elif (( _i )); then
      rowPad 2
    fi
    auroraMotdToken "${_t[_i]}"
  done
  cRows+=("$row"); cW+=("$rw")
}

# auroraMotdChecks <cells> <rows>: the checks onto cRows[] and cW[]: what
# isn't known (amber), then what's fine (green ticks), spread over at most
# <rows> rows. When they need more: with nothing wrong at all, "✓ all 5
# checks ok"; else the unknowns, as many ticks as fit and the rest counted,
# "✓ +2 ok" ("✓ 3 checks ok" when none of them fit) - two at least, so a
# name is never swapped for "+1 ok" while it fits
auroraMotdChecks() {
  local -a _t=(${ckLead:+"$ckLead"} "${unk[@]}")
  local -i _iw=$1 _r=$2 _i _n _nu=${#_t[@]} _w _g _rest _j _put=0 _row=1
  local _c _m
  for _c in "${fw[@]}" "${sv[@]}"; do _t+=($'g✓ \nd'"$_c"); done
  _n=${#_t[@]}
  (( _n )) || return 0
  auroraMotdSpread "$_iw" "$_r" "${_t[@]}" && return 0
  if (( ! ${#bad[@]} && ! ${#unk[@]} && ! ${#ckLead} )); then
    auroraMotdOkText _c $(( _iw - 2 ))
    rowStart; auroraMotdPiece "g✓ "; auroraMotdPiece "d$_c" "$_iw"
    cRows+=("$row"); cW+=("$rw")
    return 0
  fi
  rowStart
  for (( _i = 0; _i < _n; _i++ )); do
    _c=${_t[_i]} _m=${_c//[!$'\n']/}
    _w=$(( ${#_c} - 2 * ${#_m} - 1 )) _g=$(( rw ? 2 : 0 ))
    # A row ends before what won't fit on it - not before the first: a
    # token wider than the row is cut on the row it starts
    if (( rw && rw + _g + _w > _iw && (_i < _nu || _row < _r) )); then
      cRows+=("$row"); cW+=("$rw"); rowStart
      _row+=1 _g=0
    fi
    if (( _i >= _nu && _row >= _r )); then
      # The last row: the rest when it fits, else this and the count after
      _rest=_w
      for (( _j = _i + 1; _j < _n; _j++ )); do _rest+=$(( ${#_t[_j]} - 1 )); done
      if (( rw + _g + _rest > _iw )); then
        _m="+$(( _n - _i - 1 )) ok"
        if (( _n - _i - 1 < 2 || rw + _g + _w + 4 + ${#_m} > _iw )); then
          if (( _n - _i == 1 )); then
            # One alone keeps its name - its count only where that fits
            # beside the ticks and the name doesn't
            _m=${_c#*$'\n'd}
            (( _put && rw + _g + 2 + ${#_m} > _iw && rw + _g + 7 <= _iw )) && _m="+1 ok"
          elif (( _put )); then
            _m="+$(( _n - _i )) ok"
          else
            _m="$(( _n - _i )) checks ok"
            (( rw + _g + 2 + ${#_m} <= _iw )) || _m="$(( _n - _i )) ok"
          fi
          # No room left even for the count (the unknowns took it): a row
          # of its own, rather than leave it unsaid
          if (( rw && rw + _g + 2 + ${#_m} > _iw )); then
            cRows+=("$row"); cW+=("$rw"); rowStart
            _g=0
          fi
          rowPad "$_g"
          auroraMotdPiece "g✓ " "$_iw"; auroraMotdPiece "d$_m" "$_iw"
          break
        fi
      fi
    fi
    rowPad "$_g"
    auroraMotdToken "$_c" "$_iw"
    (( _i >= _nu )) && _put+=1
  done
  cRows+=("$row"); cW+=("$rw")
}

# auroraMotdEven <code> <text> <cells>: the text onto the caller's pcs[]:
# whole when it fits <cells>, else with a place to wrap where the two rows
# come out most even, so no word is left alone on a row (else a word at a
# time)
auroraMotdEven() {
  local -i _k _a _b _best=0 _bw=$3
  local -a _w
  local IFS=' ' _j
  if (( ${#2} <= $3 )); then
    pcs+=("$1$2")
    return 0
  fi
  read -ra _w <<< "$2"
  for (( _k = 1; _k < ${#_w[@]}; _k++ )); do
    _j="${_w[*]:0:_k}"
    _a=${#_j} _b=$(( ${#2} - ${#_j} - 1 ))
    if (( _a <= $3 && _b <= $3 && (_a > _b ? _a : _b) < _bw )); then
      _bw=$(( _a > _b ? _a : _b )) _best=_k
    fi
  done
  if (( _best )); then
    pcs+=("$1${_w[*]:0:_best}" "|w " "$1${_w[*]:_best}")
  else
    auroraMotdWords "$1" "$2"
  fi
}

# auroraMotdExit <cells> <label cells> <flag 1|0>: the exit country and IP,
# or why there's no IP yet, labelled EXIT, onto cRows[] and cW[]; a long
# name or note breaks into two even rows rather than being cut
auroraMotdExit() {
  local -a pcs=()
  local -i _r=$(( $1 - $2 ))
  if [[ -n $ip ]]; then
    if (( $3 )) && [[ -n $flag ]]; then pcs+=("F$flag" "w "); _r+=-3; fi
    if [[ -n $ctn ]]; then auroraMotdEven w "$ctn" "$_r"; pcs+=("|w  "); fi
    pcs+=("c$ip")
  else
    auroraMotdEven w "$ipNoteShown" "$_r"
  fi
  auroraMotdItem "$1" "$2" "vEXIT" "${pcs[@]}"
}

# auroraMotdRetry <cells> <indent>: the server being retried onto cRows[]
# and cW[], "retrying 192.0.2.20:443 · TCP" - the protocol first, or the
# address on a row of its own, when that's what fits - never cut: 1 when
# it can't be whole that narrow
auroraMotdRetry() {
  local -i _w=$(( $1 - $2 )) _s=${#server} _p=${#proto}
  local -a _pc
  if (( ! _p )); then
    if (( 9 + _s <= _w )); then _pc=("dretrying " "w$server")
    elif (( _s <= _w )); then _pc=("dretrying" "|w " "w$server")
    else return 1
    fi
  elif (( 12 + _s + _p <= _w )); then _pc=("dretrying " "w$server" "f · " "w$proto")
  elif (( 10 + _p + _s <= _w )); then _pc=("dretrying " "w$proto " "w$server")
  elif (( _s + 3 + _p <= _w )); then _pc=("dretrying" "|w " "w$server" "f · " "w$proto")
  elif (( _s <= _w )); then _pc=("dretrying " "w$proto" "|w " "w$server")
  else return 1
  fi
  auroraMotdItem "$1" "$2" "" "${_pc[@]}"
}

# auroraMotdBadge <cells> [k]: the badge onto cRows[] and cW[], and beside
# it while there's room what it's doing: connected how long ("↻ 3h 52m"
# when "up 3h 52m" won't fit, else on a row of its own), stopped (or
# starting), waiting for the browser, the server being retried (when it
# fits whole there: retryBeside, else it's a part of its own). With k, the
# checks' count after that (tck 0, nothing wrong) - uForced when the row
# can't hold it.
auroraMotdBadge() {
  local -i _w=$1 _own=0
  local _t
  rowStart; auroraMotdPiece "S$badge"
  case $view$ovpnUp in
    conn*)
      if [[ -z $upText ]]; then
        :
      elif (( rw + 6 + ${#upText} <= _w )); then
        rowPad 3; rowAdd "$cDim" "up "; rowAdd "$cWht" "$upText"
      elif (( rw + 4 + ${#upText} <= _w )); then
        rowPad 2; rowAdd "$cDim" "↻ "; rowAdd "$cWht" "$upText"
      else
        cRows+=("$row"); cW+=("$rw")
        rowStart; rowAdd "$cDim" "up "; rowAdd "$cWht" "$upText"
        _own=1
      fi ;;
    sso*) (( rw + 22 <= _w )) && { rowPad 3; rowAdd "$cDim" "waiting for browser"; } ;;
    down0)
      _t=stopped; (( starting )) && _t=starting
      (( rw + 3 + ${#_t} <= _w )) && { rowPad 3; rowAdd "$cDim" "$_t"; } ;;
    down1)
      if (( retryBeside )); then
        rowPad 3; rowAdd "$cDim" "retrying "; rowAdd "$cWht" "$server"
        [[ -n $proto ]] && { rowAdd "$cFnt" " · "; rowAdd "$cWht" "$proto"; }
      fi ;;
  esac
  if [[ $2 == k ]]; then
    # Spelled out ("5 checks ok" at least): a bare "5 ok" there could be
    # read as the badge's
    auroraMotdOkText _t $(( _w - rw - 5 ))
    if (( ! _own && ${#_t} && rw + 5 + ${#_t} <= _w )) && [[ $_t != "$okN ok" ]]; then
      rowPad 3; rowAdd "$cGrn" "✓ "; rowAdd "$cDim" "$_t"
    else
      uForced=1
    fi
  fi
  cRows+=("$row"); cW+=("$rw")
}

# auroraMotdUnit <part> <cells> <knob>: a part of the state block as rows
# <cells> wide, onto cRows[] and cW[]: b the badge and what it's doing (k:
# the checks' count after it), y the server being retried (<knob> cells
# in), w CAUTION's line, m why it's down, n what to run (or sso-url), M the
# two together, under the logo, x what's wrong (0: what's fine after it,
# the ticks or their count; k: the checks after it, uForced when they
# don't fit its row), e the exit (its label <knob> cells), k the checks (in
# <knob> rows), t the traffic. uForced is set when the part can't be whole
# that narrow.
auroraMotdUnit() {
  case $1 in
    b) auroraMotdBadge "$2" "$3" ;;
    y) auroraMotdRetry "$2" "$3" || uForced=1 ;;
    w) auroraMotdMsg "$2" "a▲" a "$warnText" ;;
    m)
      if (( ovpnUp )); then
        auroraMotdMsg "$2" "r✕" w "Waiting for outbound connectivity"
      elif (( starting == 2 )); then
        auroraMotdMsg "$2" "a◌" w "Waiting for the one-time code on the console: docker attach $hostShown"
      elif (( starting )); then
        auroraMotdMsg "$2" "a◌" w "OpenVPN is starting"
      else
        auroraMotdMsg "$2" "r✕" w "${stopWhy:-OpenVPN is not running}"
      fi ;;
    n)
      if [[ $view == sso ]]; then
        auroraMotdItem "$2" 2 "a◈" "csso-url" "|w " "dprints the link"
      else
        auroraMotdItem "$2" 2 "" "drun " "cvpn-restart" "|w " "d$restartWhy"
      fi ;;
    M)
      # What to run after the message on its last row, when that holds it
      auroraMotdUnit m "$2"
      local -i _l=$(( ${#cRows[@]} - 1 ))
      if (( cW[_l] + 19 + ${#restartWhy} <= $2 )); then
        row=${cRows[_l]} rw=${cW[_l]}
        rowAdd "$cFnt" " · "; rowAdd "$cDim" "run "; rowAdd "$cCyn" vpn-restart; rowAdd "$cDim" " $restartWhy"
        cRows[_l]=$row cW[_l]=$rw
      else
        auroraMotdUnit n "$2"
      fi ;;
    x)
      # Chips on one row (x0: what's fine after them, the ticks or their
      # count); when they'd need more, the way the panel writes alerts - a
      # red ✕, white text, no background - so rows of chips don't run into
      # one red block
      local -a _p=() _ok=()
      local -i _cw=-2 _tw=0 _uw=0
      local _c _o=""
      # The widths first (chips, ticks, unknowns, two cells apart), so a row
      # that can't hold them isn't tried
      for _c in "${bad[@]}"; do _cw+=$(( ${#_c} + 1 )); done
      for _c in "${fw[@]}" "${sv[@]}"; do _ok+=($'g✓ \nd'"$_c") _tw+=$(( ${#_c} + 4 )); done
      for _c in "${unk[@]}"; do _uw+=$(( ${#_c} + 1 )); done
      if [[ $3 == k ]]; then
        # xk: the checks (k) after them on the one row, or uForced
        if (( _cw + _uw + _tw > $2 )) || ! auroraMotdSpread "$2" 1 "${bad[@]}" "${unk[@]}" "${_ok[@]}"; then
          uForced=1
        fi
        return 0
      fi
      if [[ $3 == 0 ]]; then
        (( okN > 1 && _cw + _tw <= $2 )) && auroraMotdSpread "$2" 1 "${bad[@]}" "${_ok[@]}" && return 0
        auroraMotdOkText _o $(( $2 - _cw - 4 ))
      fi
      _ok=()
      [[ -n $_o ]] && _ok=($'g✓ \nd'"$_o")
      (( _cw + (${#_o} ? 4 + ${#_o} : 0) <= $2 )) && auroraMotdSpread "$2" 1 "${bad[@]}" "${_ok[@]}" && return 0
      for _c in "${bad[@]}"; do _p+=($'r✕ \nw'"${_c:4:-1}"); done
      [[ $3 == 0 ]] && auroraMotdOkText _o $(( $2 - 2 ))
      [[ -n $_o ]] && _ok=($'g✓ \nd'"$_o")
      auroraMotdSpread "$2" 99 "${_p[@]}" "${_ok[@]}" || auroraMotdFlow "$2" 99 2 "" "${_p[@]}" ;;
    e) auroraMotdExit "$2" "$3" "$exitFlag" ;;
    k)
      # tck 3: as many rows as they take
      if [[ $3 == u* ]]; then
        local ckLead=$'dup \nw'"$upText"
        auroraMotdChecks "$2" $(( ${3:1} > 2 ? 99 : ${3:1} ))
      else
        auroraMotdChecks "$2" $(( $3 > 2 ? 99 : $3 ))
      fi ;;
    t)
      if [[ $3 == u ]]; then
        auroraMotdItem "$2" 0 "" "dup " "w$upText" "|w   " "c▼ " "$vc$rxText" "|w    " "v▲ " "$vc$txText"
      else
        auroraMotdItem "$2" 0 "" "c▼ " "$vc$rxText" "|w    " "v▲ " "$vc$txText"
      fi ;;
  esac
  return 0
}

# auroraMotdState: the state block for the knobs trf, tck, flow and rul.
# Beside the logo (sw cells wide): the badge, the server being retried, the
# alert lines (CAUTION's, why it's down and what to run, what's wrong), the
# exit, the checks and the traffic. Under it, across the banner (flowW
# cells, the exit's value lined up with the cards'), the panel's alert row:
# an alert line that would wrap beside the logo goes there, and every alert
# line after it (why it's down and what to run then share a row, M), as
# does the retry line when it can't be whole beside it (the alert lines
# follow it). The exit, the checks and the traffic go on under it too, once
# the rows beside it are filled, when that's shorter with flow, or no
# taller when an alert line is under it already or what's beside would
# stand over twice the logo's height; under the problems, the checks go on
# their row when it holds them (xk). With tck 0 what's fine follows the
# problems (the ticks, or their count), else its count goes on the badge's
# row, else a row of its own. A spare row beside the logo draws the panel's
# rule under the badge; rul draws it on a row of its own when there's none.
# Into hh the banner's rows inside its borders, and sk the arrangement's
# key (sBes, sBel, sRule, sU, sL: the parts beside, under, the rule, the
# rows beside and under). The look at the parts is kept apart, for trf and
# tck (auroraMotdScan): flow and rul only arrange it.
auroraMotdState() {
  sk=$trf$tck$flow$rul@$sw
  if [[ -n ${sU[$sk]} ]]; then
    hh=$(( ${sU[$sk]} + ${sL[$sk]} ))
    return 0
  fi
  local _q=$trf$tck@$sw _u _k _bs _fs _gl _fl _bl=""
  local -i _A=${#art[@]} _B _F _G _L=0 _n _ha _hb _s=1
  [[ -n ${qB[$_q]} ]] || auroraMotdScan
  _B=${qB[$_q]} _F=${qF[$_q]} _G=${qG[$_q]} _n=${qN[$_q]}
  _bs=${qBs[$_q]} _fs=${qFs[$_q]} _gl=${qGl[$_q]} _fl=${qFl[$_q]}
  _ha=$(( (_B < _A ? _A : _B + rul) + _G ))
  # Flowed, when that's shorter - no taller (_s 0), when what's beside would
  # stand over twice the logo's height, or when an alert line is under it
  # already, so what comes after it follows it there; built only when it
  # might be, each part under the logo a row at least
  (( _B > 2 * _A || _G )) && _s=0
  if (( _n && (flow || ! _s) && (_F < _A ? _A : _F + rul) + _G + _n <= _ha - _s )); then
    for _u in $_fl; do
      case $_u in
        e) _k=e9 ;;
        k)
          auroraMotdChecksKey "$flowW"
          # Right after the problems: on their row, when it holds them all
          if (( tck )) && [[ $_gl == *" x" && -z $_bl ]]; then
            [[ -n ${cnt[xk@$flowW]} ]] || auroraMotdNeed "xk@$flowW" auroraMotdUnit x "$flowW" k
            if (( ! ${vT[xk@$flowW]} )); then
              _L+=$(( ${cnt[xk@$flowW]} - ${cnt[x@$flowW]} )) _gl="${_gl% x} xk"
              continue
            fi
          fi ;;
        *) _k=$_u ;;
      esac
      [[ -n ${cnt[$_k@$flowW]} ]] || auroraMotdNeed "$_k@$flowW" auroraMotdUnit "$_u" "$flowW" "${_k:1}"
      _L+=${cnt[$_k@$flowW]} _bl+=" $_k"
    done
    _hb=$(( (_F < _A ? _A : _F + rul) + _G + _L ))
    if (( _hb <= _ha - _s )); then
      _B=_F _bs=$_fs
    else
      _L=0 _bl="" _gl=${_gl/% xk/ x}
    fi
  fi
  sBes[$sk]=$_bs sBel[$sk]="$_gl$_bl" sL[$sk]=$(( _G + _L )) sRule[$sk]=$(( _B < _A || rul ))
  sU[$sk]=$(( _B < _A ? _A : _B + rul ))
  hh=$(( ${sU[$sk]} + _G + _L ))
}

# auroraMotdChecksKey <cells>: into the caller's _k the checks' part for
# tck at <cells>: built as many rows as they take (k3), and fewer only when
# that's more than tck allows
auroraMotdChecksKey() {
  [[ -n ${cnt[k3@$1]} ]] || auroraMotdNeed "k3@$1" auroraMotdUnit k "$1" 3
  _k=k3
  (( tck < 3 && ${cnt[k3@$1]} > tck )) && _k=k$tck
  return 0
}

# auroraMotdScan: auroraMotdState's look at the parts for trf and tck
# (kept under $trf$tck@$sw: flow and rul don't change it): each part built
# beside the logo, the alert lines that go under it built there, and in
# qBs, qFs, qGl, qFl the parts beside it (all of the exit, the checks and
# the traffic; as many of them as fill the logo's rows), under it, and
# left to flow, with their rows in qB, qF, qG and qN (their number)
auroraMotdScan() {
  local -i _A=${#art[@]} _B=0 _F=0 _G=0 _n=0 _r _fill=1 _und=0 _okb=0 _mn=0
  local _u _k _c _bs="" _fs="" _gl="" _fl="" _q=$trf$tck@$sw
  if (( ! tck && ! ${#bad[@]} && ! ${#unk[@]} && okN )); then
    [[ -n ${cnt[bk@$sw]} ]] || auroraMotdNeed "bk@$sw" auroraMotdUnit b "$sw" k
    (( ${vT[bk@$sw]} )) || _okb=1
  fi
  for _u in "${units[@]}"; do
    case $_u in
      b) _k=b; (( _okb )) && _k=bk ;;
      t) (( trf )) || continue; _k=t ;;
      e) _k=e5 ;;
      k)
        # tck 0: a count after the problems (x0), on the badge's row (bk),
        # with the unknowns, or a row of its own
        if (( tck )); then auroraMotdChecksKey "$sw"
        elif (( ${#unk[@]} )); then _k=k0
        elif (( ${#bad[@]} || _okb || ! okN )); then continue
        else _k=k0
        fi ;;
      x) _k=x; (( tck || ${#unk[@]} )) || _k=x0 ;;
      y) _k=y0 ;;
      n) (( _mn )) && continue; _k=n ;;
      *) _k=$_u ;;
    esac
    [[ -n ${cnt[$_k@$sw]} ]] || auroraMotdNeed "$_k@$sw" auroraMotdUnit "$_u" "$sw" "${_k:1}"
    _r=${cnt[$_k@$sw]}
    case $_u in
      y) (( ${vT[y0@$sw]} )) && _und=1 ;;
      m)
        # With what to run: both beside, or both under on as few rows
        if [[ " ${units[*]} " == *" n "* ]]; then
          [[ -n ${cnt[n@$sw]} ]] || auroraMotdNeed "n@$sw" auroraMotdUnit n "$sw"
          (( _r > 1 || ${cnt[n@$sw]} > 1 )) && _und=1
          (( _und )) && _k=M _mn=1
        else
          (( _r > 1 )) && _und=1
        fi ;;
      w|n|x) (( _r > 1 )) && _und=1 ;;
    esac
    if [[ $_u == [ywmnx] ]] && (( _und )); then
      _c=$_u
      [[ $_k == M ]] && _c=M
      [[ -n ${cnt[$_k@$flowW]} ]] || auroraMotdNeed "$_k@$flowW" auroraMotdUnit "$_c" "$flowW" "${_k:1}"
      _gl+=" $_k" _G+=${cnt[$_k@$flowW]}
    elif [[ $_u == [ekt] ]]; then
      _bs+=" $_k" _B+=_r
      if (( _fill && _F + _r <= _A )); then
        _fs+=" $_k" _F+=_r
      else
        _fill=0 _fl+=" $_u" _n+=1
      fi
    else
      _bs+=" $_k" _fs+=" $_k" _B+=_r _F+=_r
    fi
  done
  qB[$_q]=$_B qF[$_q]=$_F qG[$_q]=$_G qN[$_q]=$_n qBs[$_q]=$_bs qFs[$_q]=$_fs qGl[$_q]=$_gl qFl[$_q]=$_fl
}

# auroraMotdShell <cells>: the shell command onto the caller's pcs[]; when
# even a row of its own is too narrow, " sh -l" gives way to an ellipsis
# first, as in the status panel, so the container still shows
auroraMotdShell() {
  pcs+=("wdocker exec -it " "c$hostShown")
  if (( $1 <= 0 || 22 + ${#hostShown} <= $1 )); then
    pcs+=("w sh -l")
  elif (( 18 + ${#hostShown} <= $1 )); then
    pcs+=("w …")
  fi
}

# auroraMotdMounts <cells> <rows>: the mounts onto the caller's pcs[], in
# at most <rows> rows <cells> wide (|n starts the next): a path too long
# for the room left is cut from the front a directory at a time
# ("…/name") when it's long enough to keep a name that says something; one
# too long even for a row of its own is cut at its end; the rest are
# counted at the end, "+N more" ("N mounts" when none of them showed) -
# all the rest from the first that's counted, so the count is what follows
auroraMotdMounts() {
  local -i _iw=$1 _r=1 _i _j _n=${#mounts[@]} _x=0 _sep _res _cnt=0 _put=0 _rest
  local _p _m _c _t
  for (( _i = 0; _i < _n; _i++ )); do
    (( _cnt )) && { _cnt+=1; continue; }
    _p=${mounts[_i]% *} _m=${mounts[_i]##* }
    while :; do
      _sep=$(( _x ? 3 : 0 )) _res=0
      if (( _r >= $2 && (_i < _n - 1 || _cnt) )); then
        # On the last row, room for a count unless all the rest fits
        _rest=$(( _x + _sep + ${#_p} + 1 + ${#_m} ))
        for (( _j = _i + 1; _j < _n; _j++ )); do _rest+=$(( 3 + ${#mounts[_j]} )); done
        _t="+$(( _n - _i - 1 + _cnt )) more"
        (( _rest > _iw || _cnt )) && _res=$(( 3 + ${#_t} ))
      fi
      _c=$_p
      if (( _x + _sep + ${#_c} + 1 + ${#_m} + _res > _iw )); then
        _c="" _t=$_p
        if (( ${#_p} > 16 )); then
          while [[ ${_t:1} == */* ]]; do
            _t=/${_t#/*/}
            if (( _x + _sep + 1 + ${#_t} + 1 + ${#_m} + _res <= _iw )); then
              _c=…$_t
              break
            fi
          done
        fi
        # Too long for any row: what there's room for of its last directory
        _t=…/${_p##*/}
        if [[ -z $_c ]] && (( ! _x && ${#_t} + 1 + ${#_m} + _res > _iw && _iw - _res - ${#_m} - 1 >= 8 )); then
          fitText _c "$_t" $(( _iw - _res - ${#_m} - 1 ))
        fi
      fi
      if [[ -n $_c ]]; then
        (( _sep )) && pcs+=("|w   ")
        pcs+=("w$_c" "d $_m")
        _x+=$(( _sep + ${#_c} + 1 + ${#_m} )) _put+=1
        break
      fi
      if (( _x && _r < $2 )); then
        pcs+=("|n")
        _x=0 _r+=1
        continue
      fi
      _cnt+=1
      break
    done
  done
  (( _cnt )) || return 0
  if (( _put )); then _t="+$_cnt more"; else _t="$_cnt mounts"; fi
  (( _x )) && pcs+=("w   ")
  pcs+=("d$_t")
}

# auroraMotdList <array> <cells> <gap> <piece>...: as many of the pieces
# as fit on one row <cells> wide, <gap> cells apart, onto the named array;
# when not all of them fit, a dim "+N more" ends it, "+N" when only that
# fits after the first. Nothing when not even that fits (the caller says
# how many instead): a list that's cut short always says so.
auroraMotdList() {
  local -n _a=$1
  local -i _iw=$2 _gap=$3 _i _n=$(( $# - 3 )) _w=0 _g _res
  local -a _it=("${@:4}")
  local _x _sp
  printf -v _sp '%*s' "$_gap" ''
  for (( _i = 0; _i < _n; _i++ )); do
    _g=$(( _i ? _gap : 0 )) _res=0
    if (( _i < _n - 1 )); then
      printf -v _x '+%d more' $(( _n - _i - 1 ))
      _res=$(( _gap + ${#_x} ))
    fi
    if (( _w + _g + ${#_it[_i]} - 1 + _res > _iw )); then
      if (( ! _i )); then
        # The first doesn't leave room for the count: it with a short one,
        # or nothing
        printf -v _x '+%d' $(( _n - 1 ))
        (( _n > 1 && ${#_it[0]} - 1 + _gap + ${#_x} <= _iw )) && _a+=("${_it[0]}" "w$_sp" "d$_x")
        return 0
      fi
      printf -v _x '+%d more' $(( _n - _i ))
      _a+=("w$_sp" "d$_x")
      return 0
    fi
    (( _i )) && _a+=("w$_sp")
    _a+=("${_it[_i]}")
    _w+=$(( _g + ${#_it[_i]} - 1 ))
  done
}

# auroraMotdAccess <cells> <one|two> <mounts 2|1|0> [<rows>]: the ACCESS
# card - the proxy, ssh and its password, a shell like this one, the
# mounts: as many rows as they take (2), one and <rows> more (1), none. A
# listener that isn't there has its label in red and a chip saying so:
# beside the command when it fits, else at the end of the password's row,
# else on a row of its own.
auroraMotdAccess() {
  local -a gP=() gS=() gN=() pcs _pw=("|w   " "dpassword " "wjumpbox")
  local -i _vw=$(( $1 - lw )) _c
  local _l=v
  (( socksUp )) || _l=r
  pcs=("${_l}SOCKS5" "w127.0.0.1:" "c$port")
  (( socksUp )) || pcs+=("|w  " "R ✕ not listening ")
  auroraMotdAdd "${pcs[@]}"
  pcs=("vSSH" "wssh jumpbox@127.0.0.1 -p " "c$sshPort")
  if (( ! sshUp )); then
    _c=$(( 26 + ${#sshPort} + 2 ))
    pcs[0]=rSSH
    if (( $1 <= 0 || _c + 17 <= _vw )); then
      pcs+=("|w  " "R ✕ not listening ")
    elif (( 35 <= _vw )); then
      _pw=("|n" "dpassword " "wjumpbox" "w  " "R ✕ not listening ")
    else
      pcs+=("|n" "R ✕ not listening ") _pw=("|n" "dpassword " "wjumpbox")
    fi
  fi
  auroraMotdAdd "${pcs[@]}" "${_pw[@]}"
  pcs=("vSHELL")
  auroraMotdShell "$1"
  auroraMotdAdd "${pcs[@]}"
  if (( $3 && ${#mounts[@]} )); then
    pcs=("vMOUNTS")
    auroraMotdMounts "$_vw" $(( $3 > 1 ? 99 : 1 + ${4:-0} ))
    auroraMotdAdd "${pcs[@]}"
  fi
  auroraMotdGrid "$1" "$2"
}

# auroraMotdMountRows <cells> <rows>: ACCESS's MOUNTS on its own, in at
# most <rows> rows (an item a row, ACCESS's rows are its three ways in and
# these: built apart, so another number of rows costs only these)
auroraMotdMountRows() {
  local -a pcs=("vMOUNTS")
  (( ${#mounts[@]} )) || return 0
  auroraMotdMounts $(( $1 - lw )) "$2"
  auroraMotdItem "$1" "$lw" "${pcs[@]}"
}

# auroraMotdAccessRows <cells> <mounts 2|1|0> [<rows>]: ACCESS for the
# knobs, into ak (the key of its rows, two keys joined by + when it's its
# ways in and MOUNTS built apart) and nA (their number). Two to a row only
# where every pair fits - worked out from the items' widths first, as
# auroraMotdGrid would, so nothing's built to find out; else it's a row an
# item, and MOUNTS, built on its own, is all another number of mounts' rows
# costs. Each answer is kept (aOf), as the fit asks again and again.
auroraMotdAccessRows() {
  local _c=$1/$2/$3
  if [[ -n ${aOf[$_c]} ]]; then
    ak=${aOf[$_c]} nA=${aN[$_c]}
    return 0
  fi
  auroraMotdAccessKey "$@"
  aOf[$_c]=$ak aN[$_c]=$nA
}

# auroraMotdAccessKey <cells> <mounts 2|1|0> [<rows>]: auroraMotdAccessRows'
# work, each time it's asked something new
auroraMotdAccessKey() {
  local _m
  local -i _s5=$(( lw + 10 + ${#port} + (socksUp ? 0 : 19) )) \
    _ssh=$(( lw + 45 + ${#sshPort} + (sshUp ? 0 : 19) )) _sh=$(( lw + 22 + ${#hostShown} )) _mw=0 _mt=0
  if (( $2 && ${#mounts[@]} )); then
    _mt=-3
    for _m in "${mounts[@]}"; do _mt+=$(( ${#_m} + 3 )); done
    _mw=$(( lw + ($2 < 2 && _mt > $1 - lw ? $1 - lw : _mt) ))
    (( _sh > _s5 )) && _s5=_sh
    (( _mw > _ssh )) && _ssh=_mw
  fi
  # Every mount on one row anyway: as many rows as they take is one
  _m=$(( $2 > 1 ? 99 : 1 + ${3:-0} ))
  (( _m > 1 && _mt <= $1 - lw )) && _m=1
  if (( _s5 + 3 + _ssh <= $1 )); then
    ak=atwo$(( $2 && _m == 1 ? 1 : $2 ))@$1
    auroraMotdNeed "$ak" auroraMotdAccess "$1" two "${ak:4:1}"
    nA=${cnt[$ak]}
    return 0
  fi
  ak=aone0@$1
  auroraMotdNeed "$ak" auroraMotdAccess "$1" one 0
  nA=${cnt[$ak]}
  (( $2 && ${#mounts[@]} )) || return 0
  # More than a row: all of them, when that's no more rows than allowed
  if (( _m > 1 )); then
    auroraMotdNeed "m99@$1" auroraMotdMountRows "$1" 99
    (( ${cnt[m99@$1]} <= _m )) && _m=99
  fi
  auroraMotdNeed "m$_m@$1" auroraMotdMountRows "$1" "$_m"
  ak+=+m$_m@$1 nA+=${cnt[m$_m@$1]}
}

# auroraMotdJoin <key> <key>...: the rows kept under the keys, one after
# another, kept under the first (for a card made of parts)
auroraMotdJoin() {
  local _k
  local -i _i _n=0
  [[ -n ${cnt[$1]} ]] && return 0
  for _k in "${@:2}"; do
    for (( _i = 0; _i < ${cnt[$_k]:-0}; _i++ )); do
      vR[$1/$_n]=${vR[$_k/$_i]} vW[$1/$_n]=${vW[$_k/$_i]}
      _n+=1
    done
  done
  cnt[$1]=$_n
}

# TUNNEL: the server and its protocol (one stretch, never split or cut short
# of the protocol: the protocol first when that's what fits beside the
# label, else the two on a row of their own under it), the cipher, TLS and
# the key agreement (post-quantum called out; none of it while neither the
# cipher nor TLS is known, as before anything is negotiated, rather than
# rows of dashes), the tunnel's address and routing, DNS and its search
# domains (none of the tunnel's own when it's gone, as what's there now
# isn't the last connection's). White while connected, dim once they're the
# last connection's; their inline keywords a step fainter than the values
# either way (il).
#
# Built a row at a time, each row kept as T<row>@<cells> (C<row>@<cells>
# cut): a row is the codes of its parts - s SERVER, c CIPHER, t TLS, u TUN,
# d DNS, q SEARCH - the first labelled in the label column, the rest joined
# on after it inline (" · AES-256-GCM", " · TLS TLSv1.3", " · DNS 10.8.0.1",
# " · search corp.example"), each only when it fits there whole; upper case
# (D, Q, in a cut row) a part left out and counted where it would have gone
# ("· DNS +3", or as many as fit and "+2"). The forms, richest first: j0 a
# part a row (the search domains on the DNS row when they fit); j1 the
# cipher joining the server; j2 DNS joining TUN; j3 TLS joining the row
# before it; two, j0's parts two to a row when every pair fits; c<n>, j3 cut
# to n rows of one row each, the least needed rows left out first - SEARCH,
# DNS, TLS, CIPHER, TUN - and the server without its label when that's what
# keeps it whole. A form's rows are listed in tF[<form>@<cells>] and
# counted in tN[...] from the widths, so trying one builds nothing; only
# the form that's used is built (auroraMotdTunKey).

# auroraMotdTunPrep: TUNNEL's widths, once a render: tSa the server as
# "address · PROTO", tSb as "PROTO address", tC the cipher, tL TLS with the
# key agreement, tU the tunnel ("10.8.0.6/24 · full tunnel"), tUs the same
# without its routes, tD every DNS server and tQ every search domain (tQs),
# two cells apart
auroraMotdTunPrep() {
  [[ -n $tPrep ]] && return 0
  local _x
  local -a pcs=()
  tPrep=1
  if [[ -z $server ]]; then
    tSa=$(( logWhole ? 14 : 21 )) tSb=tSa
  elif [[ -z $proto ]]; then
    tSa=${#server} tSb=${#server}
  else
    tSa=$(( ${#server} + 3 + ${#proto} )) tSb=$(( ${#proto} + 1 + ${#server} ))
  fi
  tC=$(( ${#cipher} ? ${#cipher} : 1 )) tL=$(( ${#tlsVer} ? ${#tlsVer} : 1 ))
  [[ -n $kex ]] && tL+=$(( 3 + ${#kex} ))
  if [[ $tunnelMode == full ]]; then
    tU=$(( ${#tunIp} + 14 )) tUs=tU
  else
    tUs=$(( ${#tunIp} + 8 ))
    tU=$(( tUs + 2 + ${#routeCount} + (routeCount == 1 ? 6 : 7) ))
  fi
  tD=-2
  for _x in "${dns[@]}"; do tD+=$(( ${#_x} + 2 )); done
  auroraMotdWords "" "$dnsSearch"
  tQs=() tQ=-2
  for _x in "${pcs[@]}"; do
    [[ $_x == '|'* ]] && continue
    tQs+=("$_x") tQ+=$(( ${#_x} + 2 ))
  done
}

# auroraMotdDomains <array> <cells>: the search domains onto the named array
# as auroraMotdList puts a list, two cells apart; a first too long for the
# room even alone is cut from the front a label at a time
# ("…compute.internal", two labels kept), with room kept for the count of
# the rest - else, with <cells> 12 or more, cut at its end, else only that
# count ("+3"), else nothing
auroraMotdDomains() {
  local -n _o=$1
  local _d=${tQs[0]}
  local -i _n=${#tQs[@]} _res=0
  auroraMotdList "$1" "$2" 2 "${tQs[@]/#/$vc}"
  (( ${#_o[@]} )) && return 0
  (( _n > 1 )) && _res=$(( 3 + ${#_n} ))
  while [[ $_d == *.*.* ]] && (( 1 + ${#_d} > $2 - _res )); do _d=${_d#*.}; done
  if [[ $_d != "${tQs[0]}" ]] && (( 1 + ${#_d} <= $2 - _res )); then
    _o+=("$vc…$_d")
  elif (( $2 - _res >= 12 )); then
    fitText _d "${tQs[0]}" $(( $2 - _res ))
    _o+=("$vc$_d")
  elif (( 1 + ${#_n} <= $2 )); then
    _o+=("d+$_n")
    return 0
  else
    return 0
  fi
  (( _n > 1 )) && _o+=("w  " "d+$(( _n - 1 ))")
}

# auroraMotdTunPcs <row> <cells> [cut]: a TUNNEL row's pieces onto the
# caller's pcs[], its label into lab and the label's cells into lin (0 for
# a cut server too long to sit beside it, which goes without)
auroraMotdTunPcs() {
  local -i _iw=$2 _vw=$(( $2 - lw )) _i _w=lw _sw _r _k
  local -a lst
  local _c _x
  lab="" lin=lw
  for (( _i = 0; _i < ${#1}; _i++ )); do
    _c=${1:_i:1} lst=()
    case $_c in
      s)
        lab=SERVER
        if [[ -z $server ]]; then
          # Not logged yet, or so long ago it's further back than is read
          if (( logWhole )); then
            pcs+=("dnot logged yet") _sw=14
          else
            pcs+=("dnot in the recent log") _sw=21
          fi
        elif [[ -z $proto ]]; then
          pcs+=("$vc$server") _sw=${#server}
        elif (( tSa <= _vw || (tSb > _vw && tSa <= _iw) )); then
          pcs+=("$vc$server" "f · " "$vc$proto") _sw=tSa
        else
          pcs+=("$vc$proto " "$vc$server") _sw=tSb
        fi
        if [[ -n $3 ]] && (( _sw > _vw && _sw <= _iw )); then lab="" lin=0 _w=0; fi
        _w+=_sw ;;
      c)
        if (( _i )); then pcs+=("f · "); _w+=3; else lab=CIPHER; fi
        pcs+=("$vc${cipher:--}") _w+=tC ;;
      t)
        if (( _i )); then pcs+=("f · " "${il}TLS "); _w+=7; else lab=TLS; fi
        pcs+=("$vc${tlsVer:--}")
        [[ -n $kex ]] && pcs+=("|f · " "$vc$kex")
        _w+=tL
        if (( pq )); then
          # The long chip when the row holds it, else the short one
          _x=" ◆ post-quantum "
          (( _w + 18 <= _iw )) || _x=" ◆ PQ "
          pcs+=("|w  " "$pk$_x") _w+=$(( 2 + ${#_x} ))
        fi ;;
      u)
        lab=TUN
        pcs+=("$vc$tunIp" "|f · ")
        if [[ $tunnelMode == full ]]; then
          pcs+=("${vc}full tunnel") _w+=tU
        elif [[ -z $3 ]] || (( tU <= _vw )); then
          _x=routes
          (( routeCount == 1 )) && _x=route
          pcs+=("${vc}split" "d, $routeCount $_x") _w+=tU
        else
          # Cut: its routes go before its mode does
          pcs+=("${vc}split") _w+=tUs
        fi ;;
      d|D)
        if (( ! _i )); then
          # A row of its own: as many as fit, the rest counted; a first too
          # long to sit beside the label gets the row's width, under it
          # (not in a cut row, which has no row under it: how many instead)
          lab=DNS _r=_vw
          (( ${#dns[0]} > _vw )) && [[ -z $3 ]] && _r=_iw
          auroraMotdList lst "$_r" 2 "${dns[@]/#/$vc}"
          if (( ! ${#lst[@]} )); then
            _x=servers
            (( ${#dns[@]} == 1 )) && _x=server
            lst=("d${#dns[@]} $_x")
          fi
        elif [[ $_c == d ]]; then
          auroraMotdList lst 999 2 "${dns[@]/#/$vc}"
        else
          # Counted: as many as fit, else how many
          _r=$(( _iw - _w - 7 ))
          auroraMotdList lst "$_r" 2 "${dns[@]/#/$vc}"
          if (( ! ${#lst[@]} )); then
            _x="+${#dns[@]}"
            (( ${#_x} <= _r )) && lst=("d$_x")
          fi
        fi
        if (( _i && ${#lst[@]} )); then pcs+=("f · " "${il}DNS "); _w+=7; fi
        for _x in "${lst[@]}"; do _w+=$(( ${#_x} - 1 )); done
        pcs+=("${lst[@]}") ;;
      q|Q)
        if (( ! _i )); then
          lab=SEARCH
          auroraMotdDomains lst "$_vw"
        elif [[ $_c == q ]]; then
          auroraMotdList lst 999 2 "${tQs[@]/#/$vc}"
        else
          auroraMotdDomains lst $(( _iw - _w - 10 ))
        fi
        if (( _i && ${#lst[@]} )); then pcs+=("f · " "${il}search "); _w+=10; fi
        for _x in "${lst[@]}"; do _w+=$(( ${#_x} - 1 )); done
        pcs+=("${lst[@]}") ;;
    esac
  done
}

# auroraMotdTunRow <row> <cells> [cut]: a TUNNEL row onto cRows[] and cW[]:
# wrapped where its first part may wrap, or cut to one row
auroraMotdTunRow() {
  local -a pcs=()
  local lab lin
  auroraMotdTunPcs "$@"
  if [[ -n $3 ]]; then
    auroraMotdOne "$2" "$lin" "${lab:+v$lab}" "${pcs[@]}"
  else
    auroraMotdItem "$2" "$lin" "${lab:+v$lab}" "${pcs[@]}"
  fi
}

# auroraMotdTunForm <cells> <form>: form j0-j3's rows at <cells> into
# tF[<form>@<cells>] and their number into tN[...], counted from the widths
# - a part that can't sit beside its label takes more than one row - and
# built only for TLS when its chip may wrap (auroraMotdTunKey builds the
# rest of the form that's used)
auroraMotdTunForm() {
  local _k=$2@$1 _r _rows=""
  local -i _iw=$1 _vw=$(( $1 - lw )) _j=${2:1} _w _one _t _n=0
  [[ -n ${tN[$_k]} ]] && return 0
  auroraMotdTunPrep
  # The cipher and TLS join only with a value: unknown, each is a "-" that
  # needs its label. With neither known there are no rows of them at all.
  _one=$(( tSa <= _vw || tSb <= _vw )) _w=$(( lw + (tSa <= _vw ? tSa : tSb) )) _r=s
  if [[ -n $cipher$tlsVer ]]; then
    # TLS with the chip as it would be there; beside the server, before an
    # unknown cipher's row, when that's where it fits
    _t=$(( tL + (pq ? 2 + (_w + 7 + tL + 18 <= _iw ? 16 : 6) : 0) ))
    if (( _j >= 3 && _one && ! ${#cipher} && ${#tlsVer} && _w + 7 + _t <= _iw )); then
      _rows+=" ${_r}t" _r=c
    elif (( _j >= 1 && _one && ${#cipher} && _w + 3 + tC <= _iw )); then
      _r+=c _w+=3+tC
    else
      _rows+=" $_r" _r=c _w=lw+tC _one=1
    fi
    if [[ $_rows != *t ]]; then
      _t=$(( tL + (pq ? 2 + (_w + 7 + tL + 18 <= _iw ? 16 : 6) : 0) ))
      if (( _j >= 3 && _one && ${#tlsVer} && _w + 7 + _t <= _iw )); then
        _r+=t
      else
        _rows+=" $_r" _r=t
      fi
    fi
  fi
  _rows+=" $_r"
  if [[ -n $tunIp ]]; then
    _r=u _w=lw+tU _one=$(( tU <= _vw ))
    if (( ${#dns[@]} )); then
      if (( _j >= 2 && _one && _w + 7 + tD <= _iw )); then
        _r+=d _w+=7+tD
      else
        _rows+=" $_r" _r=d
        _w=$(( tD <= _vw ? lw + tD : _iw )) _one=$(( ${#dns[0]} <= _vw ))
      fi
    fi
    if (( ${#tQs[@]} )); then
      if (( _one && _w + 10 + tQ <= _iw )); then _r+=q; else _rows+=" $_r" _r=q; fi
    fi
    _rows+=" $_r"
  fi
  tF[$_k]=""
  for _r in $_rows; do
    case $_r in
      s*) _n+=$(( tSa <= _vw || tSb <= _vw || (tSa > _iw && tSb > _iw) ? 1 : 2 )) ;;
      u*) _n+=$(( tU <= _vw ? 1 : 2 )) ;;
      d*)
        # Under its label only when it fits there with its "+N"; else it's
        # "N servers" beside it
        _t=$(( ${#dns[@]} - 1 )); _t=$(( _t ? 3 + ${#_t} : 0 ))
        _n+=$(( ${#dns[0]} <= _vw || ${#dns[0]} + _t > _iw ? 1 : 2 )) ;;
      t*)
        if (( lw + tL + (pq ? 8 : 0) <= _iw )); then
          _n+=1
        else
          [[ -n ${cnt[T$_r@$1]} ]] || auroraMotdNeed "T$_r@$1" auroraMotdTunRow "$_r" "$1"
          _n+=${cnt[T$_r@$1]}
        fi ;;
      *) _n+=1 ;;
    esac
    tF[$_k]+=" T$_r@$1"
  done
  tN[$_k]=$_n
}

# auroraMotdTunCut <cells> <rows>: form c<rows>: j3's rows a row each, the
# row whose most needed part is the least needed left out while there are
# too many (SEARCH, DNS, TLS, CIPHER, TUN), a DNS or SEARCH row counted on
# the row it would have joined
auroraMotdTunCut() {
  local _k=c$2@$1 _r _m
  local -a _rw=()
  local -i _i _p _lo _best _q
  [[ -n ${tN[$_k]} ]] && return 0
  auroraMotdTunForm "$1" j3
  for _r in ${tF[j3@$1]}; do _r=${_r#T}; _rw+=("${_r%@*}"); done
  while (( ${#_rw[@]} > ($2 > 1 ? $2 : 1) )); do
    _lo=0 _best=9
    for (( _i = 0; _i < ${#_rw[@]}; _i++ )); do
      _r=${_rw[_i]//[!sctudq]/} _p=1
      case $_r in
        *s*) _p=6 ;; *u*) _p=5 ;; *c*) _p=4 ;; *t*) _p=3 ;; *d*) _p=2 ;;
      esac
      (( _p < _best )) && _best=_p _lo=_i
    done
    _r=${_rw[_lo]}
    if (( _lo )) && [[ $_r == [dq]* ]]; then
      # Counted on the row before: DNS, and the search domains with it
      _m=""
      [[ $_r == d* ]] && _m=D
      [[ $_r == *[qQ]* ]] && _m+=Q
      _rw[_lo-1]+=$_m
    fi
    unset '_rw[_lo]'
    _rw=("${_rw[@]}")
  done
  tF[$_k]=""
  for _r in "${_rw[@]}"; do tF[$_k]+=" C$_r@$1"; done
  tN[$_k]=${#_rw[@]}
}

# auroraMotdTunGrid <cells>: j0's parts two to a row onto cRows[] and cW[] -
# the server beside the tunnel, CIPHER beside DNS, TLS beside SEARCH -
# uForced when a pair doesn't fit
auroraMotdTunGrid() {
  local -a gP=() gS=() gN=() pcs _o=() _rt=()
  local -i _i
  local _c lab lin
  for _c in s c t u d q; do
    case $_c in
      u) [[ -n $tunIp ]] || continue ;;
      d) [[ -n $tunIp ]] && (( ${#dns[@]} )) || continue ;;
      q) [[ -n $tunIp ]] && (( ${#tQs[@]} )) || continue ;;
    esac
    pcs=()
    auroraMotdTunPcs "$_c" "$1"
    auroraMotdAdd "v$lab" "${pcs[@]}"
    if [[ $_c == [sct] ]]; then _o+=($(( ${#gS[@]} - 1 ))); else _rt+=($(( ${#gS[@]} - 1 ))); fi
  done
  # Paired in turn, left and right, what's left over after
  for (( _i = 0; _i < ${#_rt[@]}; _i++ )); do _o[_i]+=" ${_rt[_i]}"; done
  gridTwo=0
  auroraMotdGrid "$1" two ${_o[*]}
  (( gridTwo )) || uForced=1
}

# auroraMotdTunTwo <cells>: form two (auroraMotdTunGrid), its rows counted
# from the widths, paired as auroraMotdTunGrid pairs them, so it's built
# only when it's used; tN 0 when a pair doesn't fit, the server can't sit
# beside its label or the odd one out would wrap
auroraMotdTunTwo() {
  local -i _iw=$1 _vw=$(( $1 - lw )) _i _l=0 _r=0 _n=0
  local -a _w _o=()
  [[ -n ${tN[two@$1]} ]] && return 0
  auroraMotdTunPrep
  tN[two@$1]=0
  (( tSa <= _vw || tSb <= _vw )) && [[ -n $cipher$tlsVer ]] || return 0
  _w=($(( tSa <= _vw ? tSa : tSb )) "$tC" $(( tL + (pq ? (lw + tL + 18 <= _iw ? 18 : 8) : 0) )))
  if [[ -n $tunIp ]]; then
    _w+=("$tU")
    if (( ${#dns[@]} )); then _w+=($(( tD < _vw ? tD : _vw ))); fi
    if (( ${#tQs[@]} )); then _w+=($(( tQ < _vw ? tQ : _vw ))); fi
  fi
  for (( _i = 0; _i < 3; _i++ )); do
    _o+=("$_i")
    (( _i + 3 < ${#_w[@]} )) && _o+=($(( _i + 3 )))
  done
  for (( _i = 0; _i < ${#_o[@]}; _i += 2 )); do
    if (( _i + 1 < ${#_o[@]} )); then
      (( _w[_o[_i]] > _l )) && _l=_w[_o[_i]]
      (( _w[_o[_i+1]] > _r )) && _r=_w[_o[_i+1]]
    elif (( lw + _w[_o[_i]] > _iw )); then
      return 0
    fi
    _n+=1
  done
  (( lw + _l + 3 + lw + _r <= _iw )) || return 0
  tF[two@$1]=" T2@$1" tN[two@$1]=$_n
}

# auroraMotdTunKey <cells> <form>: into tk the key the form's rows are
# kept under, joined (auroraMotdTunForm, auroraMotdTunCut, auroraMotdTunTwo)
auroraMotdTunKey() {
  local _r _c
  local -a _ks=()
  tk=T$2+@$1
  [[ -n ${cnt[$tk]} ]] && return 0
  for _r in ${tF[$2@$1]}; do
    _c=${_r:1} _c=${_c%@*}
    if [[ -n ${cnt[$_r]} ]]; then
      :
    elif [[ $_c == 2 ]]; then
      auroraMotdNeed "$_r" auroraMotdTunGrid "$1"
    elif [[ $_r == C* ]]; then
      auroraMotdNeed "$_r" auroraMotdTunRow "$_c" "$1" cut
    else
      auroraMotdNeed "$_r" auroraMotdTunRow "$_c" "$1"
    fi
    _ks+=("$_r")
  done
  auroraMotdJoin "$tk" "${_ks[@]}"
}

# auroraMotdTunnelIn <cells> <rows> <full|short>: TUNNEL beside ACCESS, in
# the richest form that fits ACCESS's <rows> rows, so neither card has blank
# rows beside the other's values; when none does, the form with the fewest
# rows (ACCESS gets the blank ones), or with short, cut to those rows. Into
# tf the form and tn its rows (auroraMotdTunKey builds it).
auroraMotdTunnelIn() {
  local _f _b="" _c=ti$3$2@$1
  local -i _n=999
  if [[ -z ${tfOf[$_c]} ]]; then
    for _f in j0 j1 j2 j3; do
      auroraMotdTunForm "$1" "$_f"
      if (( ${tN[$_f@$1]} <= $2 )); then _b=$_f; break; fi
      (( ${tN[$_f@$1]} < _n )) && _n=${tN[$_f@$1]} _b=$_f
    done
    if [[ $3 == short ]] && (( ${tN[$_b@$1]} > $2 )); then
      _b=c$2
      auroraMotdTunCut "$1" "$2"
    fi
    tfOf[$_c]=$_b
  fi
  tf=${tfOf[$_c]} tn=${tN[${tfOf[$_c]}@$1]}
}

# auroraMotdTunnelBox <cells> <form>: TUNNEL at full width: one a part a
# row; full (two) two to a row where every pair fits; pack the fewest rows
# of those and j1-j3; short the fewer of that and three rows cut; r2 and r1
# cut to two rows and one. Into tf the form and tn its rows
# (auroraMotdTunKey builds it).
auroraMotdTunnelBox() {
  local _c=tb$2@$1 _b=j0 _f
  if [[ -n ${tfOf[$_c]} ]]; then tf=${tfOf[$_c]} tn=${tN[${tfOf[$_c]}@$1]}; return 0; fi
  case $2 in
    one) auroraMotdTunForm "$1" j0 ;;
    r2|r1) _b=c${2:1}; auroraMotdTunCut "$1" "${2:1}" ;;
    *)
      auroraMotdTunForm "$1" j0
      auroraMotdTunTwo "$1"
      (( ${tN[two@$1]} )) && _b=two
      if [[ $2 == pack || $2 == short ]]; then
        for _f in j1 j2 j3; do
          auroraMotdTunForm "$1" "$_f"
          (( ${tN[$_f@$1]} < ${tN[$_b@$1]} )) && _b=$_f
        done
      fi
      if [[ $2 == short ]]; then
        auroraMotdTunCut "$1" 3
        (( ${tN[c3@$1]} < ${tN[$_b@$1]} )) && _b=c3
      fi ;;
  esac
  tfOf[$_c]=$_b tf=$_b tn=${tN[$_b@$1]}
}

# auroraMotdAliases <cells> <rows>: the aliases as chips in at most <rows>
# rows, or a row saying how to add some
auroraMotdAliases() {
  local -a _c=()
  local _a _t
  local -i _w
  if (( ${#aliases[@]} && $2 >= 99 )); then
    # All of them (99): chips in turn, a row when one's full
    row="" rw=0
    for _a in "${aliases[@]}"; do
      (( ${#_a} + 2 > $1 )) && fitText _a "$_a" $(( $1 - 2 ))
      _w=$(( ${#_a} + 2 ))
      if (( rw && rw + 1 + _w > $1 )); then
        cRows+=("$row"); cW+=("$rw")
        row="" rw=0
      fi
      (( rw )) && row+=" " rw+=1
      row+="${pieceColour[C]} $_a $cOff" rw+=_w
    done
    cRows+=("$row"); cW+=("$rw")
  elif (( ${#aliases[@]} )); then
    for _a in "${aliases[@]}"; do
      _t=$_a
      (( ${#_a} > $1 - 2 )) && fitText _t "$_a" $(( $1 - 2 ))
      _c+=("C $_t ")
    done
    rowStart
    auroraMotdFlow "$1" $(( $2 - 1 )) 1 'd%s more|d%s' "${_c[@]}"
    cRows+=("$row"); cW+=("$rw")
  elif (( $1 >= 31 )); then
    auroraMotdOne "$1" 0 "" "dnone yet" "f · " "wCUSTOMCONF" "d adds them"
  else
    auroraMotdOne "$1" 0 "" "dnone yet"
  fi
}

# auroraMotdHelp <cells> <full|one>: what to reach for, under the cards:
# the commands (sso-url for an SSO profile), and in full the switch for
# servers that need legacy TLS and the logs; one is a single row of as many
# whole hints as fit
auroraMotdHelp() {
  local -a _p=("wvpn-restart")
  if [[ $2 == one ]]; then
    [[ $auth == sso ]] && _p+=("|f · " "wsso-url")
    auroraMotdOne "$1" 9 "vHELP" "${_p[@]}" "|f · " "wapk add" "|f · " "dlogs in " "w/var/log"
    return 0
  fi
  _p+=("d reconnect")
  [[ $auth == sso ]] && _p+=("|f · " "wsso-url" "d sign-in link")
  # The switch and what it's for together, unless a row can't hold both
  local -a _o=("d for legacy TLS")
  (( 9 + 48 > $1 )) && _o=("|d " "dfor legacy TLS")
  auroraMotdItem "$1" 9 "vHELP" "${_p[@]}" "|f · " "wapk add" "d packages" \
    "|f · " "wOPENSSL_CONF=/config/openssl.cnf" "${_o[@]}"
  auroraMotdItem "$1" 9 "vLOGS" "w/var/log/openvpn.log" "|f · " "w/var/log/sockd.log" \
    "|f · " "w/var/log/jumpbox.log"
}

# auroraMotdNeed <key> <builder> <arg>...: a builder's rows, built the
# first time a layout being tried asks for them and kept in the caller's
# vR[] and vW[] (as <key>/0, <key>/1...), their number in cnt[<key>], and
# in vT[<key>] whether the builder found the part can't be whole there
# (uForced)
auroraMotdNeed() {
  [[ -n ${cnt[$1]} ]] && return 0
  local -i _i uForced=0
  cRows=() cW=()
  "${@:2}"
  for (( _i = 0; _i < ${#cRows[@]}; _i++ )); do
    vR[$1/$_i]=${cRows[_i]} vW[$1/$_i]=${cW[_i]}
  done
  cnt[$1]=${#cRows[@]} vT[$1]=$uForced
}

# Fitting to the height. Each layout has knobs - what it shows, and how
# much of it - set to its richest arrangement, and one ordered list of
# steps, each giving up one thing (knob=value): the list is the priorities,
# what goes first at its head, and each layout says what its steps give up
# where it passes them. The richest arrangement is used when it fits; when
# even every step taken doesn't fit, the layout gives way to the next.
# Otherwise the first step at which it fits is found (each step only takes
# away, so halving the list finds it), and the list is walked back from
# there, the most important first: what was given up on the way comes back
# wherever it still fits, a knob a later step took further coming back a
# step at a time, and a knob that couldn't come back isn't tried again
# (richer is never shorter). The totals add up the rows auroraMotdNeed
# keeps and stop before TUNNEL once they're over, so trying an arrangement
# costs little once its parts are built.
# auroraMotdFit <total> <step>...: 0 when an arrangement fits (the knobs as
# it has them, its total and keys worked out), 1 when none does
auroraMotdFit() {
  local -i _i _j _k _n=$(( $# - 1 )) _p=-1
  local -a _st=("${@:2}") _was=()
  local -A _at=()
  local _v _s _o
  # Tall panes: the richest first, as it most often fits. Else every step
  # taken first, so a layout that can't fit at all gives up having built
  # only what it would have shown least of.
  if (( budget >= 26 )); then
    "$1"
    (( total <= budget )) && return 0
  fi
  for (( _i = 0; _i < _n; _i++ )); do
    _v=${_st[_i]%%=*}
    _was[_i]=${!_v} _at[${_st[_i]}]=$_i
    printf -v "$_v" '%s' "${_st[_i]#*=}"
  done
  "$1"
  (( total <= budget )) || return 1
  _p=_n-1
  if (( budget < 26 )); then
    for (( ; _p >= 0; _p-- )); do printf -v "${_st[_p]%%=*}" '%s' "${_was[_p]}"; done
    "$1"
    (( total <= budget )) && return 0
  fi
  # The first step that fits: each takes something away, so halving the
  # range finds it (steps 0.._lo-1 don't fit, 0.._hi do). The knobs move
  # from the steps taken (0.._p) to the next try's a step at a time, back
  # (undone in turn, latest first) or on.
  local -i _lo=0 _hi=_n-1 _m
  while (( _lo <= _hi )); do
    _m=$(( _lo < _hi ? (_lo + _hi) / 2 : _lo ))
    for (( ; _p > _m; _p-- )); do printf -v "${_st[_p]%%=*}" '%s' "${_was[_p]}"; done
    for (( ; _p < _m; )); do _p+=1; printf -v "${_st[_p]%%=*}" '%s' "${_st[_p]#*=}"; done
    (( _lo == _hi )) && break
    "$1"
    if (( total <= budget )); then _hi=_m; else _lo=_m+1; fi
  done
  _i=_lo
  local -A _no=()
  for (( _k = _i - 1; _k >= 0; _k-- )); do
    _v=${_st[_k]%%=*} _s=${_st[_k]#*=} _o=${!_v}
    # Back to a richer value can only be taller than one that didn't fit
    [[ -n ${_no[$_v]} ]] && continue
    if [[ $_o == "$_s" ]]; then
      printf -v "$_v" '%s' "${_was[_k]}"
    else
      # Its value is a later step's (_at: where each step is) still taken
      _j=${_at[$_v=$_o]:-_n}
      (( _j > _k && _j <= _i )) || continue
      printf -v "$_v" '%s' "$_s"
    fi
    "$1"
    (( total <= budget )) || { printf -v "$_v" '%s' "$_o"; _no[$_v]=1; }
  done
  "$1"
  return 0
}

# auroraMotdUnits: the state block's parts in order (auroraMotdUnit) into
# the caller's units[], and whether the server being retried fits whole
# beside the badge, sw cells: retryBeside
auroraMotdUnits() {
  units=(b)
  case $view$ovpnUp in
    down1)
      retryBeside=$(( ${#server} && ${#badge} + 12 + ${#server} + (${#proto} ? 3 + ${#proto} : 0) <= sw ))
      (( retryBeside )) || [[ -z $server ]] || units+=(y)
      units+=(m n) ;;
    # Nothing to run while it's starting: vpn-restart would say to wait
    down0) units+=(m); (( starting )) || units+=(n) ;;
    sso*) units+=(n) ;;
    *) (( warn )) && units+=(w) ;;
  esac
  (( ${#bad[@]} )) && units+=(x)
  units+=(e k)
  [[ -n $rxText ]] && units+=(t)
}

# auroraMotdBanner <width> <key>: the top panel, one line per row, for the
# state block's arrangement <key> (auroraMotdState): the panel's own frame
# - the flag, name and versions on top, the profile and the container on
# the bottom border - around the logo (art[], artW cells wide) and, 3
# cells after it, what goes beside it, the two centred against each other
# (the rule under the badge), then what flowed under the logo across it
auroraMotdBanner() {
  local -i _w=$1 _U=${sU[$2]} _A=${#art[@]} _h _k _r _lo _bo _i
  local -a _sR=() _sW=() _lR=() _lW=()
  local _x _t rule
  for _x in ${sBes[$2]}; do
    for (( _i = 0; _i < ${cnt[$_x@$sw]}; _i++ )); do
      _sR+=("${vR[$_x@$sw/$_i]}") _sW+=("${vW[$_x@$sw/$_i]}")
    done
    if [[ $_x == b* ]] && (( ${sRule[$2]} )); then
      repeatText rule "$sw" ─
      _sR+=("$cFnt$rule") _sW+=("$sw")
    fi
  done
  for _x in ${sBel[$2]}; do
    for (( _i = 0; _i < ${cnt[$_x@$flowW]}; _i++ )); do
      _lR+=("${vR[$_x@$flowW/$_i]}") _lW+=("${vW[$_x@$flowW/$_i]}")
    done
  done
  _lo=$(( (_U - _A) / 2 )) _bo=$(( (_U - ${#_sR[@]}) / 2 )) _h=$(( _U + ${#_lR[@]} + 2 ))
  for (( _k = 0; _k < _h; _k++ )); do
    gr=${#out[@]}; rowStart; rowPad 1
    if (( _k == 0 )); then
      _t=$vpnVer
      [[ -n $osVer ]] && _t+="${_t:+ · }Alpine $osVer"
      auroraMotdTop "$_w" "$flag" "PROJECT JUMPBOX" "$_t"
    elif (( _k == _h - 1 )); then
      auroraMotdHeroFoot "$_w"
    else
      _r=$(( _k - 1 ))
      auroraMotdGlyph "│"; rowPad 1
      if (( _r < _U )); then
        (( _r >= _lo && _r - _lo < _A )) && auroraMotdArt $(( _r - _lo ))
        rowTo $(( artW + 6 ))
        (( _r >= _bo && _r - _bo < ${#_sR[@]} )) && { row+=${_sR[_r-_bo]}; rw+=${_sW[_r-_bo]}; }
      else
        row+=${_lR[_r-_U]}; rw+=${_lW[_r-_U]}
      fi
      rowTo "$_w"; auroraMotdGlyph "│"
    fi
    auroraMotdPut
  done
}

# auroraMotdAliasRows <cells>: into aliRows, how many rows the aliases'
# chips take <cells> wide with no limit (the card's at most ali of them):
# counted, not built, as only the one the knobs settle on is
auroraMotdAliasRows() {
  local _a
  local -i _x=0 _w
  aliRows=1
  for _a in "${aliases[@]}"; do
    _w=$(( ${#_a} + 2 > $1 ? $1 : ${#_a} + 2 ))
    if (( _x && _x + 1 + _w > $1 )); then aliRows+=1 _x=_w; else _x+=$(( (_x ? 1 : 0) + _w )); fi
  done
}

# auroraMotdTail: the aliases and the help, as the knobs have them
auroraMotdTail() {
  (( ali )) && total+=$(( (ali < aliRows ? ali : aliRows) + 2 ))
  if [[ $hlp != 0 ]]; then
    auroraMotdNeed "h$hlp@$flowW" auroraMotdHelp "$flowW" "$hlp"
    total+=${cnt[h$hlp@$flowW]}
  fi
}

# auroraMotdCards: the aliases' card and the help, under the others
auroraMotdCards() {
  local -i _a=$(( ali < aliRows ? ali : 99 ))
  if (( ali )); then
    auroraMotdNeed "l$_a@$flowW" auroraMotdAliases "$flowW" "$_a"
    auroraMotdBox "$cw" ALIASES "l$_a@$flowW"
  fi
  [[ $hlp != 0 ]] && auroraMotdFoot "h$hlp@$flowW"
  return 0
}

# auroraMotdWideTotal: the wide layout's height, as the knobs have it.
# Beside each other, TUNNEL picks its form by ACCESS's height with MOUNTS
# on a row; when TUNNEL still comes out taller, MOUNTS takes the rows it
# leaves beside it (ak, ACCESS's key) - TUNNEL never sees that. Already
# over the budget before TUNNEL, it stops there: TUNNEL can only add.
auroraMotdWideTotal() {
  auroraMotdState
  total=$(( hh + 2 + gap ))
  auroraMotdTail
  if (( pair )); then
    auroraMotdAccessRows $(( left - 4 )) "$mnt"
    total+=$(( nA + 2 ))
    # Too tall already: TUNNEL can only add to it (and isn't built)
    (( total > budget )) && return 0
    auroraMotdTunnelIn $(( right - 4 )) "$nA" "${tun/pack/full}"
    nT=tn
    if (( nT > nA )); then
      total+=$(( nT - nA ))
      auroraMotdAccessRows $(( left - 4 )) "$mnt" $(( nT - nA ))
    fi
  else
    auroraMotdAccessRows "$flowW" "$mnt"
    total+=$(( nA + 2 ))
    (( total + 3 > budget )) && { total+=3; return 0; }
    auroraMotdTunnelBox "$flowW" "$tun"
    total+=$(( tn + 2 ))
  fi
}

# auroraMotdWide: 100 columns and up (116 used at most): the banner panel,
# then ACCESS and TUNNEL side by side - stacked when ACCESS's commands need
# the room - the aliases and the help
auroraMotdWide() {
  local -i cw=$(( motdCols - 1 > 116 ? 116 : motdCols - 1 )) left right pair=1 k h hh total sw flowW nA nT \
    gap=1 trf=1 tck=3 mnt=1 ali=99 flow=0 rul=0 retryBeside=0 exitFlag=1 aliRows need tn
  local hlp=full tun=full sk tk tf ak
  local -a units

  # JUMPBOX in FIGlet's ANSI Shadow
  art=(
    '     ██╗██╗   ██╗███╗   ███╗██████╗ ██████╗  ██████╗ ██╗  ██╗'
    '     ██║██║   ██║████╗ ████║██╔══██╗██╔══██╗██╔═══██╗╚██╗██╔╝'
    '     ██║██║   ██║██╔████╔██║██████╔╝██████╔╝██║   ██║ ╚███╔╝'
    '██   ██║██║   ██║██║╚██╔╝██║██╔═══╝ ██╔══██╗██║   ██║ ██╔██╗'
    '╚█████╔╝╚██████╔╝██║ ╚═╝ ██║██║     ██████╔╝╚██████╔╝██╔╝ ██╗'
    ' ╚════╝  ╚═════╝ ╚═╝     ╚═╝╚═╝     ╚═════╝  ╚═════╝ ╚═╝  ╚═╝'
  )
  artW=61 artGlyphs='╗║╔═╝╚' artShadow=1
  sw=$(( cw - 4 - artW - 3 )) flowW=$(( cw - 4 ))
  auroraMotdAliasRows "$flowW"

  # Side by side, split by need: half each, or what ACCESS's commands need
  # (gridNeed), and TUNNEL what its server row needs beside its label when
  # ACCESS can spare it; stacked when that leaves TUNNEL under 46 cells.
  # Settled here, from the data, so every arrangement tried has the same.
  auroraMotdAccess 0 one 0
  auroraMotdTunPrep
  left=$(( (cw - 1) / 2 ))
  (( gridNeed + 4 > left )) && left=$(( gridNeed + 4 ))
  right=$(( cw - 1 - left ))
  for need in $(( lw + tSa + 4 )) $(( lw + tSb + 4 )); do
    (( right >= need )) && break
    if (( cw - 1 - need >= gridNeed + 4 )); then right=need left=$(( cw - 1 - need )); break; fi
  done
  (( right < 46 )) && pair=0 mnt=2
  # A TUNNEL two rows shorter than ACCESS (no tunnel any more): ACCESS
  # widened until the ssh row holds the password, if TUNNEL can spare it;
  # still that much shorter, they're stacked - no card a box of blank rows
  # beside the other
  if (( pair )); then
    auroraMotdAccessRows $(( left - 4 )) 1
    auroraMotdTunForm $(( right - 4 )) j0
    if (( ${tN[j0@$(( right - 4 ))]} + 2 <= nA )); then
      need=$(( lw + 49 + ${#sshPort} + (sshUp ? 0 : 19) ))
      if (( need > left && cw - 1 - need >= 46 && cw - 1 - need >= lw + tSb + 4 )); then
        left=need right=$(( cw - 1 - need ))
        auroraMotdAccessRows $(( left - 4 )) 1
        auroraMotdTunForm $(( right - 4 )) j0
      fi
      (( ${tN[j0@$(( right - 4 ))]} + 2 <= nA )) && pair=0 mnt=2
    fi
  fi
  # The least it can take: the banner and ACCESS's three ways in (TUNNEL
  # beside them, or cut short under them)
  (( budget >= 13 + (pair ? 0 : 5) )) || return 1
  auroraMotdUnits

  # Given up first: the blank row under the banner; with no aliases, their
  # card (lead: it would only say how to add some); MOUNTS past its first
  # row (beside TUNNEL it only ever takes rows TUNNEL leaves free); TUNNEL
  # stacked tighter (nothing left out); HELP's long lines; the state block
  # flowing on under the logo; alias rows past the first; the traffic; the
  # checks' rows, down to one, then to what's fine after the problems, or
  # a count on the badge's row (else a row of its own); MOUNTS; TUNNEL cut
  # short; the help and the aliases, in the order the state wants (while
  # it's down the help, with the logs, outlasts them). Never: the badge,
  # CAUTION's line, why it's down and what to run, what's wrong, the exit,
  # the ways in, TUNNEL - the medium layout is next.
  auroraMotdFit auroraMotdWideTotal gap=0 "${lead[@]}" mnt=1 tun=pack hlp=one flow=1 "${aliRow[@]}" trf=0 \
    tck=2 tck=1 tck=0 mnt=0 tun=short "${last[@]}" || return 1

  auroraMotdBanner "$cw" "$sk"
  (( gap )) && out+=("$cOff")
  [[ $ak == *+* ]] && auroraMotdJoin "$ak" "${ak%+*}" "${ak#*+}"
  if (( pair )); then
    auroraMotdTunKey $(( right - 4 )) "$tf"
    h=$(( (nA > nT ? nA : nT) + 2 ))
    for (( k = 0; k < h; k++ )); do
      gr=${#out[@]}; rowStart; rowPad 1
      auroraMotdCard "$left" ACCESS "$ak" "$h" "$k"; rowPad 1
      auroraMotdCard "$right" TUNNEL "$tk" "$h" "$k" "${tunNote[@]}"
      auroraMotdPut
    done
  else
    auroraMotdBox "$cw" ACCESS "$ak"
    auroraMotdTunKey "$flowW" "$tf"
    auroraMotdBox "$cw" TUNNEL "$tk" "${tunNote[@]}"
  fi
  auroraMotdCards
  blank=1
}

# auroraMotdMediumTotal: the one-column layout's height, as the knobs
# have it
auroraMotdMediumTotal() {
  auroraMotdState
  total=$(( hh + 2 ))
  auroraMotdTail
  auroraMotdAccessRows "$flowW" "$mnt"
  total+=$(( nA + 2 ))
  if [[ $tun != 0 ]]; then
    # Too tall already: TUNNEL can only add to it (and isn't built)
    (( total + 3 > budget )) && { total+=3; return 0; }
    auroraMotdTunnelBox "$flowW" "$tun"
    total+=$(( tn + 2 ))
  fi
}

# auroraMotdMedium: 60 columns and up: a small logo beside the state in
# the panel's frame, then ACCESS, TUNNEL, the aliases and the help, a card
# a row
auroraMotdMedium() {
  local -i cw=$(( motdCols - 1 > 116 ? 116 : motdCols - 1 )) hh total sw flowW trf=1 tck=3 mnt=2 ali=99 \
    flow=0 rul=1 retryBeside=0 exitFlag=1 aliRows nA tn
  local hlp=full tun=one sk tk tf ak
  local -a units

  # JUMPBOX in pixel fonts of half blocks: 5x6, or 3x6 (M 5 wide) where
  # that would leave the state too little room
  if (( cw - 4 - 41 - 3 >= 30 )); then
    art=(
      '  ▀▀█ █   █ █▄ ▄█ █▀▀▀▄ █▀▀▀▄ ▄▀▀▀▄ █   █'
      '    █ █   █ █ ▀ █ █▄▄▄▀ █▀▀▀▄ █   █  ▀▄▀'
      '▀▄▄▄▀ ▀▄▄▄▀ █   █ █     █▄▄▄▀ ▀▄▄▄▀ ▄▀ ▀▄'
    )
    artW=41
  else
    art=(
      '  █ █ █ █▄ ▄█ █▀▄ █▀▄ ▄▀▄ █ █'
      '  █ █ █ █ ▀ █ █▄▀ █▀▄ █ █  █'
      '▀▄▀ █▄█ █   █ █   █▄▀ ▀▄▀ █ █'
    )
    artW=29
  fi
  artGlyphs="" artShadow=""
  sw=$(( cw - 4 - artW - 3 )) flowW=$(( cw - 4 ))
  auroraMotdAliasRows "$flowW"
  # The least it can take: the banner and ACCESS's three ways in
  (( budget >= 10 )) || return 1
  auroraMotdUnits

  # Given up first: the rule under the badge; with no aliases, their card;
  # TUNNEL two to a row, then tighter (nothing left out); HELP's long
  # lines; MOUNTS past its first row; the state block flowing on under the
  # logo; alias rows past the first; the traffic; the checks' rows, down to
  # one, then to what's fine after the problems, or a count on the badge's
  # row (else a row of its own); MOUNTS; TUNNEL cut short; the help and the
  # aliases, in the order the state wants; last TUNNEL itself, down to two
  # rows, one (its server), none. Never: the badge, CAUTION's line, why
  # it's down and what to run, what's wrong, the exit, the ways in.
  auroraMotdFit auroraMotdMediumTotal rul=0 "${lead[@]}" tun=two tun=pack hlp=one mnt=1 flow=1 "${aliRow[@]}" \
    trf=0 tck=2 tck=1 tck=0 mnt=0 tun=short "${last[@]}" tun=r2 tun=r1 tun=0 || return 1

  auroraMotdBanner "$cw" "$sk"
  [[ $ak == *+* ]] && auroraMotdJoin "$ak" "${ak%+*}" "${ak#*+}"
  auroraMotdBox "$cw" ACCESS "$ak"
  if [[ $tun != 0 ]]; then
    auroraMotdTunKey "$flowW" "$tf"
    auroraMotdBox "$cw" TUNNEL "$tk" "${tunNote[@]}"
  fi
  auroraMotdCards
  blank=1
}

# auroraMotdBadgeTop <width>: the compact panel's top border, as the status
# panel's compact one: the flag, the name while there's room, the badge
# (short when the long one won't fit) at the right
auroraMotdBadgeTop() {
  local -i _end=$(( rw + $1 ))
  local _b=$badge _n=""
  auroraMotdGlyph "╭─"
  (( _end - rw - ${#_b} - 6 - (${#flag} ? 3 : 0) < 0 )) && _b=$badgeShort
  if (( _end - rw - ${#_b} - 6 - (${#flag} ? 3 : 0) >= 16 )); then
    _n="PROJECT JUMPBOX"
  elif (( _end - rw - ${#_b} - 6 - (${#flag} ? 3 : 0) >= 8 )); then
    _n=JUMPBOX
  fi
  # A space after the corner only before the flag or the name
  [[ -n $flag || -n $_n ]] && rowPad 1
  [[ -n $flag ]] && rowAdd "" "$flag "
  if [[ -n $_n ]]; then rowAdd "$cBold$cWht" "$_n"; rowAdd "$cOff" " "; fi
  # The badge sits on the line like a bead: its own padding is the gap
  auroraMotdFill $(( _end - rw - ${#_b} - 2 ))
  auroraMotdPiece "S$_b" $(( _end - 2 ))
  auroraMotdGlyph "─╮"
}

# auroraMotdWays <part> <cells>: a way in for the compact panel, onto
# cRows[] and cW[]: s SOCKS5, h ssh and its password (after the command,
# beside it or under it), l a shell like this one. Labelled while there's
# room for the labels; narrower, the commands alone, the ports kept in
# sight (socks5 :10079, the ssh port first).
auroraMotdWays() {
  local -a pcs=()
  local _l=v
  case $1 in
    s) (( socksUp )) || _l=r ;;
    h) (( sshUp )) || _l=r ;;
  esac
  if (( $2 >= 42 )); then
    case $1 in
      s) auroraMotdItem "$2" 8 "${_l}SOCKS5" "w127.0.0.1:" "c$port" ;;
      h) auroraMotdItem "$2" 8 "${_l}SSH" "wssh jumpbox@127.0.0.1 -p " "c$sshPort" "|w   " "dpassword " "wjumpbox" ;;
      l) pcs=("vSHELL"); auroraMotdShell "$2"; auroraMotdItem "$2" 8 "${pcs[@]}" ;;
    esac
    return 0
  fi
  case $1 in
    s)
      if (( 17 + ${#port} <= $2 )); then
        auroraMotdItem "$2" 0 "" "${_l}socks5 " "w127.0.0.1:" "c$port"
      else
        auroraMotdItem "$2" 0 "" "${_l}socks5 " "w:" "c$port"
      fi ;;
    h)
      if (( 26 + ${#sshPort} <= $2 )); then
        auroraMotdItem "$2" 0 "" "${_l}ssh" "w jumpbox@127.0.0.1 -p " "c$sshPort" "|w  " "dpw " "wjumpbox"
      else
        auroraMotdItem "$2" 0 "" "${_l}ssh" "w -p " "c$sshPort" "w jumpbox@127.0.0.1" "|w  " "dpw " "wjumpbox"
      fi ;;
    l) auroraMotdShell "$2"; auroraMotdItem "$2" 0 "" "${pcs[@]}" ;;
  esac
}

# auroraMotdBit <part> <cells>: the compact panel's other rows, onto
# cRows[] and cW[]: r a faint rule, a the aliases on a row (or how to add
# some), p a row of help, as many whole hints as fit, o the checks'
# count, u the uptime
auroraMotdBit() {
  local _t
  case $1 in
    r) repeatText _t "$2" ─; cRows+=("$cFnt$_t"); cW+=("$2") ;;
    a)
      if (( ${#aliases[@]} )); then
        auroraMotdAliases "$2" 1
      elif (( $2 >= 37 )); then
        auroraMotdOne "$2" 0 "" "dno aliases yet" "f · " "wCUSTOMCONF" "d adds them"
      elif (( $2 >= 33 )); then
        auroraMotdOne "$2" 0 "" "dno aliases" "f · " "wCUSTOMCONF" "d adds them"
      else
        auroraMotdOne "$2" 0 "" "dno aliases yet"
      fi ;;
    p)
      local -a _p=("wvpn-restart")
      [[ $auth == sso ]] && _p+=("|f · " "wsso-url")
      auroraMotdOne "$2" 0 "" "${_p[@]}" "|f · " "dlogs in " "w/var/log" "|f · " "wapk add" ;;
    o) rowStart; auroraMotdPiece "g✓ "; auroraMotdPiece "d$okc" "$2"; cRows+=("$row"); cW+=("$rw") ;;
    u) rowStart; rowAdd "$cDim" "up "; rowAdd "$cWht" "$upText"; cRows+=("$row"); cW+=("$rw") ;;
  esac
}

# auroraMotdTailRow <var> <unit>: in <var>, the row of the unit (as built
# at iw) a short text at its right goes on: the last of the exit's and of
# CAUTION's line (not in the middle of a sentence), the first of the
# problems' with room for <tail cells> (tw); -1 when none has
auroraMotdTailRow() {
  local -i _i _n=${cnt[$2@$iw]:-0} _from=0
  printf -v "$1" '%d' -1
  [[ $2 == [ew]* ]] && _from=$(( _n - 1 ))
  for (( _i = _from; _i < _n; _i++ )); do
    if (( ${vW[$2@$iw/$_i]} + 2 + tw <= iw )); then
      printf -v "$1" '%d' "$_i"
      return 0
    fi
  done
}

# auroraMotdCompactRows: the compact panel's rows for the knobs into the
# caller's rows[] and widths[], in grp[] the part each came from, and in
# ranks[] what a very short pane keeps first, the lowest first (0: always):
# why it's down and what to run, the message's later rows, the exit, what's
# wrong, SOCKS5, SSH, SHELL, the checks (and what to run's later rows), the
# server being retried, the rest - but the rules (10: never then), and the
# checks' count on a row of its own after the server being retried. total
# gets the panel's height.
auroraMotdCompactRows() {
  local -i _i _n _at _g=0
  local _u _k _up=$upAt
  rows=() widths=() ranks=() grp=()
  # No row has room for the uptime: it leads the traffic, else the checks,
  # else it's a row of its own
  if [[ $_up == u ]]; then
    if (( trf )) && [[ -n $rxText ]]; then _up=t; elif (( tck || ${#unk[@]} )); then _up=k; fi
  fi
  for _u in "${units[@]}" o u r1 ws wh wl r2 a p; do
    _k=$_u _n=9 _at=-1 _g+=1
    case $_u in
      b) continue ;;
      w|m|n) _n=0 ;;
      y) _k=y2 _n=8 ;;
      x) _n=3; [[ $okAt == x ]] && _at=okRow ;;
      e) _k=e5 _n=2 ;;
      t) (( trf )) || continue; [[ $_up == t ]] && _k=tu ;;
      k) (( tck || ${#unk[@]} )) || continue; _k=k$tck _n=7; [[ $_up == k ]] && _k=ku$tck ;;
      o)
        [[ $okAt == o && -n $okc ]] && (( ! tck && ! ${#unk[@]} )) || continue
        # After the server being retried, when it's there only for want of
        # a dead SOCKS5's row
        _n=7; [[ " ${units[*]} " == *" y "* ]] && (( ! socksUp )) && _n=9 ;;
      u) [[ $_up == u ]] || continue; _n=7 ;;
      r1) (( r1 )) || continue; _k=r _n=10 ;;
      r2) (( r2 && (ali || hlp) )) || continue; _k=r _n=10 ;;
      ws) _n=4; [[ $okAt == ws ]] && _at=okRow ;;
      wh) _n=5 ;;
      wl) _n=6 ;;
      a) (( ali )) || continue ;;
      p) (( hlp )) || continue ;;
    esac
    case $_u in
      ws|wh|wl) auroraMotdNeed "$_k@$iw" auroraMotdWays "${_u:1}" "$iw" ;;
      o|u|r*|a|p) auroraMotdNeed "$_k@$iw" auroraMotdBit "${_k:0:1}" "$iw" ;;
      *) auroraMotdNeed "$_k@$iw" auroraMotdUnit "$_u" "$iw" "${_k:1}" ;;
    esac
    for (( _i = 0; _i < ${cnt[$_k@$iw]}; _i++ )); do
      row=${vR[$_k@$iw/$_i]} rw=${vW[$_k@$iw/$_i]}
      # The message's later rows come before what to run's: they're kept
      # first, as far as they fit (rank 1, a part of their own); what to
      # run's later rows ("to start over") go before the ways in
      if [[ $_u == [mn] ]] && (( _i == 1 )); then
        _g+=1 _n=1
        [[ $_u == n ]] && _n=7
      fi
      # The uptime and the checks' count at the right of their rows
      if [[ $_u == "$_up" ]] && (( _i == upRow )); then
        rowTo $(( iw - 2 - ${#upText} )); rowAdd "$cDim" "↻ "; rowAdd "$cWht" "$upText"
      fi
      if (( _i == _at && ! tck && ! ${#unk[@]} )); then
        rowTo $(( iw - 2 - ${#okc} )); rowAdd "$cGrn" "✓ "; rowAdd "$cDim" "$okc"
      fi
      rows+=("$row") widths+=("$rw") ranks+=("$_n") grp+=("$_g")
    done
  done
  total=$(( ${#rows[@]} + 2 ))
}

# auroraMotdCompact: under 60 columns, or too few rows for the others: one
# panel like the status panel's compact one, 14 rows at most: CAUTION or
# why it's down and what to run, what's wrong, the exit (the uptime at its
# right, or at the right of the first row before it with room, else
# leading the traffic or the checks), the traffic, the checks, the ways in
# between faint rules, the aliases and the help
auroraMotdCompact() {
  local -i cw=$(( motdCols - 1 > 66 ? 66 : motdCols - 1 )) iw k i j m used total trf=1 tck=3 r1=1 r2=1 ali=1 \
    hlp=1 exitFlag=0 retryBeside=0 sw=0 tw upRow=-1 okRow=-1 budget=$(( budget < 14 ? budget : 14 ))
  local -A vR=() vW=() vT=() cnt=()
  local -a units rows widths ranks grp keep kr kw
  local upAt="" okAt="" okc="" u
  iw=$(( cw - 4 ))
  auroraMotdUnits
  # The server being retried under the message: there's no badge row
  [[ ${units[1]} == y ]] && units=(b m y n "${units[@]:4}")

  # The parts the uptime may go on: the exit's last row, then the rows
  # before it
  for u in w x; do
    [[ " ${units[*]} " == *" $u "* ]] && auroraMotdNeed "$u@$iw" auroraMotdUnit "$u" "$iw" ""
  done
  auroraMotdNeed "e5@$iw" auroraMotdUnit e "$iw" 5
  if [[ $view == conn && -n $upText ]]; then
    tw=$(( 2 + ${#upText} )) upAt=u
    for u in e5 w x; do
      auroraMotdTailRow upRow "$u"
      (( upRow >= 0 )) && { upAt=${u:0:1}; break; }
    done
  fi
  # The checks' count (tck 0) at the right of the problems' first row with
  # room, else of SOCKS5's while it's up - never the exit's, it isn't the
  # exit's, nor a dead listener's - else a row of its own; spelled out as
  # far as the room allows
  okAt=o
  for u in x ws; do
    [[ $upAt == "$u" ]] && continue
    [[ $u == ws ]] && (( ! socksUp )) && continue
    if [[ $u == ws ]]; then
      auroraMotdNeed "ws@$iw" auroraMotdWays s "$iw"
    elif [[ " ${units[*]} " != *" x "* ]]; then
      continue
    fi
    for (( i = 0; i < ${cnt[$u@$iw]}; i++ )); do
      auroraMotdOkText okc $(( iw - ${vW[$u@$iw/$i]} - 4 ))
      if [[ -n $okc ]] && (( ${vW[$u@$iw/$i]} + 4 + ${#okc} <= iw )); then
        okAt=$u okRow=i
        break 2
      fi
    done
  done
  [[ $okAt == o ]] && auroraMotdOkText okc $(( iw - 2 ))

  # Given up first: the rules either side of the ways in; the traffic; the
  # checks' rows, down to one, then to a count at the right of a row; the
  # help and the aliases, in the order the state wants. A pane too short
  # even for that keeps parts by rank (auroraMotdCompactRows), each whole or
  # not at all, while they fit - a part that doesn't leaves room for a
  # smaller one - the message's later rows as far as they fit, its end
  # marked; shown in their order. Rows from the bottom only after that.
  if ! auroraMotdFit auroraMotdCompactRows "${lead[@]}" r2=0 r1=0 trf=0 tck=2 tck=1 tck=0 "${last[@]}"; then
    used=0 keep=()
    for (( k = 0; k <= 9; k++ )); do
      for (( i = 0; i < ${#rows[@]}; i = j )); do
        for (( j = i + 1; j < ${#rows[@]} && grp[j] == grp[i]; j++ )); do :; done
        (( ranks[i] == k )) || continue
        if (( ! k || used + j - i <= budget - 2 )); then
          for (( m = i; m < j; m++ )); do keep[m]=1; done
          used+=$(( j - i ))
        elif (( k == 1 )); then
          for (( m = i; m < j && used < budget - 2; m++ )); do keep[m]=1 used+=1; done
          (( widths[m-1] < iw )) && rows[m-1]+=$cWht… widths[m-1]=$(( widths[m-1] + 1 ))
        fi
      done
    done
    kr=() kw=()
    for (( i = 0; i < ${#rows[@]}; i++ )); do
      [[ -n ${keep[i]} ]] && kr+=("${rows[i]}") kw+=("${widths[i]}")
    done
    rows=("${kr[@]}") widths=("${kw[@]}")
    while (( ${#rows[@]} + 2 > budget && ${#rows[@]} > 1 )); do
      unset 'rows[-1]' 'widths[-1]'
    done
  fi

  gr=${#out[@]}; rowStart; rowPad 1; auroraMotdBadgeTop "$cw"; auroraMotdPut
  for (( k = 0; k < ${#rows[@]}; k++ )); do
    gr=${#out[@]}; rowStart; rowPad 1
    auroraMotdSide "$cw" "${rows[k]}" "${widths[k]}"
    auroraMotdPut
  done
  gr=${#out[@]}; rowStart; rowPad 1; auroraMotdBottom "$cw" "$ovpn"; auroraMotdPut
}

# auroraMotdTiny: a pane too small for any panel: the state (CAUTION's
# count with it), what to run when it's down or waiting (that it's
# starting, while it is), else the exit, and the proxy, a line each, as
# many as there are rows for (with one, what to run beside the state)
auroraMotdTiny() {
  local -i w=$(( motdCols > 1 ? motdCols - 1 : 1 )) n=$(( budget > 1 ? budget : 1 )) k
  local -a l=("${badgeShort:1:-1}")
  local t c=$stateFg
  (( warn )) && l[0]+=" ▲ $warn" c=$cAmb
  case $view in
    down)
      if (( starting == 2 )); then l+=("waiting for OTP")
      elif (( starting )); then l+=("starting")
      else l+=("run vpn-restart")
      fi ;;
    sso) l+=("run sso-url") ;;
    *) l+=("${ip:-$ipNoteShown}") ;;
  esac
  (( w < ${#l[1]} )) && l[1]=${l[1]#run }
  # A line only: what to run goes with the state, without its "run" if
  # that's what it takes
  if (( n == 1 )) && [[ $view != conn ]]; then
    (( ${#l[0]} + 2 + ${#l[1]} <= w )) || l[1]=${l[1]#run }
    (( ${#l[0]} + 2 + ${#l[1]} <= w )) && l[0]+="  ${l[1]}"
  fi
  l+=("socks5 :$port")
  for (( k = 0; k < n && k < 3; k++ )); do
    fitText t "${l[k]}" "$w"
    if (( k )); then row=$cWht$t; else row=$cBold$c$t; fi
    auroraMotdPut
  done
}

motdRender() {
  local -i rw=0 gr=0 phase=0 tick=0 lw=9 gridNeed=0 gridTwo=0 budget artW=0 ringN warn=0 blank=0 okN \
    tSa=0 tSb=0 tC=0 tL=0 tU=0 tUs=0 tD=0 tQ=0
  local row grad stateFg stateBg badge badgeShort chipBg pqBg badBg artShadow="" artGlyphs="" warnText="" \
    ipNoteShown=${ipNote:-unknown} hostShown=${host:-${dcn:-<container>}} vc=w pk=P il=d restartWhy="to start over" \
    tPrep=""
  (( ovpnUp )) || restartWhy="to reconnect"
  local -a out=() cRows=() cW=() art=() gradRing dashRing gradWarn tunNote=() bad=() unk=() fw=() sv=() \
    lead=() aliRow=(ali=3 ali=2 ali=1) last=(hlp=0 ali=0) tQs=()
  # Parts built for one layout and kept for the next (auroraMotdNeed; their
  # keys carry their widths), and the state block's arrangements
  local -A pieceColour pieceEnd vR=() vW=() vT=() cnt=() sU=() sL=() sBes=() sBel=() sRule=() tfOf=() tF=() tN=() aOf=() aN=() \
    qB=() qF=() qG=() qN=() qBs=() qFs=() qGl=() qFl=()

  # The state's colours and badge, as the panel has them (tick 0: the
  # badges with the filled dot). A view the panel doesn't know shows as down.
  case $view in
    conn|down|sso) ;;
    *) local view=down ;;
  esac
  auroraState
  auroraMotdHealth
  okN=$(( ${#fw[@]} + ${#sv[@]} ))
  # fmtAgo keeps it to a few cells; anything else is cut once, here, for
  # every place it goes
  local upText=$upText
  fitText upText "$upText" 16
  # CAUTION: connected, but a protection is known to be off (unknown, when
  # not root, doesn't count). Its amber is made here, and only then.
  if [[ $view == conn ]] && (( ${#bad[@]} )); then
    warn=${#bad[@]}
    warnText="$warn checks need attention"
    (( warn == 1 )) && warnText="1 check needs attention"
    # Amber, gold, pale amber: SSO's family, not its look, and no green.
    # Made here, so at a quarter of the steps with each colour four times:
    # the same turn round the border for a quarter of the work.
    auroraGradient gradWarn 8 255 176 64  246 214 100  255 226 150
    local _c
    local -a _g=()
    for _c in "${gradWarn[@]}"; do _g+=("$_c" "$_c" "$_c" "$_c"); done
    gradWarn=("${_g[@]}")
    grad=gradWarn
  fi
  local -n gradRef=$grad
  ringN=${#gradRef[@]}
  gradRing=("${gradRef[@]}" "${gradRef[@]}" "${gradRef[@]}")
  dashRing=("${gradRing[@]/%/─}")
  printf -v chipBg '\e[48;2;62;66;88m'
  printf -v pqBg '\e[48;2;180;132;255m'
  printf -v badBg '\e[48;2;255;96;120m'
  pieceColour=([w]=$cWht [d]=$cDim [f]=$cFnt [v]=$cVio [c]=$cCyn [g]=$cGrn [r]=$cRed [a]=$cAmb
    [S]=$stateBg$cInk$cBold [R]=$badBg$cInk$cBold [C]=$chipBg$cWht [P]=$pqBg$cInk$cBold [Q]=$chipBg$cDim [F]="")
  pieceEnd=([S]=$cOff [R]=$cOff [C]=$cOff [P]=$cOff [Q]=$cOff)

  # "Looking up the public IP..." with an ellipsis: a cell shorter
  [[ $ipNoteShown == *... ]] && ipNoteShown=${ipNoteShown%...}…
  # Away from conn, the tunnel's details are the last connection's: dim
  # (their inline keywords a step fainter still), and said so - with when
  # that connection came up, while there's room, never without the marker.
  # Nothing has come up at all when up.sh never stamped a time: then
  # they're only what the tries so far have logged.
  if [[ $view != conn ]]; then
    # While it's down the help (the logs) outlasts the aliases
    last=(ali=0 hlp=0)
    vc=d pk=Q il=f tunNote=("not connected yet" "not connected")
    [[ -n $upText ]] && tunNote=("last connection · came up $upText ago" "last connection · $upText ago" \
      "last connection")
  fi
  # No aliases: the card would only say how to add some, so it's the first
  # thing given up (lead: after the spacing), the help the last, and there
  # are no rows of them to give up a row at a time (aliRow): each knob's
  # steps only ever take more away
  if (( ! ${#aliases[@]} )); then
    lead=(ali=0) aliRow=() last=(hlp=0)
  fi

  # The prompt comes straight after: keep a row for it (more when it wraps)
  # and one spare, so the top stays on screen. A tall pane still gets 30
  # rows at most.
  budget=$(( motdRows - 2 - (26 + ${#dcn}) / (motdCols > 0 ? motdCols : 1) ))
  (( budget > 30 )) && budget=30
  if (( motdCols >= 100 )) && auroraMotdWide; then
    :
  elif (( motdCols >= 60 )) && auroraMotdMedium; then
    :
  elif (( motdCols >= 24 && budget >= 5 )); then
    auroraMotdCompact
  else
    auroraMotdTiny
  fi
  # A blank row before the prompt when there's room for it (the compact
  # panel's own border is enough)
  (( blank && ${#out[@]} < budget )) && out+=("$cOff")
  (( ${#out[@]} )) && printf '%s\n' "${out[@]}"
  return 0
}

motdMain() {
  # Only for a terminal: a pipe or a file gets nothing
  [[ -t 1 ]] || return 0
  # Anything bash itself has to say goes to a log, not across the screen
  # (and nowhere at all if the log can't be opened)
  exec 2>/dev/null
  exec 2>>/var/log/jumpbox-motd.log
  source /config/inc.sh

  local -i termRows=24 termCols=80
  termSize
  motdRows=$termRows motdCols=$termCols
  auroraInit
  motdCollect
  # At the top of a clean screen. Not clear(1): that wipes the scrollback too.
  printf '\e[H\e[2J'
  motdRender
}

motdMain
