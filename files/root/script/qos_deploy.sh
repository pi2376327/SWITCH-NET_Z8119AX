#!/bin/sh
# OpenWrt 23.05 多 TUN 接口共享限速一键部署脚本 (支持防冲突强制覆盖升级)
# 完美支持手动配置 UCI、动态 Hotplug 发现、防抖动重启机制

set -e

INSTALL_DIR="/opt/qos_deploy"
CONF_FILE="/etc/config/qos"
INIT_SCRIPT="/etc/init.d/qos"
HOTPLUG_SCRIPT="/etc/hotplug.d/iface/95-qos-auto"

echo "=== 开始部署多 TUN 接口共享限速系统 ==="

# ==========================================
# 0. 升级与强制覆盖前置清理 (防冲突)
# ==========================================
echo "正在检测并清理旧版本的限速服务与冲突文件..."

# 如果旧的服务脚本存在，先尝试停止服务（这会自动清除现有的 tc 规则和 ifb 模块）
if [ -f "$INIT_SCRIPT" ]; then
    echo "发现旧的系统服务，正在停止..."
    "$INIT_SCRIPT" stop 2>/dev/null || true
    "$INIT_SCRIPT" disable 2>/dev/null || true
fi

# 如果主脚本存在，兜底执行一次停止逻辑，防止系统服务未正确卸载残留内核规则
if [ -f "$INSTALL_DIR/qos_script.sh" ]; then
    echo "执行旧核心脚本的清理逻辑..."
    /bin/sh "$INSTALL_DIR/qos_script.sh" stop 2>/dev/null || true
fi

# 强行删除旧的程序文件和 hotplug 脚本（不删除 UCI 配置文件以保留用户原有限速值）
echo "正在强制覆盖程序目录与自动化脚本..."
rm -rf "$INSTALL_DIR"
rm -f "$INIT_SCRIPT"
rm -f "$HOTPLUG_SCRIPT"
rm -f /var/run/qos_hotplug.lock

# 重新创建干净的安装目录
mkdir -p "$INSTALL_DIR"

# ==========================================
# 1. 生成 UCI 配置文件 (保留原配置或创建默认)
# ==========================================
if [ ! -f "$CONF_FILE" ]; then
    echo "正在创建全新配置文件: $CONF_FILE ..."
    cat << 'EOF' > "$CONF_FILE"
config qos 'global'
	option enabled '1'
	option download '10240'
	option upload '10240'
EOF
else
    echo "检测到已存在旧的限速配置文件，保留原配置（避免覆盖您的限速值）。"
fi

# ==========================================
# 2. 生成核心 QoS 处理脚本
# ==========================================
echo "正在生成核心控制脚本: $INSTALL_DIR/qos_script.sh ..."
cat << 'EOF' > "$INSTALL_DIR/qos_script.sh"
#!/bin/sh
export PATH="/usr/sbin:/usr/bin:/sbin:/bin"

CONF_FILE="/etc/config/qos"
LOG_FILE="/var/log/qos.log"

log_msg() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [QOS] $1" >> "$LOG_FILE"
}

load_config() {
    local enabled
    config_load qos
    config_get_bool enabled global enabled 0
    if [ "$enabled" -eq 0 ]; then
        log_msg "QoS is disabled in config."
        exit 0
    fi
    config_get DL_LIMIT global download "10240"
    config_get UL_LIMIT global upload "10240"
}

