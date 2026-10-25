#!/bin/bash

# Print the pending SSO sign-in URL, if there is one.
# With -f keep running and print each new URL as it turns up - the host
# launcher pipes this into macOS `open` so the sign-in page pops up by itself.

source /config/inc.sh 2>/dev/null

if [[ "$1" != "-f" ]]; then
  url=$(ssoPending)
  if [[ -z "$url" ]]; then
    echo "No SSO sign-in is pending" >&2
    exit 1
  fi
  echo "$url"
  exit 0
fi

last=""
while sleep 1; do
  url=$(ssoPending)
  if [[ -n "$url" && "$url" != "$last" ]]; then
    echo "$url"
    last=$url
  fi
done
