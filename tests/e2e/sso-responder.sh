#!/bin/bash
# Answers the test server's management client-auth requests. While
# /tmp/sso-on exists a connecting client is held with a pending web-auth URL
# (client-pending-auth) until /tmp/sso-approve appears; otherwise it's let
# straight in. Lines seen go to /tmp/mgmt.log.
for i in {1..50}; do exec 3<>/dev/tcp/127.0.0.1/7505 2>/dev/null && break; sleep 0.2; done
# Approver: watches for /tmp/sso-approve and lets the held client in
( while sleep 0.3; do
    if [[ -f /tmp/sso-approve && -s /tmp/sso-pending ]]; then
      printf 'client-auth-nt %s\r\n' "$(cat /tmp/sso-pending)" >&3
      echo "approved $(cat /tmp/sso-pending)" >> /tmp/mgmt.log
      : > /tmp/sso-pending; rm -f /tmp/sso-approve
    fi
  done ) &
cur=""
while IFS= read -r line <&3; do
  line=${line%$'\r'}
  echo "$line" >> /tmp/mgmt.log
  case $line in
    '>CLIENT:CONNECT,'*|'>CLIENT:REAUTH,'*)
      IFS=, read -r _ cid kid _ <<<"${line#>CLIENT:}"
      cur="$cid $kid" ;;
    '>CLIENT:ENV,END')
      # only the env block of a CONNECT/REAUTH is answered; other events
      # (DISCONNECT, ESTABLISHED) end theirs the same way
      [[ -n $cur ]] || continue
      if [[ -f /tmp/sso-on ]]; then
        win=$(cat /tmp/sso-timeout 2>/dev/null || echo 300)
        printf 'client-pending-auth %s WEB_AUTH::https://sso.example.test/login?sess=%s %s\r\n' "$cur" "${cur%% *}" "$win" >&3
        echo "$cur" > /tmp/sso-pending
        echo "pending $cur" >> /tmp/mgmt.log
      else
        printf 'client-auth-nt %s\r\n' "$cur" >&3
        echo "auth $cur" >> /tmp/mgmt.log
      fi
      cur="" ;;
    '>CLIENT:ENV,'*) ;;
    '>CLIENT:'*) cur="" ;;
  esac
done
