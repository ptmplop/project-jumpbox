FROM alpine:latest

# Initial update
RUN apk update
RUN apk upgrade

# Add any additional packages here that are required for the jumpbox environment
RUN apk add tzdata bash jq openvpn ip6tables \
 dante-server openssh nano make git ncurses shadow \
 curl nodejs unbound ca-certificates openssl shadow-login \
 neofetch nmap mtr speedtest-cli tcpdump bind-tools

# A sensible hostname for the shell
RUN echo 'export PS1="\e[0;34m [Project Jumpbox] | $DCN\e[0m \w # "' > ~/.profile

# Add the motd
RUN echo 'sh /config/motd.sh' >> ~/.profile

# Copy in configs
RUN mkdir /config
COPY configs/start.sh /
COPY configs/inc.sh /config/
COPY configs/flag.js /config/
COPY configs/sockd.conf /etc/
COPY configs/up.sh /config/
COPY configs/restart.sh /config/
COPY configs/motd.sh /config/
COPY configs/motd_head /config/motd_head

# Set file permissions
RUN chmod 777 /start.sh
RUN chmod 777 /config/inc.sh
RUN chmod 777 /config/flag.js
RUN chmod 777 /config/up.sh
RUN chmod 777 /config/restart.sh
RUN chmod 777 /config/motd.sh

RUN touch /tmp/last

# Resolver packages 
ADD https://raw.githubusercontent.com/alfredopalhares/openvpn-update-resolv-conf/master/update-resolv-conf.sh /etc/openvpn/update-resolv-conf.sh
RUN chmod 777 /etc/openvpn/update-resolv-conf.sh
RUN cd ~/; git clone https://github.com/NetworkConfiguration/openresolv.git
RUN cd ~/openresolv; ./configure; make; make install

# Add user
RUN adduser --disabled-password --gecos "" --shell /usr/sbin/nologin vpn

ENTRYPOINT [ "/start.sh" ]
