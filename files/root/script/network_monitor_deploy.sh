#!/bin/sh
# ====================================================================
# SDWAN CPE 流量监控系统 一键全自动纯净/覆盖部署脚本 (双 IFB 专线聚合版)
# 适用环境：OpenWrt 21.02 / 22.03 / 23.05 +
# 优化策略：
#   1. 完全移除不可靠的单个 tun 接口和累加逻辑，由物理总线和虚拟中转池直算。
#   2. 完美对接 IFB 架构：监控 ifb0 的 TX 作为下载，ifb1 的 TX 作为上传。
#   3. GAUGE 模式高保真存储，彻底根治接口重启产生的数据溢出毛刺。
# ====================================================================

set -e

echo "========= [1/6] 正在执行旧版本残余清理及数据库重置 ========="

# 1. 安全从计划任务中剔除旧的采集器
if crontab -l 2>/dev/null | grep -q "traffic_collector.sh"; then
    echo "发现旧的计划任务标识，正在解除绑定..."
    crontab -l 2>/dev/null | grep -v "traffic_collector.sh" | crontab - || true
fi

# 2. 强制终止当前可能正在后台运行的旧版采集实例
killall traffic_collector.sh 2>/dev/null || true

# 3. 彻底清空历史安装路径及旧的前端残留文件
echo "正在强力抹除旧系统文件与 RRD 历史数据库..."
rm -rf /usr/share/traffic_rrd
rm -f /usr/bin/traffic_collector.sh
rm -f /www/cgi-bin/get_history_speed
rm -f /www/cgi-bin/get_net_speed
rm -rf /www/speed

echo "========= [2/6] 正在初始化全新环境及依赖环境校验 ========="
if ! command -v rrdtool >/dev/null 2>&1; then
    echo "未检测到 rrdtool，正在尝试从 opkg 软件源进行自动拉取安装..."
    opkg update
    opkg install rrdtool awk
else
    echo "RRDtool 环境检查正常，跳过安装。"
fi

# 4. 重新建立纯净的系统工作目录
mkdir -p /usr/share/traffic_rrd
mkdir -p /usr/bin
mkdir -p /www/cgi-bin
mkdir -p /www/speed

# ================= 架构检测核心变量定义 =================
ARCH_TYPE=$(uname -m)
GLOBAL_WAN="eth0"

case "$ARCH_TYPE" in
    x86_64|i386|i686)
        GLOBAL_WAN="eth0"
        ;;
    aarch64*|arm*|mips*)
        GLOBAL_WAN="eth1"
        ;;
    *)
        GLOBAL_WAN="eth0"
        ;;
esac
echo "系统底层架构为: $ARCH_TYPE，已选定专用 WAN 接口: $GLOBAL_WAN"
# =======================================================

echo "========= [3/6] 正在生成后台定时流量统计采集器 (traffic_collector.sh) ========="
cat << 'OUTER_EOF' > /usr/bin/traffic_collector.sh
#!/bin/sh
DB_DIR="/usr/share/traffic_rrd"
CACHE_DIR="/tmp/traffic_cache"
mkdir -p "$DB_DIR"
mkdir -p "$CACHE_DIR"

# 物理和核心局域网接口
INTERFACES="TARGET_WAN br-lan"

init_rrd() {
    local iface=$1
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
    local iface=$1
    awk -v ifn="$iface" '$1 ~ "^"ifn":" {print $2, $10}' /proc/net/dev
}

