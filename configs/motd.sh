#!/bin/sh

# Print the motd when accessing the container via ssh.

purple='\033[35m'
green='\033[92m'

clear
echo -n -e " ${purple}> ${green}>"
printf "\n${purple}$(tput bold; cat /config/motd_head; tput sgr0)${green}\n"
echo -n -e " ${purple}|${EMOJI} ➡ Welcome to the project Jumpbox terminal!${green}\n"
echo -n -e " ${purple}    ➡ You are in: $CTN\n     ➡ Your IP address is: ($IP)${green}\n"
echo -n -e " ${purple}    ➡ Connect a web proxy using: socks5 @127.0.0.1 port:${PORT}${green}\n"

# Fetch aliases from ~/.profile
aliasList=$(grep alias ~/.profile | awk -F= '{print $1}' | awk '{print $2}')

if [[ ! -z "$aliasList" ]]; then
  echo -n -e "${purple}     ➡ Active aliases:${green}\n"
  echo
  echo "$aliasList" | tr '\n' ' ' | xargs -n 8 | while read -r line; do
    echo "         $line"
  done
  echo
else
  echo -n -e "${purple}     ➡ Active aliases: [ No aliases, add them with CUSTOMCONF setting ]\n\n${green}"
fi

echo "  ➡ To debug VPN connectivity issues use /var/log/openvpn.log
  ➡ To debug socks5 issues use /var/log/sockd.log
  ➡ To install additional packages in the current environment use 'apk add'
"
