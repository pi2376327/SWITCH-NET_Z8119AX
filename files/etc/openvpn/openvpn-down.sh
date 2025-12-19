#!/bin/sh
DATE=`date +%Y-%m-%d-%H:%M:%S`

iptables -t mangle -D PREROUTING -m set ! --match-set chnroute dst -j MARK --set-mark 1
iptables -t mangle -D OUTPUT -m set ! --match-set chnroute dst -j MARK --set-mark 1
ip route del default table 100
ip rule del from all fwmark 1 table 100

echo "----------------------------------------------------------------" >>/root/script/ovpn-script.log
echo "$DATE: Openvpn-client disconnected" >>/root/script/ovpn-script.log
