#!/bin/sh
export PATH="/usr/sbin:/usr/bin:/sbin:/bin"

# --- 配置区 ---
DL_LIMIT="20"
UL_LIMIT="20"

start() {
    # 1. 模块加载
    if ! lsmod | grep -q ifb; then
        rmmod ifb 2>/dev/null
        modprobe ifb numifbs=2 || {
            modprobe ifb
            ip link add ifb0 type ifb 2>/dev/null
            ip link add ifb1 type ifb 2>/dev/null
        }
    fi
    ip link set ifb0 up
    ip link set ifb1 up

    # 2. 清理
    stop

    # 3. 配置下载/上传池
    tc qdisc add dev ifb1 root handle 1: htb default 10
    tc class add dev ifb1 parent 1: classid 1:10 htb rate ${DL_LIMIT}mbit ceil ${DL_LIMIT}mbit
    tc qdisc add dev ifb0 root handle 1: htb default 10
    tc class add dev ifb0 parent 1: classid 1:10 htb rate ${UL_LIMIT}mbit ceil ${UL_LIMIT}mbit

    # 4. 绑定所有活跃的 tun 接口
    TUN_DEVS=$(ip link show | grep -oE 'tun[0-9]+')
    [ -z "$TUN_DEVS" ] && return 0

    for dev in $TUN_DEVS; do
        tc qdisc add dev $dev root handle 1: htb
        tc filter add dev $dev parent 1: protocol ip prio 1 u32 match u32 0 0 action mirred egress redirect dev ifb0
        tc qdisc add dev $dev handle ffff: ingress
        tc filter add dev $dev parent ffff: protocol ip prio 1 u32 match u32 0 0 action mirred egress redirect dev ifb1
    done
}

stop() {
    # 清理所有 tun、ifb 接口上的 tc 规则
    for dev in $(ip link show | grep -oE 'tun[0-9]+|ifb[0-9]+'); do
        tc qdisc del dev $dev root 2>/dev/null
        tc qdisc del dev $dev handle ffff: ingress 2>/dev/null
    done
}

case "$1" in
    start) start ;;
    stop) stop ;;
    *) exit 1 ;;
esac
