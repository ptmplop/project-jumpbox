#!/bin/bash
# --up for the test server: Docker Desktop hands this container packets from
# the internet with TCP/UDP checksums never filled in (veth offload), and
# forwarded into the tunnel as they are the client drops them. Recompute.
tc qdisc add dev "$1" root handle 1: prio
tc filter add dev "$1" parent 1: protocol ip prio 1 u32 match ip protocol 6 0xff action csum ip and tcp
tc filter add dev "$1" parent 1: protocol ip prio 2 u32 match ip protocol 17 0xff action csum ip and udp
exit 0
