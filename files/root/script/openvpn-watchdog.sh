#!/bin/sh

DATE=`date +%Y-%m-%d-%H:%M:%S`

function exist_tun0(){
       ip addr show tun0 > /dev/null 2>&1
       return $?
}

if ! exist_tun0;then
        echo $DATE: tun0 not exist,restart openvpn >> /tmp/ovpn-watchdog.log
        /etc/init.d/openvpn restart
        exit 0
else             
        #check and add rules of mangle
        echo $DATE: Start to check iptables rules >> /tmp/ovpn-watchdog.log
        iptables -t mangle -C PREROUTING -m set ! --match-set chnroute dst -j MARK --set-mark 1
        if [ $? = 0 ]; then
                echo "$DATE: The PREROUTING rules alread exist" >>/tmp/ovpn-watchdog.log
                iptables -t mangle -C OUTPUT -m set ! --match-set chnroute dst -j MARK --set-mark 1
                if [ $? = 0 ]; then
                        echo "$DATE: The OUTPUT rules alread exist" >>/tmp/ovpn-watchdog.log
                else
                        iptables -t mangle -I OUTPUT -m set ! --match-set chnroute dst -j MARK --set-mark 1
                        echo "$DATE: Add OUTPUT  rules" >>/tmp/ovpn-watchdog.log
                fi
        else
                iptables -t mangle -I PREROUTING -m set ! --match-set chnroute dst -j MARK --set-mark 1
                echo "$DATE: Add PREROUTING rules" >>/tmp/ovpn-watchdog.log

                iptables -t mangle -C OUTPUT -m set ! --match-set chnroute dst -j MARK --set-mark 1
                if [ $? = 0 ]; then
                        echo "$DATE: The OUTPUT rules alread exist" >>/tmp/ovpn-watchdog.log
                else
                        iptables -t mangle -I OUTPUT -m set ! --match-set chnroute dst -j MARK --set-mark 1
                        echo "$DATE: Add OUTPUT  rules" >>/tmp/ovpn-watchdog.log
                fi
        fi
        #check gateway of vpn
        tries=0
        gw=$(ip addr show tun0 | grep 'inet ' | cut -d' ' -f6 | cut -d'.' -f1-2).0.1
        echo  $DATE: Start to check gateway of vpn-tun0 >>/tmp/ovpn-watchdog.log
        while [[ $tries -lt 5 ]]
        do
                if /bin/ping -c 1 $gw >/dev/null
                then
                        echo $DATE: Ovpn gateway is reachable >> /tmp/ovpn-watchdog.log
                        exit 0
                fi
                tries=$((tries+1))
                sleep 10
                echo $DATE: tries: $tries >> /tmp/ovpn-watchdog.log
        done

        echo $DATE: openvpn restart >> /tmp/ovpn-watchdog.log
        /etc/init.d/openvpn restart
fi
