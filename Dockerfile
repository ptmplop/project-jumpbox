FROM alpine:latest

RUN apk update
RUN apk upgrade

RUN apk add tzdata bash jq openvpn ip6tables dante-server openssh nano make git ncurses shadow \
curl nodejs unbound ca-certificates openssl nmap mtr speedtest-cli tcpdump bind-tools tini \
busybox-extras shadow-login wget net-tools iproute2 traceroute socat htop iotop iftop ncdu \
rsync less zip unzip tar inetutils-telnet netcat-openbsd iperf3 sshpass screen alpine-sdk \
bash-completion openssh ipmitool fzf

# The prompt's colours inside \[ \], so the shell doesn't count them as
# characters (long command lines wrapped in the wrong place)
RUN echo 'export PS1="\[\e[0;34m\] [Project Jumpbox] | $DCN\[\e[0m\] \w # "' > ~/.profile
# The welcome screen, for interactive shells only, and not one given a
# command: the output of docker exec <container> bash -lc '...' (or -lic,
# for an alias) stays the command's own
RUN echo 'case $- in *c*) ;; *i*) sh /config/motd.sh ;; esac' >> ~/.profile

RUN mkdir /config

COPY configs/start.sh /
COPY configs/inc.sh /config/
COPY configs/sockd.conf /etc/
COPY configs/sockd.sh /config/
COPY configs/up.sh /config/
COPY configs/motd.sh /config/
COPY configs/sshd_config /etc/ssh/sshd_config

RUN chmod 755 /start.sh
RUN chmod 755 /config/inc.sh
RUN chmod 755 /config/sockd.sh
RUN chmod 755 /config/up.sh
RUN chmod 755 /config/motd.sh
COPY configs/vpn-restart.sh /usr/local/bin/vpn-restart
RUN chmod 755 /usr/local/bin/vpn-restart
COPY configs/sso-url.sh /usr/local/bin/sso-url
RUN chmod 755 /usr/local/bin/sso-url
RUN touch /var/log/dante.log
RUN touch /tmp/last

# An OpenSSL config that allows legacy TLS renegotiation, for talking to old
# servers from a shell inside the container: OPENSSL_CONF=/config/openssl.cnf
COPY configs/openssl.cnf /config/openssl.cnf
RUN chmod 644 /config/openssl.cnf

# Add VPN user
RUN adduser --disabled-password --gecos "" --shell /usr/sbin/nologin vpn

# Add SSH user
RUN adduser -D jumpbox
RUN echo "jumpbox:jumpbox" | chpasswd

ENTRYPOINT ["/sbin/tini", "--"]
CMD [ "/start.sh" ]