calc_speed() {
    local key=$1
    local current_rx=$2
    local current_tx=$3
    local cache_file="$CACHE_DIR/$key.cache"
    
    if [ -f "$cache_file" ]; then
        read -r last_time last_rx last_tx < "$cache_file"
        local now=$(date +%s)
        local time_delta=$((now - last_time))
        if [ $time_delta -gt 0 ] && [ $current_rx -ge $last_rx ] && [ $current_tx -ge $last_tx ]; then
            local rx_speed_scaled=$(( (current_rx - last_rx) * 8 * 100 / time_delta / 1024 / 1024 ))
            local tx_speed_scaled=$(( (current_tx - last_tx) * 8 * 100 / time_delta / 1024 / 1024 ))
            
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

# 初始化固定的三个监控数据库
for i in $INTERFACES TUN_TOTAL; do init_rrd "$i"; done

# 1. 采集标准物理和局域网网口
for iface in $INTERFACES; do
    stats=$(get_bytes "$iface")
    if [ -n "$stats" ]; then
        rx=$(echo "$stats" | awk '{print $1}')
        tx=$(echo "$stats" | awk '{print $2}')
        calc_speed "$iface" "$rx" "$tx"
        rrdtool update "$DB_DIR/$iface.rrd" N:"$rx_speed":"$tx_speed"
    fi
done

# 2. 采集双 IFB 中转池数据并精密合成为专线总流量
# ifb0 的 TX 代表所有 tun 的明文下载(Download/RX)
# ifb1 的 TX 代表所有 tun 的明文上传(Upload/TX)
ifb0_stats=$(get_bytes "ifb0")
ifb1_stats=$(get_bytes "ifb1")

# 兜底确保提取到数据，若未启动则赋予 0
ifb0_tx=$(echo "$ifb0_stats" | awk '{print $2}')
[ -z "$ifb0_tx" ] && ifb0_tx=0

ifb1_tx=$(echo "$ifb1_stats" | awk '{print $2}')
[ -z "$ifb1_tx" ] && ifb1_tx=0

# 利用两手数据换算并归档至专线库
calc_speed "TUN_TOTAL" "$ifb0_tx" "$ifb1_tx"
rrdtool update "$DB_DIR/TUN_TOTAL.rrd" N:"$rx_speed":"$tx_speed"
OUTER_EOF

# 精准替换采集器中的 WAN 接口标识
sed -i "s/TARGET_WAN/$GLOBAL_WAN/g" /usr/bin/traffic_collector.sh
chmod +x /usr/bin/traffic_collector.sh

echo "========= [4/6] 正在生成后端数据路由 CGI 接口服务 ========="
cat << 'OUTER_EOF' > /www/cgi-bin/get_history_speed
#!/bin/sh
echo "Content-type: application/json"
echo ""
TIME_RANGE="-1h"
RESOLUTION="60"
if [ -n "$QUERY_STRING" ]; then
    TIME_RANGE="-$(echo "$QUERY_STRING" | cut -d'&' -f1)"
    RESOLUTION="$(echo "$QUERY_STRING" | cut -d'&' -f2)"
fi
DB_DIR="/usr/share/traffic_rrd"
echo "{"
first=1
# 固定读取需要的三个 RRD 库文件
for iface in TUN_TOTAL TARGET_WAN br-lan; do
    f="$DB_DIR/$iface.rrd"
    [ -f "$f" ] || continue
    if [ $first -ne 1 ]; then echo ","; fi
    first=0
    echo "\"$iface\": ["
    rrdtool fetch "$f" AVERAGE -s "$TIME_RANGE" -e "now" -r "$RESOLUTION" | awk '
        NR > 2 {
            if ($1 != "") {
                sub(/:/, "", $1);
                val_rx = ($2 ~ /nan/) ? 0 : $2;
                val_tx = ($3 ~ /nan/) ? 0 : $3;
                printf "{\x22time\x22: \x22%s\x22, \x22rx\x22: %.2f, \x22tx\x22: %.2f},\n", $1, val_rx, val_tx
            }
        }
    ' | sed '$s/,$//'
    echo "]"
done
echo "}"
OUTER_EOF

cat << 'OUTER_EOF' > /www/cgi-bin/get_net_speed
#!/bin/sh
echo "Content-type: application/json"
echo ""
echo "{"
# 实时提取接口字节计数，将 ifb 处理逻辑融入前端或统一后端计算
awk 'NR > 2 {
    sub(/:/, "", $1);
    printf "\"%s\": {\"rx\": %s, \"tx\": %s},\n", $1, $2, $10
}' /proc/net/dev | sed '$s/,$//'
echo "}"
OUTER_EOF

