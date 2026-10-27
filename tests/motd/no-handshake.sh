# A first connect that never gets past the TLS handshake (a blocked port):
# the server is logged, nothing else, while OpenVPN keeps retrying
view=down ovpnUp=1 stopWhy="" ssoUrl=""
upSecs="" upText="" ageSecs=95 ageText="1m 35s"
ip="" ipNote="Looking up the public IP..." cc="" ctn="" flag=""
dcn="jumpbox-jp" host="a91f03d7c2e5" port=10082 sshPort=12082 ovpn="jp-tokyo.ovpn" auth=certificate
server="192.0.2.20:443" proto=TCP cipher="" tlsVer="" kex="" pq=0
tunIp="" gw="" tunnelMode="" routeCount=0
dns=("192.168.65.7") dnsSearch=""
rxBytes="" txBytes="" rxText="" txText=""
killSwitch=on v6Blocked=1 socksUp=1 sshUp=1 watcherUp=1
vpnVer="OpenVPN 2.7.7" osVer="3.24.2"
aliases=(bastion web-1)
mounts=("/vpn ro")