start() {    
    stop
    log_msg "=== Starting QoS Service ==="

    . /lib/functions.sh
    load_config

    # 加载 IFB 模块
    modprobe ifb numifbs=2 2>/dev/null || {
        modprobe ifb 2>/dev/null
        ip link add ifb0 type ifb 2>/dev/null
        ip link add ifb1 type ifb 2>/dev/null
    }
    ip link set ifb0 up 2>/dev/null
    ip link set ifb1 up 2>/dev/null

    # 创建共享 HTB 速率池
    # ifb0 用于控制【下载】 (tunX Ingress -> ifb0 Egress)
    tc qdisc add dev ifb0 root handle 1: htb default 10
    tc class add dev ifb0 parent 1: classid 1:10 htb rate ${DL_LIMIT}kbit ceil ${DL_LIMIT}kbit
    
    # ifb1 用于控制【上传】 (tunX Egress -> ifb1 Egress)
    tc qdisc add dev ifb1 root handle 1: htb default 10
    tc class add dev ifb1 parent 1: classid 1:10 htb rate ${UL_LIMIT}kbit ceil ${UL_LIMIT}kbit

    log_msg "Shared pool created: Download=${DL_LIMIT}kbps, Upload=${UL_LIMIT}kbps"
    echo "Shared pool created: Download=${DL_LIMIT}kbps, Upload=${UL_LIMIT}kbps"

    # 扫描并绑定所有活跃的 tun 接口
    TUN_DEVS=$(ip link show | grep -oE 'tun[0-9]+')
    if [ -z "$TUN_DEVS" ]; then
        log_msg "WARNING: No active tun interface found."
        return 0
    fi

    for dev in $TUN_DEVS; do
        # 1. tunX 的 Egress (root) 代表上传 -> 重定向到负责上传的 ifb1
        tc qdisc add dev $dev root handle 1: htb
        tc filter add dev $dev parent 1: protocol ip prio 1 u32 match u32 0 0 action mirred egress redirect dev ifb1
        
        # 2. tunX 的 Ingress 代表下载 -> 重定向到负责下载的 ifb0
        tc qdisc add dev $dev handle ffff: ingress
        tc filter add dev $dev parent ffff: protocol ip prio 1 u32 match u32 0 0 action mirred egress redirect dev ifb0
        
        log_msg "Successfully attached interface to shared pool: $dev"
        echo "Successfully attached interface to shared pool: $dev"
    done
}

stop() {
    log_msg "=== Stopping QoS Service ==="
    # 清理所有的 tc 规则
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
EOF
chmod +x "$INSTALL_DIR/qos_script.sh"

# ==========================================
# 3. 生成 /etc/init.d/qos 服务脚本
# ==========================================
echo "正在生成系统服务脚本: $INIT_SCRIPT ..."
cat << 'EOF' > "$INIT_SCRIPT"
#!/bin/sh /etc/rc.common

START=99
STOP=10

USE_PROCD=1
PROG="/opt/qos_deploy/qos_script.sh"

start_service() {
    procd_open_instance
    procd_set_param command /bin/sh $PROG start
    procd_set_param type oneshot
    procd_close_instance
}

stop_service() {
    /bin/sh $PROG stop
}

restart() {
    /bin/sh $PROG stop
    sleep 1
    /bin/sh $PROG start
}
EOF
chmod +x "$INIT_SCRIPT"

# ==========================================
# 4. 生成 Hotplug 自动发现和防抖脚本
# ==========================================
echo "正在生成 Hotplug 自动化脚本: $HOTPLUG_SCRIPT ..."
mkdir -p /etc/hotplug.d/iface
cat << 'EOF' > "$HOTPLUG_SCRIPT"
#!/bin/sh

LOCK_FILE="/var/run/qos_hotplug.lock"
DELAY_SECONDS="3"

if echo "$DEVICE" | grep -q "tun"; then
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
fi
EOF
chmod +x "$HOTPLUG_SCRIPT"

# ==========================================
# 5. 激活并启动新服务
# ==========================================
echo "正在激活并启动新版 QoS 限速系统..."
"$INIT_SCRIPT" enable
"$INIT_SCRIPT" restart

echo "=== 强制覆盖覆盖/升级部署完成 ==="
echo "提示：后续如需手动修改限速值，请编辑 '$CONF_FILE'，修改后执行 '/etc/init.d/qos restart' 生效。"
