#!/bin/bash

JB="docker exec -it $(cat /etc/hostname) sh -l"

function ctrl_c() {
    clear
    echo -n -e "|$FLAG  ➡ ${BOLD}${PURPLE}Project Jumpbox${NORMAL} ➡ Exit\n\n"
    tput cvvis
    exit 0
}

custom() {
    if [[ -n "$CUSTOMCONF" ]]; then
        echo -n -e " ➡ A custom config file will be applied ($CUSTOMCONF)\n"
        cat /vpn/$CUSTOMCONF | sh
    fi
}

tun_device() {
    mkdir -p /dev/net
    [[ -c /dev/net/tun ]] || mknod -m 0666 /dev/net/tun c 10 200
}

conn_check() {
    SFILE="/.conn_check"
    echo "1" > $SFILE
    while true; do
        if ! ping -q -c 1 -W 1 8.8.8.8 &>/dev/null && \
           ! ping -q -c 1 -W 1 1.1.1.1 &>/dev/null; then
            echo "1" > $SFILE
        else
            echo "0" > $SFILE
        fi
    sleep 5
    done &
}

lines() {
    echo -n -e "+"
    for i in $(seq 62); do
        echo -n -e "-"
    done
    echo -n -e "+"
    echo
}

killswitch() {
    DOCKERNET=$(ip -o addr show dev eth0 | awk '$3 == "inet" {print $4}')
    iptables -F
    iptables -X
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT DROP

    ip6tables -P INPUT DROP
    ip6tables -P FORWARD DROP
    ip6tables -P OUTPUT DROP

    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -s $DOCKERNET -j ACCEPT

    iptables -A OUTPUT -o tun0 -j ACCEPT
    iptables -A OUTPUT -m owner --gid-owner vpn -j ACCEPT
    iptables -A OUTPUT -d $DOCKERNET -j ACCEPT
}

connect_ovpn() {
    if [[ -n "$AUTHFILE" ]]; then
        echo -n -e " ➡ Using specified authfile ($AUTHFILE)\n"
        sg vpn -c "openvpn --auth-nocache --daemon openvpn-client \
          --persist-tun --persist-key --log /var/log/openvpn.log \
           --setenv PATH '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
            --connect-retry 2 0 --script-security 2 --up /config/up.sh --up-restart \
             --down /etc/openvpn/update-resolv-conf.sh --down-pre --auth-retry nointeract \
              --config /vpn/$OVPNFILE --auth-user-pass /vpn/$AUTHFILE"
    else
	    echo -n -e " ➡ No authfile was specified...\n"
        sg vpn -c "openvpn --auth-nocache --daemon openvpn-client \
          --persist-tun --persist-key --log /var/log/openvpn.log \
           --setenv PATH '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
            --connect-retry 2 0 --script-security 2 --up /config/up.sh --up-restart \
             --down /etc/openvpn/update-resolv-conf.sh --down-pre --auth-retry nointeract \
              --config /vpn/$OVPNFILE"
    fi
}

wait_conn() {
    COUNT=40
    echo -n -e " ➡ Waiting for connection"
    while [[ $(cat $SFILE) -eq "1" && $COUNT -ge "0" ]]; do
        echo -n -e "."
        COUNT=$((COUNT-1))
        sleep 1

        # Fail and give some useful output
        if [[ $COUNT -eq "0" ]]; then
	        clear; cat /var/log/openvpn.log
            exit 1
        fi
    done
}

display() {
    # Keep alive & display outputs
    IP=$(curl -s ifconfig.me || curl -s https://ipinfo.io/ip)
    GEOURL="https://api.ipgeolocation.io/ipgeo?apiKey=${GEOAPIKEY}&ip=$IP"

    # Unreliable sometimes - Out of our control so we will run twice to cover things
    readarray -t CCARRAY < <(curl -s -k "$GEOURL" | jq '.country_name','.country_code2')

    if [[ -z "${CCARRAY[0]}" && -z "${CCARRAY[1]}" ]]; then
    	readarray -t CCARRAY < <(curl -s -k "$GEOURL" | jq '.country_name','.country_code2')
    fi

    CTN=$(echo "${CCARRAY[0]}" | sed 's/"//g')
    CC=$(echo ${CCARRAY[1]} | sed 's/"//g')

    FLAG=$(node /config/flag.js $CC)
    if [[ -z "$FLAG" ]]; then
    	FLAG="x"
    fi

    # We want these for motd
    echo "export IP=\"$IP\"" >> /etc/profile
    echo "export CC=\"$CC\"" >> /etc/profile
    echo "export CTN=\"$CTN\"" >> /etc/profile
    echo "export EMOJI=\"$FLAG\"" >> /etc/profile

    tput civis
    clear

    echo -n -e "|$FLAG ${GREEN} ➡ ${BOLD}${PURPLE}Project Jumpbox... ${NORMAL}${GREEN}"
    echo -n -e "Simple VPN access with a socks backend!${NORMAL}${GREEN}\n"
    echo -n -e "➡ OpenVPN ➡ Config File: ${PURPLE}$OVPNFILE${GREEN}\n"

    echo -n -e ${GREEN}
    lines
    if [[ $IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ -n $CTN ]]; then
        printf "|%-64s|\n" " Public IP Address ➡ $CTN ($IP)"
    else
	    printf "|%-64s|\n" " Public IP Address ➡ Unable to determine from API call"
    fi

    printf "|%-64s|\n" " Web Proxy ➡ socks5 @127.0.0.1 port:$PORT"
    printf "|%-64s|\n" " Jumpbox Shell ➡ $JB"
    lines

    echo -n -e "➡ Loading...\n➡ Loading..."
    sleep 1

    DCON="➡ Outbound Status ➡ [ ${RED}Disconnected${GREEN} ]"
    CONN="➡ Outbound Status ➡ [ ${PURPLE}Connected${GREEN} ]"

    while true; do
        if [[ $(cat $SFILE) -eq "1" ]]; then
            tput cub 1000; tput el
	        tput cuu1
            tput cub 1000; tput el
            echo -n -e "$DCON\n"
            echo -n -e "➡ Transfer Stats ➡ Waiting for outbound connectivity!"

            sleep 0.2
            COUNT=1
            while [[ "$COUNT" -le "5" ]]; do
                echo -n -e " ${PURPLE}➡${GREEN}"
                sleep 0.1
                COUNT=$(($COUNT+1))
            done
            sleep 1
        else

            XFER=$(ifconfig tun0 2>/dev/null | \
	   	    grep RX | grep bytes | \
		     awk '{print "[ ⬇ " $3 $4 " | ⬆ " $7 $8 " ]"}')

	        tput cub 1000; tput el
	        tput cuu1
	        tput cub 1000; tput el

            echo -n -e "$CONN ➡ Last Reconnect: $(date -u -d @$(($(date +%s)-$(cat /tmp/last))) +%Hh:%Mm:%Ss)\n"

	        if [[ -n $XFER ]]; then
   	            echo -n -e "➡ Transfer Stats ➡ $XFER "
	        else
	            echo -n -e "➡ Transfer Stats ➡ Interface is down "
	        fi

            sleep 0.2
            COUNT=1
            while [[ "$COUNT" -le "3" ]]; do
                echo -n -e " ${PURPLE}➡${GREEN}"
                sleep 0.3
                COUNT=$(($COUNT+1))
            done
	        sleep 1
	    fi
    done
}
