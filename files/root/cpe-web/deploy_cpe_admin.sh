#!/bin/sh
# ====================================================================
# SDWAN CPE Web Admin installer for OpenWrt 23.05
# Installs files from ./files instead of generating every file inline.
# ====================================================================

set -eu

APP_NAME="cpe-web-admin"
VERSION="5.17"
SRC_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PAYLOAD_DIR="$SRC_DIR/files"
BACKUP_ROOT="/root/cpe_admin_backup"
DB_DIR="/usr/share/traffic_rrd"
RESET_RRD=0
SKIP_DEPS=0

usage() {
    cat <<EOF
Usage: sh deploy_cpe_admin.sh [options]

Options:
  --reset-rrd   remove old RRD traffic history before installing
  --skip-deps   skip opkg dependency checks
  -h, --help    show this help
EOF
}

log() {
    echo "[$APP_NAME] $*"
}

die() {
    echo "[$APP_NAME] ERROR: $*" >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --reset-rrd) RESET_RRD=1 ;;
        --skip-deps) SKIP_DEPS=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
    shift
done

[ "$(id -u)" = "0" ] || die "please run as root on OpenWrt"
[ -d "$PAYLOAD_DIR" ] || die "payload directory not found: $PAYLOAD_DIR"

detect_wan() {
    local wan arch
    arch=$(uname -m 2>/dev/null)
    case "$arch" in
        x86_64|i386|i686) wan="eth0" ;;
        aarch64*|arm*) wan="eth1" ;;
        *) wan="eth0" ;;
    esac
    echo "$wan" | tr -d ' \t\r\n'
}

install_deps() {
    [ "$SKIP_DEPS" = "1" ] && return 0
    missing=""
    for bin in rrdtool awk iptables; do
        command -v "$bin" >/dev/null 2>&1 || missing="$missing $bin"
    done
    [ -z "$missing" ] && {
        log "dependency check passed"
        return 0
    }
    command -v opkg >/dev/null 2>&1 || die "missing dependencies:$missing, and opkg is unavailable"
    log "installing missing dependencies:$missing"
    opkg update
    opkg install rrdtool awk iptables-nft
}

backup_path() {
    local src="$1"
    local backup_dir="$2"
    [ -e "$src" ] || return 0
    mkdir -p "$backup_dir$(dirname "$src")"
    cp -a "$src" "$backup_dir$src"
}