chmod +x /www/cgi-bin/get_history_speed
chmod +x /www/cgi-bin/get_net_speed

echo "========= [5/6] 正在生成前端高阶主页面 (index.html) ========="
cat << 'OUTER_EOF' > /www/speed/index.html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <title>SDWAN CPE 流量监控系统</title>
    <script src="https://cdn.jsdelivr.net/npm/echarts@5.4.3/dist/echarts.min.js"></script>
    <style>
        :root {
            --bg-main: #0b111e; --bg-card: #121b2e; --border-color: #1e2d4a;
            --text-main: #f1f5f9; --text-muted: #64748b; --theme-blue: #38bdf8;
            --theme-green: #00e676; --theme-red: #ff3d00;
        }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background-color: var(--bg-main); color: var(--text-main); padding: 30px; margin: 0; -webkit-font-smoothing: antialiased; }
        .container { max-width: 1400px; margin: 0 auto; }
        .login-overlay { position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: var(--bg-main); z-index: 9999; display: flex; justify-content: center; align-items: center; }
        .login-box { background: var(--bg-card); border: 1px solid var(--border-color); padding: 40px; border-radius: 12px; width: 320px; text-align: center; box-shadow: 0 20px 50px rgba(0,0,0,0.5); }
        .login-box h2 { margin-top: 0; font-size: 1.3rem; color: var(--theme-blue); margin-bottom: 25px; font-weight: 600; }
        .login-box input { width: 100%; padding: 11px; margin-bottom: 15px; border-radius: 6px; box-sizing: border-box; border: 1px solid var(--border-color); background: #16223b; color: #fff; outline: none; }
        .login-box button { width: 100%; background: var(--theme-blue); color: #0b111e; font-weight: bold; border: none; padding: 11px; border-radius: 6px; cursor: pointer; transition: 0.2s; }
        .login-box button:hover { background: #0ea5e9; }
        .header-panel { text-align: center; margin-bottom: 25px; }
        h1 { font-size: 2.2rem; font-weight: 700; letter-spacing: 1px; background: linear-gradient(to right, #38bdf8, #00e676); -webkit-background-clip: text; -webkit-text-fill-color: transparent; margin: 0; }
        .navigation-tabs { display: flex; justify-content: center; gap: 8px; margin-bottom: 25px; }
        .nav-tab { background: #16223b; color: var(--text-muted); border: 1px solid var(--border-color); padding: 10px 24px; font-size: 0.95rem; font-weight: 600; border-radius: 6px; cursor: pointer; transition: 0.2s; }
        .nav-tab:hover { color: var(--text-main); }
        .nav-tab.active { background: #1e2d4a; color: var(--theme-green); border-color: var(--theme-green); box-shadow: 0 4px 15px rgba(0,230,118,0.15); }
        .btn-wrapper { text-align: center; width: 100%; margin-bottom: 30px; display: none; }
        .control-row { display: inline-flex; gap: 4px; background: var(--bg-card); border: 1px solid var(--border-color); padding: 5px; border-radius: 8px; box-shadow: 0 8px 24px rgba(0, 0, 0, 0.3); flex-wrap: wrap; justify-content: center; }
        .control-row button { background: transparent; border: none; color: var(--text-muted); padding: 8px 14px; font-size: 0.85rem; font-weight: 500; border-radius: 5px; cursor: pointer; }
        .control-row button:hover { color: var(--text-main); }
        .control-row button.active { background: #1e2d4a; color: var(--theme-blue); font-weight: 600; }
        .chart-grid { display: grid; grid-template-columns: 1fr; gap: 25px; }
        .chart-card { background: var(--bg-card); border: 1px solid var(--border-color); border-radius: 12px; padding: 24px; height: 380px; box-shadow: 0 10px 30px rgba(0, 0, 0, 0.2); }
        #realtime-grid { display: grid; } #history-grid { display: none; }
    </style>
</head>
<body>
    <div class="login-overlay" id="loginWall">
        <div class="login-box">
            <h2>SDWAN CPE 网络流量监控</h2>
            <input type="text" id="username" placeholder="管理员账号" onkeydown="handleKeyDown(event)">
            <input type="password" id="password" placeholder="访问密码" onkeydown="handleKeyDown(event)">
            <button onclick="checkLogin()">安全登录</button>
            <p id="loginErr" style="color:var(--theme-red); font-size:0.85rem; margin-top:15px; display:none; font-weight:500;">凭据错误，拒绝访问</p>
        </div>
    </div>
    <div class="container">
        <div class="header-panel"><h1>SDWAN CPE流量监控</h1></div>
        <div class="navigation-tabs">
            <div class="nav-tab active" id="tab-realtime" onclick="switchMode('realtime')">实时网络监控</div>
            <div class="nav-tab" id="tab-history" onclick="switchMode('history')">历史网络查看</div>
        </div>
        <div class="btn-wrapper" id="history-controls">
            <div class="control-row">
                <button onclick="changeHistoryRange('30m', 60, this)">30分钟</button>
                <button class="active" onclick="changeHistoryRange('1h', 60, this)">1小时</button>
                <button onclick="changeHistoryRange('6h', 60, this)">6小时</button>
                <button onclick="changeHistoryRange('12h', 60, this)">12小时</button>
                <button onclick="changeHistoryRange('24h', 60, this)">24小时</button>
                <button onclick="changeHistoryRange('2d', 60, this)">2天</button>
                <button onclick="changeHistoryRange('7d', 300, this)">7天</button>
                <button onclick="changeHistoryRange('15d', 300, this)">15天</button>
                <button onclick="changeHistoryRange('30d', 300, this)">1个月</button>
                <button onclick="changeHistoryRange('90d', 1800, this)">3个月</button>
                <button onclick="changeHistoryRange('180d', 1800, this)">6个月</button>
                <button onclick="changeHistoryRange('365d', 7200, this)">1年</button>
            </div>
        </div>
        <div class="chart-grid" id="realtime-grid"></div>
        <div class="chart-grid" id="history-grid"></div>
    </div>
    <script>
        function handleKeyDown(event) { if (event.key === "Enter" || event.keyCode === 13) { checkLogin(); } }
        function checkLogin() {
            const u = document.getElementById('username').value; const p = document.getElementById('password').value;
            if(u === "admin" && p === "admin888") { sessionStorage.setItem("cpe_auth", "passed"); document.getElementById('loginWall').style.display = 'none'; initSystem(); } else { document.getElementById('loginErr').style.display = 'block'; }
        }
        if(sessionStorage.getItem("cpe_auth") === "passed") { document.getElementById('loginWall').style.display = 'none'; window.onload = initSystem; }
        let appMode = 'realtime'; let currentRange = '1h'; let currentResolution = 60; let realtimeCharts = {}; let historyCharts = {}; let realtimeTimer = null; let historyTimer = null; let previousStats = {}; let previousTime = Date.now();
        
        const nameMapping = { 'TUN_TOTAL': 'SDWAN专线流量图', 'TARGET_WAN': 'WAN口流量图', 'br-lan': 'LAN口流量图' };
        const orderedInterfaces = ['TUN_TOTAL', 'TARGET_WAN', 'br-lan'];

        function initSystem() { 
            // 纯净初始化：固定生成三个卡片容器
            const rtGrid = document.getElementById('realtime-grid');
            const hiGrid = document.getElementById('history-grid');
            rtGrid.innerHTML = ''; hiGrid.innerHTML = '';
            
            orderedInterfaces.forEach(iface => {
                const cardRt = document.createElement('div'); cardRt.className = 'chart-card'; cardRt.id = `rt-chart-${iface}`; rtGrid.appendChild(cardRt);
                realtimeCharts[iface] = echarts.init(cardRt, 'dark');
                realtimeCharts[iface].timeline = new Array(30).fill(''); realtimeCharts[iface].rxTrack = new Array(30).fill(0); realtimeCharts[iface].txTrack = new Array(30).fill(0);
                
                const cardHi = document.createElement('div'); cardHi.className = 'chart-card'; cardHi.id = `hi-chart-${iface}`; hiGrid.appendChild(cardHi);
                historyCharts[iface] = echarts.init(cardHi, 'dark');
            });

            switchMode('realtime'); 
            realtimeTimer = setInterval(loadRealtimeData, 2000); 
            historyTimer = setInterval(loadHistoryData, 30000); 
        }

        function switchMode(mode) {
            appMode = mode; document.getElementById('tab-realtime').classList.remove('active'); document.getElementById('tab-history').classList.remove('active');
            if(mode === 'realtime') {
                document.getElementById('tab-realtime').classList.add('active'); document.getElementById('history-controls').style.display = 'none'; document.getElementById('history-grid').style.display = 'none'; document.getElementById('realtime-grid').style.display = 'grid';
                for (let k in realtimeCharts) { realtimeCharts[k].resize(); } loadRealtimeData();
            } else {
                document.getElementById('tab-history').classList.add('active'); document.getElementById('history-controls').style.display = 'block'; document.getElementById('realtime-grid').style.display = 'none'; document.getElementById('history-grid').style.display = 'grid';
                for (let k in historyCharts) { historyCharts[k].resize(); } loadHistoryData();
            }
        }

        async function loadRealtimeData() {
            try {
                const res = await fetch('/cgi-bin/get_net_speed'); const currentStats = await res.json(); 
                const now = Date.now(); const timeDelta = (now - previousTime) / 1000 || 1; previousTime = now;
                
                orderedInterfaces.forEach(iface => {
                    let rxMbps = 0, txMbps = 0;
                    if (iface === 'TUN_TOTAL') {
                        // 核心重构：专线下载取决于 ifb0 的 TX；专线上传取决于 ifb1 的 TX
                        const curIfb0 = currentStats['ifb0'] || {tx:0}; const prvIfb0 = previousStats['ifb0'] || curIfb0;
                        const curIfb1 = currentStats['ifb1'] || {tx:0}; const prvIfb1 = previousStats['ifb1'] || curIfb1;
                        rxMbps = parseFloat((((curIfb0.tx - prvIfb0.tx) * 8 / timeDelta) / 1024 / 1024).toFixed(2));
                        txMbps = parseFloat((((curIfb1.tx - prvIfb1.tx) * 8 / timeDelta) / 1024 / 1024).toFixed(2));
                    } else {
                        const current = currentStats[iface] || {rx:0, tx:0}; const prev = previousStats[iface] || current;
                        rxMbps = parseFloat((((current.rx - prev.rx) * 8 / timeDelta) / 1024 / 1024).toFixed(2)); 
                        txMbps = parseFloat((((current.tx - prev.tx) * 8 / timeDelta) / 1024 / 1024).toFixed(2));
                    }
                    if (rxMbps < 0 || isNaN(rxMbps)) rxMbps = 0; if (txMbps < 0 || isNaN(txMbps)) txMbps = 0;
                    
                    const c = realtimeCharts[iface]; const timeStr = new Date().toLocaleTimeString([], {hour: '2-digit', minute:'2-digit', second:'2-digit'});
                    c.timeline.shift(); c.timeline.push(timeStr); c.rxTrack.shift(); c.rxTrack.push(rxMbps); c.txTrack.shift(); c.txTrack.push(txMbps);
                    renderEChart(realtimeCharts[iface], iface, c.timeline, c.rxTrack, c.txTrack, true);
                });
                previousStats = currentStats;
            } catch (e) { console.error(e); }
        }

        async function loadHistoryData() {
            try {
                const response = await fetch(`/cgi-bin/get_history_speed?${currentRange}&${currentResolution}`); const data = await response.json();
                orderedInterfaces.forEach(iface => {
                    const records = data[iface] || [];
                    const labels = records.map(r => { let d = new Date(parseInt(r.time.replace(':', '')) * 1000); return currentResolution >= 300 ? `${d.getMonth()+1}-${d.getDate()} ${d.getHours()}:${(d.getMinutes()<10?'0':'')+d.getMinutes()}` : d.toLocaleTimeString([], {hour: '2-digit', minute:'2-digit'}); });
                    const rxData = records.map(r => r.rx); const txData = records.map(r => r.tx);
                    renderEChart(historyCharts[iface], iface, labels, rxData, txData, false);
                });
            } catch (e) { console.error(e); }
        }

        function changeHistoryRange(range, resolution, btn) { currentRange = range; currentResolution = resolution; document.querySelectorAll('.control-row button').forEach(b => b.classList.remove('active')); btn.classList.add('active'); loadHistoryData(); }
        
        function renderEChart(chartInstance, iface, labels, rx, tx, isSmooth) {
            let labelName = nameMapping[iface] || iface;
            chartInstance.setOption({
                backgroundColor: 'transparent', title: { text: labelName, left: 'center', top: 5, textStyle: { color: '#f1f5f9', fontSize: 16, fontWeight: 'bold' } },
                tooltip: { trigger: 'axis', backgroundColor: 'rgba(18, 27, 46, 0.95)', borderColor: '#1e2d4a', textStyle: { color: '#f1f5f9' }, boxShadow: '0 8px 32px rgba(0,0,0,0.3)' },
                legend: { data: ['下载 (RX)', '上行 (TX)'], bottom: 5, textStyle: { color: '#64748b', fontWeight: 500 } },
                grid: { top: 70, bottom: 65, left: 65, right: 30 },
                xAxis: { 
                    type: 'category', boundaryGap: false, data: labels, 
                    axisLine: { lineStyle: { color: '#94a3b8', width: 2 } }, axisLabel: { color: '#64748b' } 
                },
                yAxis: { 
                    type: 'value', name: 'Mbps', nameTextStyle: { color: '#64748b' }, 
                    splitLine: { show: true, lineStyle: { color: 'rgba(148, 163, 184, 0.35)', type: 'solid', width: 1.5 } }, 
                    axisLine: { show: true, lineStyle: { color: '#94a3b8', width: 2 } }, axisLabel: { color: '#64748b' }, minInterval: 0.5 
                },
                series: [
                    { name: '下载 (RX)', type: 'line', smooth: isSmooth, showSymbol: false, itemStyle: { color: '#00e676' }, lineStyle: { width: 2 }, areaStyle: { color: new echarts.graphic.LinearGradient(0, 0, 0, 1, [{ offset: 0, color: 'rgba(0, 230, 118, 0.15)' }, { offset: 1, color: 'rgba(0, 230, 118, 0.0)' }]) }, data: rx },
                    { name: '上行 (TX)', type: 'line', smooth: isSmooth, showSymbol: false, itemStyle: { color: '#ff3d00' }, lineStyle: { width: 2 }, areaStyle: { color: new echarts.graphic.LinearGradient(0, 0, 0, 1, [{ offset: 0, color: 'rgba(255, 61, 0, 0.1)' }, { offset: 1, color: 'rgba(255, 61, 0, 0.0)' }]) }, data: tx }
                ]
            });
        }
        window.addEventListener('resize', () => { for (let k in realtimeCharts) realtimeCharts[k].resize(); for (let k in historyCharts) historyCharts[k].resize(); });
    </script>
</body>
</html>
OUTER_EOF

# 精准替换网页中的 WAN 接口动态映射
sed -i "s/TARGET_WAN/$GLOBAL_WAN/g" /www/speed/index.html

echo "========= [6/6] 正在向 OpenWrt 重新注册内核级高频计划任务模块 ========="
# 重新将纯净的采集指令挂载入宿主机 Crontab
(crontab -l 2>/dev/null; echo "* * * * * /usr/bin/traffic_collector.sh") | crontab -

# 强制重启系统的 cron 计划任务引擎，确保立刻生效
/etc/init.d/cron restart

# 运行初始化采集
sh /usr/bin/traffic_collector.sh

echo "===================================================================="
echo " 恭喜！基于双 IFB 的精简专线监控系统已全自动升级覆盖部署完成！"
echo "--------------------------------------------------------------------"
echo " 访问地址 : http://[你的路由器IP]/speed/"
echo "===================================================================="
