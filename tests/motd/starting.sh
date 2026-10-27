# A docker restart, start.sh not yet as far as starting OpenVPN: the last
# run's details still in the log
view=conn ovpnUp=1 stopWhy="" ssoUrl=""
upSecs=13963 upText="3h 52m" ageSecs=142380 ageText="1d 15h"
ip="203.0.113.42" ipNote="" cc=SG ctn="Singapore" flag=$'\U0001F1F8\U0001F1EC'
dcn="jumpbox-sg" host="4c7e19a2f05d" port=10079 sshPort=12079 ovpn="sg-singapore.ovpn" auth=password
server="203.0.113.10:1194" proto=UDP cipher="AES-256-GCM" tlsVer="TLSv1.3" kex="X25519MLKEM768" pq=1
tunIp="10.8.0.6/24" gw="10.8.0.1" tunnelMode=full routeCount=0
dns=("10.8.0.1" "1.1.1.1") dnsSearch=""
rxBytes=1288490188 txBytes=88394547 rxText="1.1 GiB" txText="84.3 MiB"
killSwitch=on v6Blocked=1 socksUp=1 sshUp=1 watcherUp=1
vpnVer="OpenVPN 2.7.7" osVer="3.24.2"
aliases=(bastion prod-db nagios build1 build2 pve1 pve2 ipmi-gw)
mounts=("/vpn ro")
# The case, over that connected container:
view=down ovpnUp=0 starting=1 logWhole=1 rxBytes="" txBytes="" rxText="" txText="" tunIp="" gw="" tunnelMode="" socksUp=0 sshUp=0 watcherUp=0