copy_payload() {
    local backup_dir="$1"
    local rel src dst

    find "$PAYLOAD_DIR" -type f | while read -r src; do
        rel=${src#"$PAYLOAD_DIR"}
        dst="$rel"
        backup_path "$dst" "$backup_dir"
        mkdir -p "$(dirname "$dst")"
        cp "$src" "$dst"
    done
}

set_permissions() {
    chmod 755 /usr/bin/traffic_collector.sh 2>/dev/null || true
    chmod 755 /www/cgi-bin/get_history_speed 2>/dev/null || true
    chmod 755 /www/cgi-bin/get_net_speed 2>/dev/null || true
    chmod 755 /www/cgi-bin/cpe_api.sh 2>/dev/null || true
    chmod 755 /www/cgi-bin/cpe_redsocks.sh 2>/dev/null || true
    chmod 700 /etc/cpe_iptables 2>/dev/null || true
    chmod 700 /etc/cpe_iptables.sh 2>/dev/null || true
    chmod 600 /etc/cpe_users 2>/dev/null || true
    chmod 600 /etc/config/cpe_iptables.json 2>/dev/null || true
}

normalize_installed_text_files() {
    for f in \
        /usr/bin/traffic_collector.sh \
        /www/cgi-bin/get_history_speed \
        /www/cgi-bin/get_net_speed \
        /www/cgi-bin/cpe_api.sh \
        /www/cgi-bin/cpe_redsocks.sh \
        /www/cpe/index.html \
        /www/cpe/settings.html \
        /www/cpe/redsocks.html \
        /www/cpe/network.html \
        /www/cpe/wifi.html \
        /www/cpe/basic.html \
        /www/cpe/openvpn.html \
        /www/cpe/qos.html \
        /www/cpe/speed.html
    do
        [ -f "$f" ] && sed -i 's/\r$//' "$f"
    done
}

install_cron() {
    local cron_tmp
    cron_tmp="/tmp/cpe_cron.$$"
    crontab -l 2>/dev/null | grep -v '/usr/bin/traffic_collector.sh' > "$cron_tmp" || true
    echo "* * * * * /usr/bin/traffic_collector.sh >/dev/null 2>&1" >> "$cron_tmp"
    crontab "$cron_tmp"
    rm -f "$cron_tmp"
    /etc/init.d/cron enable >/dev/null 2>&1 || true
    /etc/init.d/cron restart >/dev/null 2>&1 || true
}

install_qos() {
    local backup_dir="$1"
    local install_dir conf_file init_script hotplug_script
    install_dir="/opt/qos_deploy"
    conf_file="/etc/config/qos"
    init_script="/etc/init.d/qos"
    hotplug_script="/etc/hotplug.d/iface/95-qos-auto"

    log "installing shared tun QoS limiter"
    [ -f "$init_script" ] && {
        "$init_script" stop >/dev/null 2>&1 || true
        "$init_script" disable >/dev/null 2>&1 || true
        backup_path "$init_script" "$backup_dir"
    }
    [ -f "$install_dir/qos_script.sh" ] && /bin/sh "$install_dir/qos_script.sh" stop >/dev/null 2>&1 || true
    [ -e "$install_dir" ] && backup_path "$install_dir" "$backup_dir"
    [ -f "$hotplug_script" ] && backup_path "$hotplug_script" "$backup_dir"

    rm -rf "$install_dir"
    rm -f "$init_script" "$hotplug_script" /var/run/qos_hotplug.lock
    mkdir -p "$install_dir" /etc/hotplug.d/iface /etc/config

    if [ ! -f "$conf_file" ]; then
        cat > "$conf_file" <<'EOF'
config qos 'global'
	option enabled '1'
	option download '10240'
	option upload '10240'
EOF
    fi

    cat > "$install_dir/qos_script.sh" <<'EOF'
#!/bin/sh
export PATH="/usr/sbin:/usr/bin:/sbin:/bin"

CONF_FILE="/etc/config/qos"
LOG_FILE="/var/log/qos.log"

log_msg() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [QOS] $1" >> "$LOG_FILE"
}

load_config() {
    . /lib/functions.sh
    config_load qos
    config_get_bool enabled global enabled 0
    config_get DL_LIMIT global download "10240"
    config_get UL_LIMIT global upload "10240"
}

ensure_ifb() {
    for module in sch_htb sch_ingress cls_u32 act_mirred; do
        modprobe "$module" 2>/dev/null || {
            log_msg "ERROR: required tc module is unavailable: $module"
            return 1
        }
    done
    modprobe ifb numifbs=2 2>/dev/null || modprobe ifb 2>/dev/null || {
        log_msg "ERROR: IFB kernel module is unavailable"
        return 1
    }
    for dev in ifb0 ifb1; do
        if ! ip link show dev "$dev" >/dev/null 2>&1; then
            ip link add "$dev" type ifb 2>/dev/null || {
                log_msg "ERROR: failed to create $dev"
                return 1
            }
        fi
        ip link set "$dev" up 2>/dev/null || {
            log_msg "ERROR: failed to bring $dev up"
            return 1
        }
        ip link show dev "$dev" >/dev/null 2>&1 || {
            log_msg "ERROR: $dev is unavailable after creation"
            return 1
        }
    done
}

list_tun_devs() {
    ip link show | grep -oE 'tun[0-9]+' | sort -u | grep -v '^tun10$' || true
}

prepare_tun() {
    dev="$1"
    tc qdisc del dev "$dev" root 2>/dev/null
    tc qdisc del dev "$dev" handle ffff: ingress 2>/dev/null
}

attach_tun() {
    dev="$1"
    tc qdisc add dev "$dev" root handle 1: htb default 10 || return 1
    tc class add dev "$dev" parent 1: classid 1:10 htb rate "$2" ceil "$2" || return 1
    tc filter add dev "$dev" parent 1: protocol ip prio 1 u32 match u32 0 0 action mirred egress redirect dev ifb1 || return 1
    tc qdisc add dev "$dev" handle ffff: ingress || return 1
    tc filter add dev "$dev" parent ffff: protocol ip prio 1 u32 match u32 0 0 action mirred egress redirect dev ifb0 || return 1
}

start() {
    stop
    log_msg "=== Starting QoS Service ==="
    load_config
    ensure_ifb || return 1

    TUN_DEVS=$(list_tun_devs)
    [ -n "$TUN_DEVS" ] || {
        log_msg "WARNING: No active tun interface found."
        return 0
    }

    if [ "$enabled" -eq 0 ]; then
        # Keep the IFB mirrors alive for SDWAN traffic monitoring when rate limiting is disabled.
        tc qdisc del dev ifb0 root 2>/dev/null
        tc qdisc del dev ifb1 root 2>/dev/null
        tc qdisc add dev ifb0 root handle 1: htb default 10 || return 1
        tc class add dev ifb0 parent 1: classid 1:10 htb rate 1000000kbit ceil 1000000kbit || return 1
        tc qdisc add dev ifb1 root handle 1: htb default 10 || return 1
        tc class add dev ifb1 parent 1: classid 1:10 htb rate 1000000kbit ceil 1000000kbit || return 1
        for dev in $TUN_DEVS; do
            prepare_tun "$dev"
            attach_tun "$dev" 1000000kbit || { log_msg "ERROR: failed to attach monitor to $dev"; return 1; }
            log_msg "Traffic monitor attached without rate limit: $dev"
        done
        return 0
    fi

    tc qdisc del dev ifb0 root 2>/dev/null
    tc qdisc del dev ifb1 root 2>/dev/null
    tc qdisc add dev ifb0 root handle 1: htb default 10 || return 1
    tc class add dev ifb0 parent 1: classid 1:10 htb rate ${DL_LIMIT}kbit ceil ${DL_LIMIT}kbit || return 1
    tc qdisc add dev ifb1 root handle 1: htb default 10 || return 1
    tc class add dev ifb1 parent 1: classid 1:10 htb rate ${UL_LIMIT}kbit ceil ${UL_LIMIT}kbit || return 1

    log_msg "Shared pool created: Download=${DL_LIMIT}kbps, Upload=${UL_LIMIT}kbps"

    for dev in $TUN_DEVS; do
        prepare_tun "$dev"
        attach_tun "$dev" ${UL_LIMIT}kbit || { log_msg "ERROR: failed to attach QoS to $dev"; return 1; }
        log_msg "Successfully attached interface to shared pool: $dev"
    done
}

stop() {
    log_msg "=== Stopping QoS Service ==="
    for dev in $(list_tun_devs); do
        tc filter del dev "$dev" parent 1: 2>/dev/null
        tc filter del dev "$dev" parent ffff: 2>/dev/null
        tc qdisc del dev "$dev" root 2>/dev/null
        tc qdisc del dev "$dev" handle ffff: ingress 2>/dev/null
    done
    tc qdisc del dev ifb0 root 2>/dev/null
    tc qdisc del dev ifb1 root 2>/dev/null
    log_msg "QoS Service stopped."
}

case "$1" in
    start) start ;;
    stop) stop ;;
    *) exit 1 ;;
