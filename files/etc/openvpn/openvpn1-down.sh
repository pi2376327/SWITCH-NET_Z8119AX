#!/bin/sh
DATE=`date +%Y-%m-%d-%H:%M:%S`

iptables -t mangle -D PREROUTING -s 192.168.151.0/24 -m set ! --match-set chnroute dst -j MARK --set-mark 10
ip route del default table 101
ip rule del from all fwmark 10 table 101 pref 32000

echo "$DATE: Openvpn-client disconnected" >>/root/script/ovpn-script.log
echo "----------------------------------------------------------------" >>/root/script/ovpn-script.log
