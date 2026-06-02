#!/bin/sh
DATE=`date +%Y-%m-%d-%H:%M:%S`

#check and add rules of mangle     
iptables -t mangle -C PREROUTING -s 192.168.151.0/24 -m set ! --match-set chnroute dst -j MARK --set-mark 10
if [ $? = 1 ]; then
        iptables -t mangle -I PREROUTING -s 192.168.151.0/24 -m set ! --match-set chnroute dst -j MARK --set-mark 10
fi

ip rule add from all fwmark 10 table 101 pref 32000
ip route add default via 172.19.0.1 dev tun1 src 172.19.1.4 table 101

echo "$DATE: Openvpn1-client startup" >>/root/script/ovpn-script.log
echo "----------------------------------------------------------------" >>/root/script/ovpn-script.log
