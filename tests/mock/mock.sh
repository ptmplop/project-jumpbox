#!/bin/bash
# Mock environment for the Aurora display - no VPN. Runs the real display()
# from /config/inc.sh against:
#   - a fake `openvpn` process (a script of that name, so pgrep -x finds it;
#     `openvpn --version` is passed to the real binary)
#   - tun0 as one end of a veth pair, so both byte counters move: tx from a
#     ping to a static neighbour, rx from raw frames written into the peer
#   - the openvpn log lines and /tmp/last that connCheck (CONNCHECK=tunnel),
#     ssoPending and the display read; /t/state.sh changes them
#   - curl stubbed for the IP and geo lookups (MOCK_IP / MOCK_GEO_FILE,
#     "fail" for either to make that lookup fail)
#   - a 0.0.0.0/1 route via the docker gateway, with netem latency
#     (MOCK_DELAY, default 100ms 10ms; "none" for no route)
# Traffic: MOCK_TRAFFIC=on (default) / off.
export DCN=${DCN:-jbx-mock} PORT=${PORT:-10079} OVPNFILE=${OVPNFILE:-example-gateway-sso.ovpn}
export CONNCHECK=${CONNCHECK:-tunnel}

mkdir -p /tmp/fakebin
cat > /tmp/fakebin/openvpn <<'X'
#!/bin/bash
[[ $1 == --version ]] && exec /usr/sbin/openvpn --version
while :; do sleep 3600; done
X
cat > /tmp/fakebin/curl <<'X'
#!/bin/bash
[[ -n ${MOCK_CURL_DELAY:-} ]] && sleep "$MOCK_CURL_DELAY"
for a in "$@"; do
  case $a in
    *ifconfig.me*|*ipinfo.io*)
      [[ ${MOCK_IP:-} == fail ]] && exit 7
      printf '%s' "${MOCK_IP:-198.51.100.147}"; exit 0 ;;
    *ip2location*)
      [[ ${MOCK_GEO_FILE:-} == fail ]] && exit 7
      cat "${MOCK_GEO_FILE:-/t/mock/geo-in.json}"; exit 0 ;;
  esac
done
exec /usr/bin/curl "$@"
X
chmod +x /tmp/fakebin/openvpn /tmp/fakebin/curl
export PATH=/tmp/fakebin:$PATH

openvpn &>/dev/null &
disown

ip link add tun0 type veth peer name tunpeer
ip link set tun0 up; ip link set tunpeer up
ip addr add 10.99.0.2/24 dev tun0
ip neigh add 10.99.0.1 lladdr 02:00:00:00:00:01 dev tun0
if [[ ${MOCK_DELAY:-} != none ]]; then
  gw=$(ip route | awk '/default/{print $3}')
  ip route add 0.0.0.0/1 via "$gw" dev eth0
  # shellcheck disable=SC2086
  tc qdisc add dev eth0 root netem delay ${MOCK_DELAY:-50ms 5ms} 2>/dev/null
fi
if [[ ${MOCK_TRAFFIC:-on} == on ]]; then
  ( while :; do ping -q -c 5 -i 0.2 -s $(( RANDOM % 1400 + 64 )) 10.99.0.1; done ) &>/dev/null &
  disown
  ( while :; do
      n=$(( RANDOM % 9 == 0 ? 40 : 2 ))
      for (( i = 0; i < n; i++ )); do head -c 1400 /dev/urandom; done | socat -u -b 1400 - INTERFACE:tunpeer
      sleep 0.3
    done ) &>/dev/null &
  disown
fi

echo "$(date) Initialization Sequence Completed" > /var/log/openvpn.log
echo $(( $(date +%s) - ${MOCK_UPTIME:-13963} )) > /tmp/last

source /config/inc.sh
sfile=/.conn_check
echo 0 > $sfile
trap ctrlC INT TERM QUIT
display
