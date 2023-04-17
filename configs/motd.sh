#!/bin/sh

# Print the motd when accessing the container via ssh.

PURPLE='\033[35m'
GREEN='\033[92m'

clear
echo -n -e " ${PURPLE}> ${GREEN}>"
printf "\n${PURPLE}$(tput bold; cat /config/motd_head; tput sgr0)${GREEN}\n"
echo -n -e " ${PURPLE}|${EMOJI}  ➡ Welcome to the project Jumpbox terminal!${GREEN}\n"
echo -n -e " ${PURPLE}    ➡ You are in: $CTN\n     ➡ Your IP address is: ($IP)${GREEN}\n"
echo -n -e " ${PURPLE}    ➡ Connect a web proxy using: socks5 @127.0.0.1 port:${PORT}${GREEN}\n"

ALIAS=$(grep alias ~/.profile | awk '{print $2}' | cut -d= -f1 | tr '\n' ' ')
if [[ ! -z "$ALIAS"  ]]; then
    echo -n -e "${PURPLE}     ➡ Active aliases: [ $ALIAS ]\n\n${GREEN}"
else
    echo -n -e "${PURPLE}     ➡ Active aliases: [ No aliases, add them with CUSTOMCONF setting ]\n\n${GREEN}"
fi

echo "  ➡ To debug VPN connectivity issues use /var/log/openvpn.log
  ➡ To debug socks5 issues use /var/log/sockd.log
  ➡ To install additional packages in the current environment use 'apk add'
"
neofetch --ascii_distro LinuxLite