esac
EOF
    chmod 755 "$install_dir/qos_script.sh"

    cat > "$init_script" <<'EOF'
#!/bin/sh /etc/rc.common

START=99
STOP=10
USE_PROCD=1
PROG="/opt/qos_deploy/qos_script.sh"

start_service() {
    procd_open_instance
    procd_set_param command /bin/sh "$PROG" start
    procd_set_param type oneshot
    procd_close_instance
}

stop_service() {
    /bin/sh "$PROG" stop
}

restart() {
    /bin/sh "$PROG" stop
    sleep 1
    /bin/sh "$PROG" start
}
EOF
    chmod 755 "$init_script"

    cat > "$hotplug_script" <<'EOF'
#!/bin/sh

LOCK_FILE="/var/run/qos_hotplug.lock"
DELAY_SECONDS="3"

echo "$DEVICE" | grep -q "tun" || exit 0
case "$ACTION" in
    ifup|ifdown)
        if [ -f "$LOCK_FILE" ]; then
            touch "$LOCK_FILE"
            exit 0
        fi
        touch "$LOCK_FILE"
        (
            while true; do
                LAST_MOD=$(stat -c %Y "$LOCK_FILE")
                NOW=$(date +%s)
                AGE=$((NOW - LAST_MOD))
                if [ "$AGE" -ge "$DELAY_SECONDS" ]; then
                    /etc/init.d/qos restart
                    rm -f "$LOCK_FILE"
                    break
                fi
                sleep 1
            done
        ) &
        ;;
