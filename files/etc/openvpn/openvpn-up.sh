#!/bin/sh

DATE=`date +%Y-%m-%d-%H:%M:%S`

#add route-policy
src=$(ip addr show tun0 | grep 'inet ' | sed 's/^.*inet //g' | sed 's/\/16.*$//g')
gw=$(ip addr show tun0 | grep 'inet ' | cut -d' ' -f6 | cut -d'.' -f1-2).0.1
ip route add default via $gw dev tun0 src $src table 100 
ip rule add from all fwmark 1 table 100
#ip route add 8.8.8.8 via $gw dev tun0 src $src

#check and add rules of mangle     
iptables -t mangle -C PREROUTING -m set ! --match-set chnroute dst -j MARK --set-mark 1
if [ $? = 0 ]; then
        echo "$DATE: The PREROUTING of mangle rules already exist"  >>/root/script/ovpn-script.log
        iptables -t mangle -C OUTPUT -m set ! --match-set chnroute dst -j MARK --set-mark 1
        if [ $? = 0 ]; then
                echo "$DATE: The OUTPUT of mangle rules already exist" >>/root/script/ovpn-script.log
        else
                iptables -t mangle -I OUTPUT -m set ! --match-set chnroute dst -j MARK --set-mark 1
                echo "$DATE: Add OUTPUT of mangle rules" >>/root/script/ovpn-script.log
        fi
else
        iptables -t mangle -I PREROUTING -m set ! --match-set chnroute dst -j MARK --set-mark 1
        echo "$DATE: Add PREROUTING of mangle rules" >>/root/script/ovpn-script.log

        iptables -t mangle -C OUTPUT -m set ! --match-set chnroute dst -j MARK --set-mark 1
        if [ $? = 0 ]; then
                echo "$DATE: The OUTPUT rules of mangle already exist" >>/root/script/ovpn-script.log
        else
                iptables -t mangle -I OUTPUT -m set ! --match-set chnroute dst -j MARK --set-mark 1
                echo "$DATE: Add OUTPUT of mangle rules" >>/root/script/ovpn-script.log
        fi
fi

#Add WAN's ip to the chnroute list if it is a public ip address
iwan=$(ip route show 1/0 | cut -d' ' -f5)
ips=$(ip addr show $iwan | grep 'inet ' | cut -d' ' -f6 | cut -d'/' -f1)

is_private_ip() {
        ip="$1"
        IFS='.' read -r i1 i2 i3 i4 <<EOF
$ip
EOF
        if [ "$i1" -eq 10 ]; then
                return 0
        elif [ "$i1" -eq 192 ] && [ "$i2" -eq 168 ]; then
                return 0
        elif [ "$i1" -eq 172 ] && [ "$i2" -ge 16 ] && [ "$i2" -le 31 ]; then
                return 0
        elif [ "$i1" -eq 100 ] && [ "$i2" -ge 64 ] && [ "$i2" -le 127 ]; then
                return 0
        else
                return 1
        fi
}

if ! is_private_ip "$ips"; then
        if ! ipset list | grep "$ips"; then
                echo "add chnroute $ips" >> /root/script/chnroute-ipset
                echo "$DATE: Add $ips to the chnroute seccessfully" >>/root/script/ovpn-script.log
        fi
else
        echo "$DATE: The $ips is a private ip address" >>/root/script/ovpn-script.log
fi

echo "$DATE: Openvpn-client startup" >>/root/script/ovpn-script.log
echo "------------------------------END-------------------------------" >>/root/script/ovpn-script.log
