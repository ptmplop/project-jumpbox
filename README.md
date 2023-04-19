
# Project Jumpbox

A local docker container that connects to an openvpn server and exposes socks5 on the backend, this can be configured with a brower plugin like FoxyProxy or SwitchyOmega to easily push traffic from browers over a specific VPN connection.
 
You can install additional tools in the shell to use it as a functional jumpbox for accessing and managing remote servers via ssh.





## Installation

You will need an API key from https://ipgeolocation.io - This is required to start the container and fetch the location details for the UI. Signup for free and generate your API key.

The .ovpn config file, authfile and customconfig file are mounted inside the container, in this example we will use ~/Private/openvpn_configs/ but you can change if required. Use an authfile if your openvpn requires username and password authentication, the customconfig is optional, see environment variable for more details.

Build the container and run using the instructions below. 

```bash
  cd project-jumpbox
  docker build -t project-jumpbox .

  # - Jumpbox Proxy
  docker run -it --init --rm --name jumpbox-proxy \
   --cap-add NET_ADMIN -p 10097:1080 \
    -e CUSTOMCONF=jumpbox-custom \
    -e AUTHFILE=jumpbox-auth \
    -e DCN=jumpbox-proxy \
    -e OVPNFILE=jumpbox.officeconnect.udp1194.ovpn \
    -e PORT=10097 \
    -e TZ=Europe/London \
    -e GEOAPIKEY={YOUR API KEY HERE} \
     -v ~/Private/openvpn_configs/:/vpn:ro jumpbox
```



## Environment Variables

To run this project, you will need to add the following environment variables to your .env file

`CUSTOMCONF`

Path to the customconfig for executing bash code on container startup, for example,

```
#Maintain consistent SSH keys
cp /vpn/id_rsa.pub ~/.ssh/id_rsa.pub
cp /vpn/id_rsa ~/.ssh/id_rsa
chmod 600 ~/.ssh/id_rsa
chmod 600 ~/.ssh/id_rsa.pub

#Create Aliases
echo "alias webserver='ssh -o StrictHostKeyChecking=no root@xxxx'" >> ~/.profile
echo "alias database='ssh -o StrictHostKeyChecking=no root@xxxx -p2788'" >> ~/.profile
```

This variable is optional

`AUTHFILE`

If your openvpn connection requires a username and password you must specify them in the authfile, put the username on the first line and password on the second.

The authfile should be in the mounted directory
For example: ~/Private/openvpn_configs/jumpbox-auth

This variable is optional, if no auth is required it can be skipped.

`DCN`

A friendly hostname for the jumpbox shell

`OVPNFILE`

Name of the .ovpn file in ~/Private/openvpn_configs/

`PORT`

The port for socks5 connectivity, should match the port specified when starting the container (-p {PORT}:{PORT}). You can use default 1080:1080 if you only plan to run a single jumpbox.

`TZ`

Timezone for the container example Asia/Bangkok

`GEOAPIKEY`

API key is required to fetching location details and flag for UI
You can get an API key for free by registering at https://ipgeolocation.io
