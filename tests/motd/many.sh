# Everything at its worst: long names, the longest country name the panel
# keeps, twenty aliases, a split tunnel, an IPv6 server, three DNS servers
# and three search domains, ssh not listening, the watcher dead, the kill
# switch unreadable
view=conn ovpnUp=1 stopWhy="" ssoUrl=""
upSecs=1209700 upText="14d 0h" ageSecs=1209800 ageText="14d 0h"
ip="192.0.2.10" ipNote="" cc=BA ctn="Bosnia and Herzegovina" flag=$'\U0001F1E7\U0001F1E6'
dcn="jumpbox-with-a-really-long-name" host="jumpbox-with-a-really-long-hos" port=10079 sshPort=12079
ovpn="a-very-long-openvpn-profile-name-for-a-gateway-in-somewhere-far-away.ovpn" auth=otp
server="[2001:db8:85a3::8a2e:370:7334]:1194" proto=TCP cipher="AES-128-CBC" tlsVer="TLSv1.2" kex="" pq=0
tunIp="192.168.255.6/30" gw="" tunnelMode=split routeCount=14
dns=("10.20.0.53" "10.20.1.53" "10.30.0.53") dnsSearch="corp.example eu.corp.example lab.corp.example"
rxBytes=1125899906842624 txBytes=999999999999 rxText="1.0 PiB" txText="931.3 GiB"
killSwitch="" v6Blocked="" socksUp=1 sshUp=0 watcherUp=0
vpnVer="OpenVPN 2.7.7" osVer="3.24.2"
aliases=(ssh-prod-database-primary ssh-prod-database-replica bastion-eu bastion-us nagios grafana kibana jenkins
         build1 build2 build3 pve1 pve2 pve3 pve4 ipmi-rack1 ipmi-rack2 switch-core fw-edge vpn-test)
mounts=("/vpn ro" "/root/files rw" "/root/projects/a-rather-long-mount-point-name rw")
