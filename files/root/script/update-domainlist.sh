#!/bin/sh 

DATE=`date +%Y-%m-%d-%H:%M:%S`

if [ ! -d /tmp/smartdns/ ];then
        mkdir -p /tmp/smartdns
fi

#Download the file of China-Domain-List
wget -O /tmp/smartdns/china.conf https://raw.githubusercontent.com/felixonmars/dnsmasq-china-list/master/accelerated-domains.china.conf 

if [ ! -f /tmp/smartdns/china.conf ];then
    echo $DATE: Domain file download failed, EXIT !   >> /root/script/update.log
    exit 0
else
    echo $DATE: Domian file download successful.  >> /root/script/update.log  
 
    #Format conversion
    sed -e 's/server=/nameserver /g' -e 's/114.114.114.114/china/g' /tmp/smartdns/china.conf > /tmp/smartdns/address.conf
    #cp -a /tmp/smartdns/address.conf /root/script/cndomainlist.conf
    mv -f /tmp/smartdns/address.conf /etc/smartdns/address.conf
    echo $DATE: The conversion of the file to a smartDNS .conf format has been completed.

    # Delete the tmp files
    rm -rf /tmp/smartdns/
    domain_number=$(cat /etc/smartdns/address.conf | wc -l)
    echo "$DATE: Update domain list from github/felixonmars completely"
    echo "$DATE: The number of newest domain list is: $domain_number"
    echo '-----------------------------------------------------------------------------------------' >> /root/script/update.log
    echo "$DATE: Update domain list from github/felixonmars completely" >> /root/script/update.log
    echo "$DATE: The number of newest domain list is: $domain_number"  >> /root/script/update.log
    echo '-----------------------------------------------------------------------------------------' >> /root/script/update.log
    /etc/init.d/smartdns restart

    exit 0
fi
