#!/bin/sh
  
DATE=`date +%Y-%m-%d-%H:%M:%S`

if [ ! -d /root/script ];then
        mkdir -p /root/script
fi

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

#Create tmp directory and download source file of IPs
mkdir -p /tmp/china-ip/
wget -P /tmp/china-ip/ https://raw.githubusercontent.com/metowolf/iplist/master/data/special/china.txt

if [ ! -f /tmp/china-ip/china.txt ];then
        echo $DATE: IPS file download failed, EXIT ! > /root/script/update-ip.log
        exit 0
else
        echo $DATE: IPs file download successfully. > /root/script/update-ip.log
        #Delete empty row
        grep -vE '^#|^&}' /tmp/china-ip/china.txt  > /tmp/china-ip/ip.txt

        #Convert to ipse format and move to directory of openvpn
        sed -i 's/^/add chnroute /g' /tmp/china-ip/ip.txt
        mv -f /tmp/china-ip/ip.txt /root/script/chnroute-ipset
        echo $DATE: Format conversion done >> /root/script/update-ip.log

        #Add private IPs to ipset list
        echo "add chnroute 10.0.0.0/8" >> /root/script/chnroute-ipset
        echo "add chnroute 172.16.0.0/12" >> /root/script/chnroute-ipset
        echo "add chnroute 192.168.0.0/16" >> /root/script/chnroute-ipset
        echo "add chnroute 100.64.0.0/10" >> /root/script/chnroute-ipset
        echo "add chnroute 119.29.29.29/32" >> /root/script/chnroute-ipset
        if ! is_private_ip "$ips"; then
                echo "add chnroute $ips" >> /root/script/chnroute-ipset
                echo "$DATE: Add $ips,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10 to the chnroute seccessfully" >> /root/script/update-ip.log
        else
                echo "$DATE: The $ips is a private ip address" >> /root/script/update-ip.log
                echo $DATE: Seccess to add  10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10 to the chnroute >> /root/script/update-ip.log
        fi

        #Reload new ipset list
        ipset flush chnroute
        ipset restore -f /root/script/chnroute-ipset
        echo $DATE: Loading ipset list successfully >> /root/script/update-ip.log

        #Delete tmp
        rm -rf /tmp/china-ip
        ip_number=$(cat /root/script/chnroute-ipset | wc -l)
        echo '---------------------------------------------------------------------------' >> /root/script/update-ip.log
        echo "$DATE: Update ipset list from github completely" >> /root/script/update-ip.log
        echo "$DATE: The number of newest ipset list is: $ip_number"  >> /root/script/update-ip.log
        echo '---------------------------------------------------------------------------' >> /root/script/update-ip.log

        echo '---------------------------------------------------------------------------'
        echo "$DATE: Update ipset list from github completely"
        echo "$DATE: The number of newest ipset list is: $ip_number"
        echo '---------------------------------------------------------------------------'

        #erase ovpn-scripe.log
        echo " " > /root/script/ovpn-script.log
        exit 0
fi