esac
EOF
    chmod 755 "$hotplug_script"
    "$init_script" enable >/dev/null 2>&1 || true
    "$init_script" restart >/dev/null 2>&1 || true
}

init_runtime() {
    mkdir -p "$DB_DIR" /tmp/traffic_cache /www/cgi-bin /www/cpe /etc/config
    rm -f /tmp/traffic_cache/*.cache 2>/dev/null || true
    [ "$RESET_RRD" = "1" ] && {
        log "removing old RRD traffic history because --reset-rrd was requested"
        rm -rf "$DB_DIR"
        mkdir -p "$DB_DIR"
    }
    [ -f /etc/config/cpe_iptables.json ] || echo "[]" > /etc/config/cpe_iptables.json
    [ -f /etc/config/rtty ] || cat > /etc/config/rtty <<'EOF'
config rtty
	option id 'Default'
	option description 'SWITCH_Z8119AX'
	option host 'rtty.switch-net.com'
	option port '5912'
	option token 'switch-net.com'
EOF
    [ -f /etc/zabbix_agentd.conf ] || cat > /etc/zabbix_agentd.conf <<'EOF'
Hostname=CPE-Default
AllowRoot=1
Server=zabbix.switch-net.com
ServerActive=zabbix.switch-net.com
LogFile=/tmp/zabbix_agentd.log
LogFileSize=1
AllowKey=system.run[*]
StartAgents=1
Timeout=10
BufferSend=5
BufferSize=100
EOF
}

cleanup_legacy_paths() {
    local backup_dir="$1"
    if [ -e /www/speed/index.html ]; then
        backup_path /www/speed/index.html "$backup_dir"
        rm -f /www/speed/index.html
        rmdir /www/speed 2>/dev/null || true
    fi
}

main() {
    local wan backup_dir stamp
    stamp=$(date +%Y%m%d-%H%M%S)
    backup_dir="$BACKUP_ROOT/$stamp"

    log "installing $APP_NAME v$VERSION"
    install_deps
    init_runtime

    wan=$(detect_wan)
    [ -n "$wan" ] || wan="eth0"
    log "detected WAN interface: $wan"

    mkdir -p "$backup_dir"
    log "backing up replaced files to $backup_dir"
    cleanup_legacy_paths "$backup_dir"
    copy_payload "$backup_dir"
    normalize_installed_text_files
    set_permissions
    install_cron
    install_qos "$backup_dir"

    if [ -f /www/cpe/assets/echarts.min.js ]; then
        log "local ECharts asset installed"
    else
        log "warning: local ECharts asset is missing; traffic page will try CDN fallback"
    fi

    if [ -x /usr/bin/traffic_collector.sh ]; then
        sh /usr/bin/traffic_collector.sh || true
    fi

    log "installation complete"
    echo "===================================================================="
    echo " CPE Web Admin has been installed."
    echo " Visit: http://[router-ip]/cpe/index.html"
    echo " Default account: admin / admin888"
    echo " Backup path: $backup_dir"
    echo "===================================================================="
}

main "$@"
