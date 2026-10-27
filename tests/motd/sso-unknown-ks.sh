# A sign-in waiting on the browser (SSO), the kill switch unreadable
view=sso ovpnUp=1 stopWhy="" ssoUrl="https://sso.example.test/login?sess=42"
upSecs=20112 upText="5h 35m" ageSecs=20160 ageText="5h 36m"
ip="198.51.100.58" ipNote="" cc=DE ctn="Germany" flag=$'\U0001F1E9\U0001F1EA'
dcn="work-gateway" host="7d20c6ae91b4" port=10081 sshPort=12081 ovpn="work-gateway-sso.ovpn" auth=sso
server="198.51.100.7:1194" proto=UDP cipher="AES-256-GCM" tlsVer="TLSv1.3" kex="X25519" pq=0
tunIp="10.240.232.14/22" gw="10.240.232.1" tunnelMode=full routeCount=1
dns=("10.240.236.1") dnsSearch="corp.example"
rxBytes=48325529 txBytes=5320394 rxText="46.0 MiB" txText="5.0 MiB"
killSwitch="" v6Blocked=1 socksUp=1 sshUp=1 watcherUp=1
vpnVer="OpenVPN 2.7.7" osVer="3.24.2"
aliases=(gitlab wiki monitor)
mounts=("/vpn ro")
