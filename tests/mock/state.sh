#!/bin/bash
# Drive the mock's state: state.sh conn|down|sso|reconnect
log=/var/log/openvpn.log
case $1 in
  conn)      echo "$(date) Initialization Sequence Completed" >> $log ;;
  reconnect) date +%s > /tmp/last; echo "$(date) Initialization Sequence Completed" >> $log ;;
  down)      echo "$(date) SIGUSR1[soft,ping-restart] received, process restarting" >> $log ;;
  sso)       echo "$(date) SIGUSR1[soft,ping-restart] received, process restarting" >> $log
             echo "$(date) Info command was pushed by server ('WEB_AUTH::https://sso.example.test/login?sess=42')" >> $log ;;
  *) echo "usage: $0 conn|down|sso|reconnect" >&2; exit 2 ;;
esac
