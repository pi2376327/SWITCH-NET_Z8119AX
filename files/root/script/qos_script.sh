#!/bin/sh
export PATH="/usr/sbin:/usr/bin:/sbin:/bin"

DL_LIMIT="11"
UL_LIMIT="11"
LOG_FILE="/var/log/qos.log"

log_msg() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [QOS] $1" >> "$LOG_FILE"
}

start() {
    log_msg "=== Starting QoS Service ==="
    stop

    # Load IFB module cleanly
    modprobe ifb numifbs=2 2>/dev/null || {
        modprobe ifb 2>/dev/null
        ip link add ifb0 type ifb 2>/dev/null
        ip link add ifb1 type ifb 2>/dev/null
    }
    ip link set ifb0 up 2>/dev/null
    ip link set ifb1 up 2>/dev/null

    # Create shared HTB rate pools
    tc qdisc add dev ifb1 root handle 1: htb default 10
    tc class add dev ifb1 parent 1: classid 1:10 htb rate ${DL_LIMIT}mbit ceil ${DL_LIMIT}mbit
    tc qdisc add dev ifb0 root handle 1: htb default 10
    tc class add dev ifb0 parent 1: classid 1:10 htb rate ${UL_LIMIT}mbit ceil ${UL_LIMIT}mbit
    log_msg "Shared pool created: DL=${DL_LIMIT}Mbit/s, UL=${UL_LIMIT}Mbit/s"

    # Scan and bind all active tun interfaces to the shared pool
    TUN_DEVS=$(ip link show | grep -oE 'tun[0-9]+')
    if [ -z "$TUN_DEVS" ]; then
        log_msg "WARNING: No active tun interface found."
        return 0
    fi

    for dev in $TUN_DEVS; do
        tc qdisc add dev $dev root handle 1: htb
        tc filter add dev $dev parent 1: protocol ip prio 1 u32 match u32 0 0 action mirred egress redirect dev ifb0
        tc qdisc add dev $dev handle ffff: ingress
        tc filter add dev $dev parent ffff: protocol ip prio 1 u32 match u32 0 0 action mirred egress redirect dev ifb1
        log_msg "Successfully attached interface to shared pool: $dev"
    done
}

stop() {
    log_msg "=== Stopping QoS Service ==="
    # Remove all tc rules from tun and ifb interfaces
    for dev in $(ip link show | grep -oE 'tun[0-9]+|ifb[0-9]+'); do
        tc filter del dev $dev parent 1: 2>/dev/null
        tc filter del dev $dev parent ffff: 2>/dev/null
        tc qdisc del dev $dev root 2>/dev/null
        tc qdisc del dev $dev handle ffff: ingress 2>/dev/null
    done

    ip link set ifb0 down 2>/dev/null
    ip link set ifb1 down 2>/dev/null

    if lsmod | grep -q ifb; then
        rmmod ifb 2>/dev/null
    fi
    log_msg "QoS Service stopped. Network reverted to stock."
}

case "$1" in
    start) start ;;
    stop) stop ;;
    *) exit 1 ;;
esac
