#!/bin/sh
DB_DIR="/usr/share/traffic_rrd"
CACHE_DIR="/tmp/traffic_cache"
mkdir -p "$DB_DIR"
mkdir -p "$CACHE_DIR"

get_wan_iface() {
    arch=$(uname -m 2>/dev/null)
    case "$arch" in
        x86_64|i386|i686) preferred="eth0" ;;
        arm*|aarch64*) preferred="eth1" ;;
        *) preferred="eth0" ;;
    esac
    if grep -q "^[[:space:]]*$preferred:" /proc/net/dev 2>/dev/null; then
        echo "$preferred"
        return
    fi
    if command -v uci >/dev/null 2>&1; then
        cfg=$(uci -q get network.wan.device || uci -q get network.wan.ifname || true)
        if [ -n "$cfg" ] && grep -q "^[[:space:]]*$cfg:" /proc/net/dev 2>/dev/null; then
            echo "$cfg"
            return
        fi
    fi
    route_if=$(ip route 2>/dev/null | awk '/default/ {print $5; exit}')
    if [ -n "$route_if" ] && grep -q "^[[:space:]]*$route_if:" /proc/net/dev 2>/dev/null; then
        echo "$route_if"
        return
    fi
    echo "$preferred"
}

WAN_IFACE=$(get_wan_iface)

init_rrd() {
    iface=$1
    if [ ! -f "$DB_DIR/$iface.rrd" ]; then
        rrdtool create "$DB_DIR/$iface.rrd" --step 60 \
            DS:rx:GAUGE:120:0:U \
            DS:tx:GAUGE:120:0:U \
            RRA:AVERAGE:0.5:1:4320 \
            RRA:AVERAGE:0.5:5:8640 \
            RRA:AVERAGE:0.5:30:5760 \
            RRA:AVERAGE:0.5:120:4400
    fi
}

get_bytes() {
    iface=$1
    awk -v ifn="$iface" '$1 ~ "^"ifn":" {print $2, $10}' /proc/net/dev
}

calc_speed() {
    key=$1
    current_rx=$2
    current_tx=$3
    cache_file="$CACHE_DIR/$key.cache"
    now=$(date +%s)
    if [ -f "$cache_file" ]; then
        read -r last_time last_rx last_tx < "$cache_file"
        case "$last_time:$last_rx:$last_tx:$current_rx:$current_tx" in
            *[!0-9:]*|::*|*::)
                last_time=""
                ;;
        esac
        if [ -n "$last_time" ]; then
            time_delta=$((now - last_time))
        else
            time_delta=0
        fi
        if [ "$time_delta" -gt 0 ] && [ "$current_rx" -ge "$last_rx" ] && [ "$current_tx" -ge "$last_tx" ]; then
            rx_speed_scaled=$(( (current_rx - last_rx) * 8 * 100 / time_delta / 1024 / 1024 ))
            tx_speed_scaled=$(( (current_tx - last_tx) * 8 * 100 / time_delta / 1024 / 1024 ))
            rx_speed=$(awk -v s=$rx_speed_scaled 'BEGIN {printf "%.2f", s/100}')
            tx_speed=$(awk -v s=$tx_speed_scaled 'BEGIN {printf "%.2f", s/100}')
        else
            rx_speed="0.00"
            tx_speed="0.00"
        fi
    else
        rx_speed="0.00"
        tx_speed="0.00"
    fi
    echo "$(date +%s) $current_rx $current_tx" > "$cache_file"
}

for i in SDWAN_TOTAL WAN_TOTAL LAN_TOTAL; do init_rrd "$i"; done

ifb0_stats=$(get_bytes "ifb0")
ifb1_stats=$(get_bytes "ifb1")

ifb0_tx=$(echo "$ifb0_stats" | awk '{print $2}')
[ -z "$ifb0_tx" ] && ifb0_tx=0

ifb1_tx=$(echo "$ifb1_stats" | awk '{print $2}')
[ -z "$ifb1_tx" ] && ifb1_tx=0

calc_speed "SDWAN_TOTAL" "$ifb0_tx" "$ifb1_tx"
rrdtool update "$DB_DIR/SDWAN_TOTAL.rrd" N:"$rx_speed":"$tx_speed" >/dev/null 2>&1 || true

wan_stats=$(get_bytes "$WAN_IFACE")
wan_rx=$(echo "$wan_stats" | awk '{print $1}')
wan_tx=$(echo "$wan_stats" | awk '{print $2}')
[ -z "$wan_rx" ] && wan_rx=0
[ -z "$wan_tx" ] && wan_tx=0
calc_speed "WAN_TOTAL" "$wan_rx" "$wan_tx"
rrdtool update "$DB_DIR/WAN_TOTAL.rrd" N:"$rx_speed":"$tx_speed" >/dev/null 2>&1 || true

lan_stats=$(get_bytes "br-lan")
lan_rx=$(echo "$lan_stats" | awk '{print $1}')
lan_tx=$(echo "$lan_stats" | awk '{print $2}')
[ -z "$lan_rx" ] && lan_rx=0
[ -z "$lan_tx" ] && lan_tx=0
calc_speed "LAN_TOTAL" "$lan_rx" "$lan_tx"
rrdtool update "$DB_DIR/LAN_TOTAL.rrd" N:"$rx_speed":"$tx_speed" >/dev/null 2>&1 || true
