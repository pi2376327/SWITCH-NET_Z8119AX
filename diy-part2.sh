#!/bin/bash
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#
# Copyright (c) 2019-2024 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

# Modify default IP
#sed -i 's/192.168.1.1/192.168.50.5/g' package/base-files/files/bin/config_generate

# Modify default theme
#sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci/Makefile

# Modify hostname
#sed -i 's/OpenWrt/P3TERX-Router/g' package/base-files/files/bin/config_generate

#openwrt #CONFIG_PACKAGE_luci-theme-argon=y
git clone https://github.com/jerrykuku/luci-theme-argon.git package/luci-theme-argon

#redsocks2 
git clone https://github.com/pi2376327/openwrt-redsocks2.git package/redsocks2

#download binary NextTrace
mkdir -p files/usr/bin
TAG_NAME=$(curl -s https://api.github.com/repos/nxtrace/NTrace-core/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
wget -O files/usr/bin/nexttrace https://github.com/nxtrace/NTrace-core/releases/download/${TAG_NAME}/nexttrace_linux_arm64 && chmod +x files/usr/bin/nexttrace
#wget -O /usr/bin/nexttrace https://github.com/nxtrace/NTrace-core/releases/download/v1.7.1/nexttrace_linux_arm64 && chmod +x /usr/bin/nexttrace 
