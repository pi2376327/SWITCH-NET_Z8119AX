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

#更改ubi参数<0x2000000>
#sed #sed -i "s/0x580000 0x20000000/0x580000 0x7280000/g" target/linux/mediatek/dts/mt7981b-zbtlink-zbt-z8119a
