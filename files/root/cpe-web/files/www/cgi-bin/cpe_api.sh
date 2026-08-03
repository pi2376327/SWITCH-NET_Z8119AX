#!/bin/sh
USERS_FILE="/etc/cpe_users"
SESSIONS_FILE="/tmp/cpe_sessions"
IPTABLES_CONF="/etc/config/cpe_iptables.json"
IPTABLES_SH="/etc/cpe_iptables.sh"
IPTABLES_LEGACY="/etc/cpe_iptables"
LOGIN_BG_CONF="/etc/config/cpe_login_bg"
SESSION_TTL=86400

json_header() {
    echo "Content-type: application/json"
    echo ""
}

text_header() {
    echo "Content-type: text/plain"
    echo ""
}

read_body() {
    [ -n "$CONTENT_LENGTH" ] && head -c "$CONTENT_LENGTH" || true
}

urldecode() {
    local data
    data=$(echo "$1" | sed 's/+/ /g')
    printf '%b' "$(echo "$data" | sed 's/%/\\x/g')"
}

form_value() {
    local body="$1"
    local key="$2"
    echo "$body" | tr '&' '\n' | awk -F= -v k="$key" '$1==k {print substr($0, length(k)+2); exit}' | while read -r v; do urldecode "$v"; done
}

query_value() {
    local key="$1"
    echo "$QUERY_STRING" | tr '&' '\n' | awk -F= -v k="$key" '$1==k {print substr($0, length(k)+2); exit}' | while read -r v; do urldecode "$v"; done
}

safe_abs_file() {
    case "$1" in
        /*) ;;
        *) return 1 ;;
    esac
    case "$1" in *..*|*'//'*) return 1 ;; esac
    echo "$1" | grep -Eq '^[A-Za-z0-9_./:@%+=,-]+$' || return 1
    [ -f "$1" ] || return 1
    return 0
}

safe_abs_path() {
    case "$1" in
        /*) ;;
        *) return 1 ;;
    esac
    case "$1" in *..*|*'//'*) return 1 ;; esac
    echo "$1" | grep -Eq '^[A-Za-z0-9_./:@%+=,-]+$' || return 1
    return 0
}

openvpn_account_exists() {
    [ -f /etc/openvpn/psw-file ] || return 1
    awk -v user="$1" '$1 == user {found=1} END {exit found ? 0 : 1}' /etc/openvpn/psw-file
}

rand_token() {
    tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 40
}

make_salt() {
    (date +%s; cat /proc/sys/kernel/random/uuid 2>/dev/null; echo $$) | sha256sum | awk '{print substr($1,1,16)}'
}

hash_pwd() {
    local salt="$1"
    local pwd="$2"
    printf '%s' "$salt:$pwd" | sha256sum | awk '{print $1}'
}

ensure_users_file() {
    if [ ! -f "$USERS_FILE" ]; then
        salt=$(make_salt)
        hash=$(hash_pwd "$salt" "admin888")
        umask 077
        echo "admin|$salt|$hash|admin" > "$USERS_FILE"
    fi
    chmod 600 "$USERS_FILE" 2>/dev/null || true
}

json_escape() {
    echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

valid_uci_target() {
    echo "$1" | grep -Eq '^(network|dhcp|wireless)(\.[A-Za-z0-9_@:-]+){0,2}$'
}

valid_uci_package() {
    case "$1" in
        network|dhcp|wireless) return 0 ;;
        *) return 1 ;;
    esac
}

uci_unquote_value() {
    printf '%s' "$1" | sed -e "s/^'//" -e "s/'$//" -e 's/^"//' -e 's/"$//'
}

run_uci_batch() {
    local scope="$1"
    local tmp="/tmp/cpe_uci_batch.$$"
    local line arg key val pkg

    read_body > "$tmp"
    while IFS= read -r line || [ -n "$line" ]; do
        line=$(printf '%s' "$line" | tr -d '\r')
        [ -z "$line" ] && continue
        case "$line" in
            "uci set "*)
                arg=${line#uci set }
                key=${arg%%=*}
                val=${arg#*=}
                [ "$arg" != "$key" ] || { rm -f "$tmp"; return 1; }
                valid_uci_target "$key" || { rm -f "$tmp"; return 1; }
                case "$key" in "$scope"|"$scope".*) ;; *) rm -f "$tmp"; return 1 ;; esac
                val=$(uci_unquote_value "$val")
                uci set "$key=$val" || { rm -f "$tmp"; return 1; }
                ;;
            "uci delete "*)
                key=${line#uci delete }
                valid_uci_target "$key" || { rm -f "$tmp"; return 1; }
                case "$key" in "$scope"|"$scope".*) ;; *) rm -f "$tmp"; return 1 ;; esac
                uci -q delete "$key" || true
                ;;
            "uci add_list "*)
                arg=${line#uci add_list }
                key=${arg%%=*}
                val=${arg#*=}
                [ "$arg" != "$key" ] || { rm -f "$tmp"; return 1; }
                valid_uci_target "$key" || { rm -f "$tmp"; return 1; }
                case "$key" in "$scope"|"$scope".*) ;; *) rm -f "$tmp"; return 1 ;; esac
                val=$(uci_unquote_value "$val")
                uci add_list "$key=$val" || { rm -f "$tmp"; return 1; }
                ;;
            "uci commit "*)
                pkg=${line#uci commit }
                valid_uci_package "$pkg" || { rm -f "$tmp"; return 1; }
                case "$pkg" in "$scope") ;; *) rm -f "$tmp"; return 1 ;; esac
                uci commit "$pkg" || { rm -f "$tmp"; return 1; }
                ;;
            *)
                rm -f "$tmp"
                return 1
                ;;
        esac
    done < "$tmp"
    rm -f "$tmp"
    return 0
}

run_wifi_iface_batch() {
    local tmp="/tmp/cpe_wifi_batch.$$"
    local line arg key val section pkg

    read_body > "$tmp"
    while IFS= read -r line || [ -n "$line" ]; do
        line=$(printf '%s' "$line" | tr -d '\r')
        [ -z "$line" ] && continue
        case "$line" in
            "uci set wireless."*)
                arg=${line#uci set }
                key=${arg%%=*}
                val=${arg#*=}
                [ "$arg" != "$key" ] || { rm -f "$tmp"; return 1; }
                valid_uci_target "$key" || { rm -f "$tmp"; return 1; }
                section=${key#wireless.}
                section=${section%%.*}
                [ "$(uci -q get wireless.$section)" = "wifi-iface" ] || { rm -f "$tmp"; return 1; }
                val=$(uci_unquote_value "$val")
                uci set "$key=$val" || { rm -f "$tmp"; return 1; }
                ;;
            "uci delete wireless."*)
                key=${line#uci delete }
                valid_uci_target "$key" || { rm -f "$tmp"; return 1; }
                section=${key#wireless.}
                case "$section" in *.*) section=${section%%.*} ;; *) rm -f "$tmp"; return 1 ;; esac
                [ "$(uci -q get wireless.$section)" = "wifi-iface" ] || { rm -f "$tmp"; return 1; }
                uci -q delete "$key" || true
                ;;
            "uci add_list wireless."*)
                arg=${line#uci add_list }
                key=${arg%%=*}
                val=${arg#*=}
                [ "$arg" != "$key" ] || { rm -f "$tmp"; return 1; }
                valid_uci_target "$key" || { rm -f "$tmp"; return 1; }
                section=${key#wireless.}
                section=${section%%.*}
                [ "$(uci -q get wireless.$section)" = "wifi-iface" ] || { rm -f "$tmp"; return 1; }
                val=$(uci_unquote_value "$val")
                uci add_list "$key=$val" || { rm -f "$tmp"; return 1; }
                ;;
            "uci commit wireless")
                uci commit wireless || { rm -f "$tmp"; return 1; }
                ;;
            *)
                rm -f "$tmp"
                return 1
                ;;
        esac
    done < "$tmp"
    rm -f "$tmp"
    return 0
}

verify_user() {
    local u="$1"
    local p="$2"
    local line role salt hash calc
    line=$(awk -F'|' -v u="$u" '$1==u {print; exit}' "$USERS_FILE")
    [ -n "$line" ] || return 1

    fields=$(echo "$line" | awk -F'|' '{print NF}')
    if [ "$fields" = "4" ]; then
        salt=$(echo "$line" | cut -d'|' -f2)
        hash=$(echo "$line" | cut -d'|' -f3)
        role=$(echo "$line" | cut -d'|' -f4)
        calc=$(hash_pwd "$salt" "$p")
        [ "$calc" = "$hash" ] || return 1
        AUTH_USER="$u"
        AUTH_ROLE="$role"
        return 0
    fi

    oldp=$(echo "$line" | cut -d'|' -f2)
    role=$(echo "$line" | cut -d'|' -f3)
    [ "$p" = "$oldp" ] || return 1
    set_user "$u" "$p" "$role"
    AUTH_USER="$u"
    AUTH_ROLE="$role"
    return 0
}

set_user() {
    local u="$1"
    local p="$2"
    local r="$3"
    local salt hash tmp
    echo "$u" | grep -Eq '^[A-Za-z0-9_.-]{1,32}$' || return 1
    [ "$r" = "admin" ] || r="user"
    salt=$(make_salt)
    hash=$(hash_pwd "$salt" "$p")
    tmp="/tmp/cpe_users.$$"
    grep -v "^${u}|" "$USERS_FILE" > "$tmp" 2>/dev/null || true
    echo "${u}|${salt}|${hash}|${r}" >> "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$USERS_FILE"
}

cleanup_sessions() {
    tmp="/tmp/cpe_sessions.$$"
    now=$(date +%s)
    [ -f "$SESSIONS_FILE" ] || return 0
    awk -F'|' -v now="$now" '$4 > now' "$SESSIONS_FILE" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$SESSIONS_FILE"
    chmod 600 "$SESSIONS_FILE" 2>/dev/null || true
}

create_session() {
    local u="$1"
    local r="$2"
    local token exp
    cleanup_sessions
    token=$(rand_token)
    [ -n "$token" ] || token="$(date +%s)$$"
    exp=$(( $(date +%s) + SESSION_TTL ))
    umask 077
    echo "$token|$u|$r|$exp" >> "$SESSIONS_FILE"
    echo "$token"
}

require_auth() {
    cleanup_sessions
    CPE_TOKEN="$HTTP_X_CPE_TOKEN"
    [ -n "$CPE_TOKEN" ] || CPE_TOKEN=$(echo "$QUERY_STRING" | grep -o 'token=[^&]*' | cut -d= -f2)
    [ -n "$CPE_TOKEN" ] || CPE_TOKEN=$(echo "$QUERY_STRING" | grep -o '_cpe_token=[^&]*' | cut -d= -f2)
    [ -n "$CPE_TOKEN" ] || return 1
    session=$(awk -F'|' -v t="$CPE_TOKEN" '$1==t {print; exit}' "$SESSIONS_FILE" 2>/dev/null)
    [ -n "$session" ] || return 1
    AUTH_USER=$(echo "$session" | cut -d'|' -f2)
    AUTH_ROLE=$(echo "$session" | cut -d'|' -f3)
    new_exp=$(( $(date +%s) + SESSION_TTL ))
    tmp="/tmp/cpe_sessions.$$"
    awk -F'|' -v t="$CPE_TOKEN" -v exp="$new_exp" 'BEGIN{OFS=FS} $1==t {$4=exp} {print}' "$SESSIONS_FILE" > "$tmp" 2>/dev/null && mv "$tmp" "$SESSIONS_FILE"
    chmod 600 "$SESSIONS_FILE" 2>/dev/null || true
    return 0
}

require_admin() {
    [ "$AUTH_ROLE" = "admin" ]
}

ACTION=$(echo "$QUERY_STRING" | grep -o 'action=[^&]*' | cut -d= -f2)
ensure_users_file

case "$ACTION" in
    "get_login_bg")
        json_header
        if [ -f "$LOGIN_BG_CONF" ]; then
            path=$(cat "$LOGIN_BG_CONF" 2>/dev/null)
            ep=$(json_escape "$path")
            echo "{\"status\":\"ok\",\"path\":\"$ep\"}"
        else
            echo '{"status":"ok","path":""}'
        fi
        ;;
    "login")
        body=$(read_body)
        u=$(form_value "$body" "u")
        p=$(form_value "$body" "p")
        json_header
        if verify_user "$u" "$p"; then
            token=$(create_session "$AUTH_USER" "$AUTH_ROLE")
            echo "{\"status\":\"ok\",\"role\":\"$AUTH_ROLE\",\"token\":\"$token\"}"
        else
            echo "{\"status\":\"error\"}"
        fi
        ;;
    "logout")
        require_auth || { json_header; echo '{"status":"ok"}'; exit 0; }
        tmp="/tmp/cpe_sessions.$$"
        grep -v "^${CPE_TOKEN}|" "$SESSIONS_FILE" > "$tmp" 2>/dev/null || true
        mv "$tmp" "$SESSIONS_FILE"
        json_header
        echo '{"status":"ok"}'
        ;;
    *)
        if ! require_auth; then
            json_header
            echo '{"status":"error","msg":"unauthorized"}'
            exit 0
        fi
        case "$ACTION" in
            "get_users")
                json_header
                if require_admin; then
                    echo "["
                    awk -F'|' '{printf "%s{\"username\":\"%s\",\"role\":\"%s\"}", sep, $1, (NF==4?$4:$3); sep=","}' "$USERS_FILE"
                    echo "]"
                else
                    role=$(awk -F'|' -v u="$AUTH_USER" '$1==u {print (NF==4?$4:$3); exit}' "$USERS_FILE")
                    eu=$(json_escape "$AUTH_USER")
                    echo "[{\"username\":\"$eu\",\"role\":\"$role\"}]"
                fi
                ;;
            "add_user")
                require_admin || { json_header; echo '{"status":"error","msg":"forbidden"}'; exit 0; }
                body=$(read_body)
                u=$(form_value "$body" "u")
                p=$(form_value "$body" "p")
                r=$(form_value "$body" "r")
                json_header
                if [ -n "$u" ] && [ -n "$p" ] && set_user "$u" "$p" "$r"; then
                    echo '{"status":"ok"}'
                else
                    echo '{"status":"error","msg":"invalid user"}'
                fi
                ;;
            "del_user")
                require_admin || { json_header; echo '{"status":"error","msg":"forbidden"}'; exit 0; }
                body=$(read_body)
                u=$(form_value "$body" "u")
                json_header
                if [ "$u" = "admin" ]; then
                    echo '{"status":"error","msg":"admin cannot be deleted"}'
                else
                    grep -v "^${u}|" "$USERS_FILE" > /tmp/users.tmp
                    chmod 600 /tmp/users.tmp
                    mv /tmp/users.tmp "$USERS_FILE"
                    echo '{"status":"ok"}'
                fi
                ;;
            "update_pwd")
                body=$(read_body)
                u=$(form_value "$body" "u")
                oldp=$(form_value "$body" "oldp")
                newp=$(form_value "$body" "newp")
                json_header
                if [ "$u" != "$AUTH_USER" ] && ! require_admin; then
                    echo '{"status":"error","msg":"forbidden"}'
                elif verify_user "$u" "$oldp" && [ -n "$newp" ]; then
                    set_user "$u" "$newp" "$AUTH_ROLE"
                    echo '{"status":"ok"}'
                else
                    echo '{"status":"error"}'
                fi
                ;;
            "get_interfaces")
                require_admin || { json_header; echo '{"status":"error","msg":"forbidden"}'; exit 0; }
                json_header
                echo "{"
                {
                    ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | awk '{print $1 "|"}'
                    ip -o -f inet addr show 2>/dev/null | awk '{ifn=$2; sub(/:/,"",ifn); print ifn "|" $4}'
                } | awk -F'|' '
                    $1 != "lo" && $1 != "" {
                        if (!seen[$1]++) order[++n]=$1;
                        if ($2 != "") ip[$1]=$2;
                    }
                    END {
                        for (i=1; i<=n; i++) {
                            name=order[i];
                            printf "%s\"%s\":\"%s\"", sep, name, ip[name];
                            sep=",";
                        }
                    }'
                echo "}"
                ;;
            "get_devices")
                require_admin || { json_header; echo '{"status":"error","msg":"forbidden"}'; exit 0; }
                json_header
                printf '['
                ip -o link show 2>/dev/null | awk -F': ' '
                    {
                        name=$2;
                        sub(/@.*/, "", name);
                        sub(/[[:space:]].*/, "", name);
                        if (name != "lo" && name != "") {
                            printf "%s\"%s\"", sep, name;
                            sep=",";
                        }
                    }'
                printf ']'
                ;;
            "get_iptables")
                require_admin || { json_header; echo '{"status":"error","msg":"forbidden"}'; exit 0; }
                json_header
                cat "$IPTABLES_CONF" 2>/dev/null || echo "[]"
                ;;
            "set_iptables_ui")
                require_admin || { json_header; echo '{"status":"error","msg":"forbidden"}'; exit 0; }
                read_body > "$IPTABLES_CONF"
                chmod 600 "$IPTABLES_CONF" 2>/dev/null || true
                json_header
                echo '{"status":"ok"}'
                ;;
            "set_iptables_sh")
                require_admin || { json_header; echo '{"status":"error","msg":"forbidden"}'; exit 0; }
                body=$(read_body)
                if echo "$body" | grep -Ev '^(iptables[[:space:]]+-t[[:space:]]+(nat|filter)[[:space:]]+-A[[:space:]]+(PREROUTING|OUTPUT|FORWARD)[[:space:]].*|[[:space:]]*)$' >/dev/null; then
                    json_header
                    echo '{"status":"error","msg":"invalid iptables rule"}'
                    exit 0
                fi
                cat << 'EOF' > "$IPTABLES_SH"
#!/bin/sh
# Auto-generated by CPE Web Admin

iptables -t nat -N CPE_PRE 2>/dev/null || true
iptables -t nat -N CPE_OUT 2>/dev/null || true
iptables -t filter -N CPE_FWD 2>/dev/null || true

iptables -t nat -F CPE_PRE
iptables -t nat -F CPE_OUT
iptables -t filter -F CPE_FWD

iptables -t nat -C PREROUTING -j CPE_PRE 2>/dev/null || iptables -t nat -I PREROUTING 1 -j CPE_PRE
iptables -t nat -C OUTPUT -j CPE_OUT 2>/dev/null || iptables -t nat -I OUTPUT 1 -j CPE_OUT
iptables -t filter -C FORWARD -j CPE_FWD 2>/dev/null || iptables -t filter -I FORWARD 1 -j CPE_FWD
EOF
                echo "$body" | sed -e 's/-A PREROUTING/-A CPE_PRE/g' \
                                   -e 's/-A OUTPUT/-A CPE_OUT/g' \
                                   -e 's/-A FORWARD/-A CPE_FWD/g' >> "$IPTABLES_SH"
                chmod 700 "$IPTABLES_SH"
                cp "$IPTABLES_SH" "$IPTABLES_LEGACY" 2>/dev/null || true
                chmod 700 "$IPTABLES_LEGACY" 2>/dev/null || true
                if ! grep -q "path '/etc/cpe_iptables.sh'" /etc/config/firewall 2>/dev/null; then
                    echo "config include" >> /etc/config/firewall
                    echo "	option path '/etc/cpe_iptables.sh'" >> /etc/config/firewall
                fi
                /etc/init.d/firewall restart >/dev/null 2>&1 &
                json_header
                echo '{"status":"ok"}'
                ;;
            "get_qos")
                require_admin || { json_header; echo '{"status":"error","msg":"forbidden"}'; exit 0; }
                json_header
                enabled=$(uci -q get qos.global.enabled || echo 1)
                download=$(uci -q get qos.global.download || echo 10240)
                upload=$(uci -q get qos.global.upload || echo 10240)
                qos_tuns=$(awk -F': ' '/Successfully attached interface to shared pool/ {print $NF}' /var/log/qos.log 2>/dev/null | tail -n 30 | sort -u | grep -v '^tun10$' | tr '\n' ' ')
                [ -n "$qos_tuns" ] || qos_tuns=$(ip link show 2>/dev/null | grep -oE 'tun[0-9]+' | grep -v '^tun10$' | sort -u | tr '\n' ' ')
                qos_tuns=$(json_escape "$qos_tuns")
                echo "{\"status\":\"ok\",\"enabled\":\"$enabled\",\"download\":\"$download\",\"upload\":\"$upload\",\"tuns\":\"$qos_tuns\"}"
                ;;
            "set_qos")
                require_admin || { json_header; echo '{"status":"error","msg":"forbidden"}'; exit 0; }
                body=$(read_body)
                enabled=$(form_value "$body" "enabled")
                download=$(form_value "$body" "download")
                upload=$(form_value "$body" "upload")
                json_header
                case "$enabled" in 0|1) ;; *) echo '{"status":"error","msg":"enabled invalid"}'; exit 0 ;; esac
                echo "$download" | grep -Eq '^[0-9]{1,9}$' || { echo '{"status":"error","msg":"download invalid"}'; exit 0; }
                echo "$upload" | grep -Eq '^[0-9]{1,9}$' || { echo '{"status":"error","msg":"upload invalid"}'; exit 0; }
                uci -q get qos.global >/dev/null 2>&1 || uci set qos.global=qos
                uci set qos.global.enabled="$enabled"
                uci set qos.global.download="$download"
                uci set qos.global.upload="$upload"
                uci commit qos
                /etc/init.d/qos restart >/dev/null 2>&1 </dev/null &
                echo '{"status":"ok"}'
                ;;
            "get_basic")
                require_admin || { json_header; echo '{"status":"error","msg":"forbidden"}'; exit 0; }
                json_header
                rid=$(uci -q get rtty.@rtty[0].id || echo Default)
                rdesc=$(uci -q get rtty.@rtty[0].description || echo SWITCH_Z8119AX)
                rhost=$(uci -q get rtty.@rtty[0].host || echo rtty.switch-net.com)
                rport=$(uci -q get rtty.@rtty[0].port || echo 5912)
                rtoken=$(uci -q get rtty.@rtty[0].token || echo switch-net.com)
                zhost=$(awk -F= '$1=="Hostname" {print substr($0, index($0,"=")+1); exit}' /etc/zabbix_agentd.conf 2>/dev/null)
                zserver=$(awk -F= '$1=="Server" {print substr($0, index($0,"=")+1); exit}' /etc/zabbix_agentd.conf 2>/dev/null)
                zactive=$(awk -F= '$1=="ServerActive" {print substr($0, index($0,"=")+1); exit}' /etc/zabbix_agentd.conf 2>/dev/null)
                [ -n "$zhost" ] || zhost="CPE-Default"
                [ -n "$zserver" ] || zserver="zabbix.switch-net.com"
                [ -n "$zactive" ] || zactive="zabbix.switch-net.com"
                rid=$(json_escape "$rid"); rdesc=$(json_escape "$rdesc"); rhost=$(json_escape "$rhost"); rport=$(json_escape "$rport"); rtoken=$(json_escape "$rtoken")
                zhost=$(json_escape "$zhost"); zserver=$(json_escape "$zserver"); zactive=$(json_escape "$zactive")
                echo "{\"status\":\"ok\",\"rtty\":{\"id\":\"$rid\",\"description\":\"$rdesc\",\"host\":\"$rhost\",\"port\":\"$rport\",\"token\":\"$rtoken\"},\"zabbix\":{\"Hostname\":\"$zhost\",\"Server\":\"$zserver\",\"ServerActive\":\"$zactive\"}}"
                ;;
            "set_basic")
                require_admin || { json_header; echo '{"status":"error","msg":"forbidden"}'; exit 0; }
                body=$(read_body)
                rid=$(form_value "$body" "rtty_id")
                rdesc=$(form_value "$body" "rtty_description")
                rhost=$(form_value "$body" "rtty_host")
                rport=$(form_value "$body" "rtty_port")
                rtoken=$(form_value "$body" "rtty_token")
                zhost=$(form_value "$body" "zbx_hostname")
                zserver=$(form_value "$body" "zbx_server")
                zactive=$(form_value "$body" "zbx_serveractive")
                json_header
                echo "$rid:$rdesc:$rhost:$rport:$rtoken:$zhost:$zserver:$zactive" | grep -Eq '^[^`$;&|<>\\]*$' || { echo '{"status":"error","msg":"invalid characters"}'; exit 0; }
                echo "$rport" | grep -Eq '^[0-9]{1,5}$' || { echo '{"status":"error","msg":"rtty port invalid"}'; exit 0; }
                [ -n "$rid" ] && [ -n "$rhost" ] && [ -n "$rtoken" ] && [ -n "$zhost" ] && [ -n "$zserver" ] && [ -n "$zactive" ] || { echo '{"status":"error","msg":"required value missing"}'; exit 0; }
                mkdir -p /etc/config
                uci -q get rtty.@rtty[0] >/dev/null 2>&1 || uci add rtty rtty >/dev/null
                uci set rtty.@rtty[0].id="$rid"
                uci set rtty.@rtty[0].description="$rdesc"
                uci set rtty.@rtty[0].host="$rhost"
                uci set rtty.@rtty[0].port="$rport"
                uci set rtty.@rtty[0].token="$rtoken"
                uci commit rtty
                cat > /etc/zabbix_agentd.conf <<EOF
Hostname=$zhost
AllowRoot=1
Server=$zserver
ServerActive=$zactive
LogFile=/tmp/zabbix_agentd.log
LogFileSize=1
AllowKey=system.run[*]
StartAgents=1
Timeout=10
BufferSend=5
BufferSize=100
EOF
                /etc/init.d/rtty restart >/dev/null 2>&1 </dev/null || true
                /etc/init.d/zabbix_agentd restart >/dev/null 2>&1 </dev/null || true
                echo '{"status":"ok"}'
                ;;
            "set_rtty")
                require_admin || { json_header; echo '{"status":"error","msg":"forbidden"}'; exit 0; }
                body=$(read_body)
                rid=$(form_value "$body" "rtty_id")
                rdesc=$(form_value "$body" "rtty_description")
                rhost=$(form_value "$body" "rtty_host")
                rport=$(form_value "$body" "rtty_port")
                rtoken=$(form_value "$body" "rtty_token")
                json_header
                echo "$rid:$rdesc:$rhost:$rport:$rtoken" | grep -Eq '^[^`$;&|<>\\]*$' || { echo '{"status":"error","msg":"invalid characters"}'; exit 0; }
                echo "$rport" | grep -Eq '^[0-9]{1,5}$' || { echo '{"status":"error","msg":"rtty port invalid"}'; exit 0; }
                [ -n "$rid" ] && [ -n "$rhost" ] && [ -n "$rtoken" ] || { echo '{"status":"error","msg":"required value missing"}'; exit 0; }
                mkdir -p /etc/config
                uci -q get rtty.@rtty[0] >/dev/null 2>&1 || uci add rtty rtty >/dev/null
                uci set rtty.@rtty[0].id="$rid"
                uci set rtty.@rtty[0].description="$rdesc"
                uci set rtty.@rtty[0].host="$rhost"
                uci set rtty.@rtty[0].port="$rport"
                uci set rtty.@rtty[0].token="$rtoken"
                uci commit rtty
                /etc/init.d/rtty restart >/dev/null 2>&1 </dev/null || true
                echo '{"status":"ok"}'
                ;;
            "set_zabbix")
                require_admin || { json_header; echo '{"status":"error","msg":"forbidden"}'; exit 0; }
                body=$(read_body)
                zhost=$(form_value "$body" "zbx_hostname")
                zserver=$(form_value "$body" "zbx_server")
                zactive=$(form_value "$body" "zbx_serveractive")
                json_header
                echo "$zhost:$zserver:$zactive" | grep -Eq '^[^`$;&|<>\\]*$' || { echo '{"status":"error","msg":"invalid characters"}'; exit 0; }
                [ -n "$zhost" ] && [ -n "$zserver" ] && [ -n "$zactive" ] || { echo '{"status":"error","msg":"required value missing"}'; exit 0; }
                cat > /etc/zabbix_agentd.conf <<EOF
Hostname=$zhost
AllowRoot=1
Server=$zserver
ServerActive=$zactive
LogFile=/tmp/zabbix_agentd.log
LogFileSize=1
AllowKey=system.run[*]
StartAgents=1
Timeout=10
BufferSend=5
BufferSize=100
EOF
                /etc/init.d/zabbix_agentd restart >/dev/null 2>&1 </dev/null || true
                echo '{"status":"ok"}'
                ;;
            "get_openvpn")
                require_admin || { json_header; echo '{"status":"error","msg":"forbidden"}'; exit 0; }
                json_header
                echo "{\"status\":\"ok\",\"tunnels\":["
                sep=""
                uci show openvpn 2>/dev/null | awk -F= '$2=="openvpn" {sub(/^openvpn\./,"",$1); print $1}' | while IFS= read -r sec; do
                    [ -n "$sec" ] || continue
                    enabled=$(uci -q get "openvpn.$sec.enabled" || echo 0)
                    remote=$(uci -q get "openvpn.$sec.remote" || echo ovpn.switch-net.com)
                    port=$(uci -q get "openvpn.$sec.port" || echo 1199)
                    kind="other"
                    auth_file=""
                    auth_user=""
                    auth_pass=""
                    account_count="0"
                    case "$sec" in
                        client*)
                            kind="client"
                            auth_file=$(uci -q get "openvpn.$sec.auth_user_pass" || true)
                            if safe_abs_path "$auth_file"; then
                                case "$auth_file" in
                                /etc/openvpn/*)
                                    auth_user=$(sed -n '1p' "$auth_file" 2>/dev/null)
                                    auth_pass=$(sed -n '2p' "$auth_file" 2>/dev/null)
                                    ;;
                                *) auth_file="" ;;
                                esac
                            else
                                auth_file=""
                            fi
                            ;;
                        server*)
                            kind="server"
                            remote=$(uci -q get "openvpn.$sec.local" || echo 0.0.0.0)
                            account_count=$(wc -l < /etc/openvpn/psw-file 2>/dev/null || echo 0)
                            ;;
                    esac
                    esec=$(json_escape "$sec")
                    eenabled=$(json_escape "$enabled")
                    eremote=$(json_escape "$remote")
                    eport=$(json_escape "$port")
                    ekind=$(json_escape "$kind")
                    efile=$(json_escape "$auth_file")
                    euser=$(json_escape "$auth_user")
                    epass=$(json_escape "$auth_pass")
                    printf '%s{"section":"%s","kind":"%s","enabled":"%s","remote":"%s","port":"%s","auth_file":"%s","user":"%s","pass":"%s","account_count":"%s"}' "$sep" "$esec" "$ekind" "$eenabled" "$eremote" "$eport" "$efile" "$euser" "$epass" "$account_count"
                    sep=","
                done
                echo "],\"server_accounts\":["
                sep=""
                if [ -f /etc/openvpn/psw-file ]; then
                    while read -r account_user account_pass rest; do
                        [ -n "$account_user" ] && [ -n "$account_pass" ] || continue
                        echo "$account_user" | grep -Eq '^[A-Za-z0-9_.@-]{1,64}$' || continue
                        disabled="0"
                        if [ -f "/etc/openvpn/ccd/$account_user" ] && grep -qx 'disable' "/etc/openvpn/ccd/$account_user" 2>/dev/null; then
                            disabled="1"
                        fi
                        euser=$(json_escape "$account_user")
                        epass=$(json_escape "$account_pass")
                        printf '%s{"user":"%s","pass":"%s","disabled":"%s"}' "$sep" "$euser" "$epass" "$disabled"
                        sep=","
                    done < /etc/openvpn/psw-file
                fi
                echo "],\"online_sessions\":["
                server_status_file=""
                for server_sec in $(uci show openvpn 2>/dev/null | awk -F= '$2=="openvpn" {sub(/^openvpn\./,"",$1); print $1}'); do
                    case "$server_sec" in
                        server*)
                            status_value=$(uci -q get "openvpn.$server_sec.status" || true)
                            server_status_file=${status_value%% *}
                            safe_abs_path "$server_status_file" || server_status_file=""
                            break
                            ;;
                    esac
                done
                sep=""
                if [ -n "$server_status_file" ] && [ -f "$server_status_file" ]; then
                    awk -F, '
                        { sub(/\r$/, "") }
                        $0 == "OpenVPN CLIENT LIST" { section="clients"; next }
                        $0 == "ROUTING TABLE" { section="routes"; next }
                        $0 == "GLOBAL STATS" || $0 == "END" { section=""; next }
                        section == "clients" && $1 == "Common Name" { next }
                        section == "routes" && $1 == "Virtual Address" { next }
                        section == "clients" && NF >= 5 {
                            name[++count] = $1
                            real[$1] = $2
                            received[$1] = $3
                            sent[$1] = $4
                            connected[$1] = $5
                            next
                        }
                        section == "routes" && NF >= 4 { virtual[$2] = $1 }
                        END {
                            for (i = 1; i <= count; i++) {
                                n = name[i]
                                printf "%s\t%s\t%s\t%s\t%s\t%s\n", n, virtual[n], real[n], received[n], sent[n], connected[n]
                            }
                        }
                    ' "$server_status_file" | while IFS="$(printf '\t')" read -r common_name virtual_ip real_address bytes_received bytes_sent connected_since; do
                        [ -n "$common_name" ] || continue
                        echo "$bytes_received" | grep -Eq '^[0-9]+$' || bytes_received=0
                        echo "$bytes_sent" | grep -Eq '^[0-9]+$' || bytes_sent=0
                        ecommon=$(json_escape "$common_name")
                        evirtual=$(json_escape "$virtual_ip")
                        ereal=$(json_escape "$real_address")
                        econnected=$(json_escape "$connected_since")
                        printf '%s{"common_name":"%s","virtual_ip":"%s","real_address":"%s","bytes_received":"%s","bytes_sent":"%s","connected_since":"%s"}' "$sep" "$ecommon" "$evirtual" "$ereal" "$bytes_received" "$bytes_sent" "$econnected"
                        sep=","
                    done
                fi
                echo "]}"
                ;;
            "set_openvpn")
                require_admin || { json_header; echo '{"status":"error","msg":"forbidden"}'; exit 0; }
                body=$(read_body)
                count=$(form_value "$body" "count")
                json_header
                echo "$count" | grep -Eq '^[0-9]{1,3}$' || { echo '{"status":"error","msg":"count invalid"}'; exit 0; }
                restart_required=0
                i=0
                while [ "$i" -lt "$count" ]; do
                    sec=$(form_value "$body" "sec_$i")
                    enabled=$(form_value "$body" "enabled_$i")
                    remote=$(form_value "$body" "remote_$i")
                    port=$(form_value "$body" "port_$i")
                    echo "$sec" | grep -Eq '^(@openvpn\[[0-9]+\]|[A-Za-z0-9_-]+)$' || { echo '{"status":"error","msg":"section invalid"}'; exit 0; }
                    case "$enabled" in 0|1) ;; *) echo '{"status":"error","msg":"enabled invalid"}'; exit 0 ;; esac
                    echo "$remote" | grep -Eq '^[A-Za-z0-9_.-]{1,128}$' || { echo '{"status":"error","msg":"remote invalid"}'; exit 0; }
                    echo "$port" | grep -Eq '^[0-9]{1,5}$' || { echo '{"status":"error","msg":"port invalid"}'; exit 0; }
                    old_enabled=$(uci -q get "openvpn.$sec.enabled" || echo 0)
                    case "$sec" in
                        server*)
                            echo "$remote" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || { echo '{"status":"error","msg":"local invalid"}'; exit 0; }
                            old_remote=$(uci -q get "openvpn.$sec.local" || echo 0.0.0.0)
                            ;;
                        *) old_remote=$(uci -q get "openvpn.$sec.remote" || echo ovpn.switch-net.com) ;;
                    esac
                    old_port=$(uci -q get "openvpn.$sec.port" || echo 1199)
                    [ "$enabled" = "$old_enabled" ] && [ "$remote" = "$old_remote" ] && [ "$port" = "$old_port" ] || restart_required=1
                    uci set "openvpn.$sec.enabled=$enabled" || { echo '{"status":"error","msg":"uci failed"}'; exit 0; }
                    case "$sec" in
                        server*) uci set "openvpn.$sec.local=$remote" || { echo '{"status":"error","msg":"uci failed"}'; exit 0; } ;;
                        *) uci set "openvpn.$sec.remote=$remote" || { echo '{"status":"error","msg":"uci failed"}'; exit 0; } ;;
                    esac
                    uci set "openvpn.$sec.port=$port" || { echo '{"status":"error","msg":"uci failed"}'; exit 0; }
                    case "$sec" in
                        client*)
                            auth_user=$(form_value "$body" "auth_user_$i")
                            auth_pass=$(form_value "$body" "auth_pass_$i")
                            echo "$auth_user:$auth_pass" | grep -Eq '^[^`$;&|<>\\]*$' || { echo '{"status":"error","msg":"invalid credentials"}'; exit 0; }
                            auth_file=$(uci -q get "openvpn.$sec.auth_user_pass" || true)
                            safe_abs_path "$auth_file" || { echo '{"status":"error","msg":"client auth file invalid"}'; exit 0; }
                            case "$auth_file" in
                                /etc/openvpn/*) ;;
                                *) echo '{"status":"error","msg":"client auth file invalid"}'; exit 0 ;;
                            esac
                            old_auth_user=$(sed -n '1p' "$auth_file" 2>/dev/null)
                            old_auth_pass=$(sed -n '2p' "$auth_file" 2>/dev/null)
                            if [ "$auth_user" != "$old_auth_user" ] || [ "$auth_pass" != "$old_auth_pass" ]; then
                                umask 077
                                mkdir -p /etc/openvpn
                                printf '%s\n%s\n' "$auth_user" "$auth_pass" > "$auth_file"
                                chmod 600 "$auth_file" 2>/dev/null || true
                                restart_required=1
                            fi
                            ;;
                    esac
                    i=$((i + 1))
                done
                uci commit openvpn || { echo '{"status":"error","msg":"uci commit failed"}'; exit 0; }
                [ "$restart_required" = "1" ] && /etc/init.d/openvpn restart >/dev/null 2>&1 </dev/null &
                echo '{"status":"ok"}'
                ;;
            "add_openvpn_server_account")
                require_admin || { json_header; echo '{"status":"error","msg":"forbidden"}'; exit 0; }
                body=$(read_body)
                account_user=$(form_value "$body" "user")
                account_pass=$(form_value "$body" "pass")
                json_header
                echo "$account_user" | grep -Eq '^[A-Za-z0-9_.@-]{1,64}$' || { echo '{"status":"error","msg":"username invalid"}'; exit 0; }
                echo "$account_pass" | grep -Eq '^[^[:space:]`$;&|<>\\]{1,128}$' || { echo '{"status":"error","msg":"password invalid"}'; exit 0; }
                openvpn_account_exists "$account_user" && { echo '{"status":"error","msg":"username exists"}'; exit 0; }
                mkdir -p /etc/openvpn/ccd
                umask 077
                printf '%s          %s\n' "$account_user" "$account_pass" >> /etc/openvpn/psw-file
                : > "/etc/openvpn/ccd/$account_user"
                chmod 600 /etc/openvpn/psw-file 2>/dev/null || true
                chmod 600 "/etc/openvpn/ccd/$account_user" 2>/dev/null || true
                echo '{"status":"ok"}'
                ;;
            "save_openvpn_server_account")
                require_admin || { json_header; echo '{"status":"error","msg":"forbidden"}'; exit 0; }
                body=$(read_body)
                old_user=$(form_value "$body" "old_user")
                account_user=$(form_value "$body" "user")
                account_pass=$(form_value "$body" "pass")
                json_header
                echo "$old_user" | grep -Eq '^[A-Za-z0-9_.@-]{1,64}$' || { echo '{"status":"error","msg":"username invalid"}'; exit 0; }
                echo "$account_user" | grep -Eq '^[A-Za-z0-9_.@-]{1,64}$' || { echo '{"status":"error","msg":"username invalid"}'; exit 0; }
                echo "$account_pass" | grep -Eq '^[^[:space:]`$;&|<>\\]{1,128}$' || { echo '{"status":"error","msg":"password invalid"}'; exit 0; }
                openvpn_account_exists "$old_user" || { echo '{"status":"error","msg":"account not found"}'; exit 0; }
                if [ "$old_user" != "$account_user" ] && openvpn_account_exists "$account_user"; then
                    echo '{"status":"error","msg":"username exists"}'
                    exit 0
                fi
                tmp_psw="/tmp/cpe_openvpn_psw.$$"
                awk -v old="$old_user" -v user="$account_user" -v pass="$account_pass" '{if ($1 == old) print user "          " pass; else print $0}' /etc/openvpn/psw-file > "$tmp_psw"
                umask 077
                mv "$tmp_psw" /etc/openvpn/psw-file
                chmod 600 /etc/openvpn/psw-file 2>/dev/null || true
                mkdir -p /etc/openvpn/ccd
                if [ "$old_user" != "$account_user" ] && [ -f "/etc/openvpn/ccd/$old_user" ]; then
                    mv "/etc/openvpn/ccd/$old_user" "/etc/openvpn/ccd/$account_user"
                fi
                [ -f "/etc/openvpn/ccd/$account_user" ] || : > "/etc/openvpn/ccd/$account_user"
                chmod 600 "/etc/openvpn/ccd/$account_user" 2>/dev/null || true
                echo '{"status":"ok"}'
                ;;
            "delete_openvpn_server_account")
                require_admin || { json_header; echo '{"status":"error","msg":"forbidden"}'; exit 0; }
                body=$(read_body)
                account_user=$(form_value "$body" "user")
                json_header
                echo "$account_user" | grep -Eq '^[A-Za-z0-9_.@-]{1,64}$' || { echo '{"status":"error","msg":"username invalid"}'; exit 0; }
                openvpn_account_exists "$account_user" || { echo '{"status":"error","msg":"account not found"}'; exit 0; }
                tmp_psw="/tmp/cpe_openvpn_psw.$$"
                awk -v user="$account_user" '$1 != user {print}' /etc/openvpn/psw-file > "$tmp_psw"
                umask 077
                mv "$tmp_psw" /etc/openvpn/psw-file
                chmod 600 /etc/openvpn/psw-file 2>/dev/null || true
                rm -f "/etc/openvpn/ccd/$account_user"
                echo '{"status":"ok"}'
                ;;
            "toggle_openvpn_server_account")
                require_admin || { json_header; echo '{"status":"error","msg":"forbidden"}'; exit 0; }
                body=$(read_body)
                account_user=$(form_value "$body" "user")
                json_header
                echo "$account_user" | grep -Eq '^[A-Za-z0-9_.@-]{1,64}$' || { echo '{"status":"error","msg":"username invalid"}'; exit 0; }
                openvpn_account_exists "$account_user" || { echo '{"status":"error","msg":"account not found"}'; exit 0; }
                mkdir -p /etc/openvpn/ccd
                ccd_file="/etc/openvpn/ccd/$account_user"
                if [ -f "$ccd_file" ] && grep -qx 'disable' "$ccd_file" 2>/dev/null; then
                    : > "$ccd_file"
                    state="enabled"
                else
                    printf 'disable\n' > "$ccd_file"
                    state="disabled"
                fi
                chmod 600 "$ccd_file" 2>/dev/null || true
                echo "{\"status\":\"ok\",\"state\":\"$state\"}"
                ;;
            "list_dir")
                require_admin || { json_header; echo '{"status":"error","msg":"forbidden"}'; exit 0; }
                dir=$(query_value "path")
                [ -n "$dir" ] || dir="/"
                safe_abs_path "$dir" || { json_header; echo '{"status":"error","msg":"invalid path"}'; exit 0; }
                [ -d "$dir" ] || { json_header; echo '{"status":"error","msg":"not directory"}'; exit 0; }
                json_header
                edir=$(json_escape "$dir")
                echo "{\"status\":\"ok\",\"path\":\"$edir\",\"items\":["
                sep=""
                find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null | sort | head -n 300 | while IFS= read -r p; do
                    [ -e "$p" ] || continue
                    name=$(basename "$p")
                    ep=$(json_escape "$p")
                    en=$(json_escape "$name")
                    if [ -d "$p" ]; then
                        printf '%s{"name":"%s","path":"%s","type":"dir","size":"0"}' "$sep" "$en" "$ep"
                    elif [ -f "$p" ]; then
                        size=$(wc -c < "$p" 2>/dev/null || echo 0)
                        printf '%s{"name":"%s","path":"%s","type":"file","size":"%s"}' "$sep" "$en" "$ep" "$size"
                    else
                        continue
                    fi
                    sep=","
                done
                echo "]}"
                ;;
            "list_files")
                require_admin || { json_header; echo '{"status":"error","msg":"forbidden"}'; exit 0; }
                json_header
                echo '{"status":"ok","files":['
                sep=""
                find /tmp /root /etc/config /www/cpe -maxdepth 2 -type f 2>/dev/null | sort | head -n 500 | while IFS= read -r f; do
                    [ -f "$f" ] || continue
                    size=$(wc -c < "$f" 2>/dev/null || echo 0)
                    ef=$(json_escape "$f")
                    printf '%s{"path":"%s","size":"%s"}' "$sep" "$ef" "$size"
                    sep=","
                done
                echo ']}'
                ;;
            "upload_file")
                require_admin || { json_header; echo '{"status":"error","msg":"forbidden"}'; exit 0; }
                name=$(query_value "name")
                json_header
                base=$(basename "$name" 2>/dev/null)
                echo "$base" | grep -Eq '^[A-Za-z0-9_.@%+=,-]{1,128}$' || { echo '{"status":"error","msg":"文件名非法"}'; exit 0; }
                [ -n "$CONTENT_LENGTH" ] || { echo '{"status":"error","msg":"文件数据为空"}'; exit 0; }
                mkdir -p /tmp
                out="/tmp/$base"
                read_body > "$out"
                [ -s "$out" ] || { rm -f "$out"; echo '{"status":"error","msg":"文件数据为空"}'; exit 0; }
                chmod 600 "$out" 2>/dev/null || true
                eout=$(json_escape "$out")
                echo "{\"status\":\"ok\",\"path\":\"$eout\"}"
                ;;
            "download_file")
                require_auth || { text_header; echo "unauthorized"; exit 0; }
                file=$(query_value "file")
                safe_abs_file "$file" || { text_header; echo "invalid file"; exit 0; }
                base=$(basename "$file")
                echo "Content-Type: application/octet-stream"
                echo "Content-Disposition: attachment; filename=\"$base\""
                echo ""
                cat "$file"
                ;;
            "sysupgrade_firmware")
                require_admin || { json_header; echo '{"status":"error","msg":"forbidden"}'; exit 0; }
                body=$(read_body)
                file=$(form_value "$body" "file")
                keep=$(form_value "$body" "keep")
                json_header
                case "$file" in /tmp/*) ;; *) echo '{"status":"error","msg":"固件文件必须位于 /tmp 目录"}'; exit 0 ;; esac
                safe_abs_file "$file" || { echo '{"status":"error","msg":"固件文件不存在或路径非法"}'; exit 0; }
                if [ "$keep" = "1" ]; then
                    sysupgrade -F "$file" >/tmp/cpe_sysupgrade.log 2>&1 &
                else
                    sysupgrade -F -n "$file" >/tmp/cpe_sysupgrade.log 2>&1 &
                fi
                echo '{"status":"ok"}'
                ;;
            "get_network")
                text_header
                uci show network 2>/dev/null || true
                ;;
            "get_dhcp")
                require_admin || { text_header; echo "forbidden"; exit 0; }
                text_header
                uci show dhcp 2>/dev/null || true
                ;;
            "get_wifi")
                text_header
                uci show wireless 2>/dev/null || true
                ;;
            "set_network")
                require_admin || { json_header; echo '{"status":"error","msg":"forbidden"}'; exit 0; }
                json_header
                if run_uci_batch network; then
                    /etc/init.d/network restart >/dev/null 2>&1 </dev/null &
                    /etc/init.d/dnsmasq restart >/dev/null 2>&1 </dev/null &
                    echo '{"status":"ok"}'
                else
                    echo '{"status":"error","msg":"invalid uci command"}'
                fi
                ;;
            "set_dhcp")
                require_admin || { json_header; echo '{"status":"error","msg":"forbidden"}'; exit 0; }
                json_header
                if run_uci_batch dhcp; then
                    /etc/init.d/dnsmasq restart >/dev/null 2>&1 </dev/null &
                    echo '{"status":"ok"}'
                else
                    echo '{"status":"error","msg":"invalid uci command"}'
                fi
                ;;
            "set_wifi")
                json_header
                if require_admin; then
                    run_uci_batch wireless
                    ok=$?
                else
                    run_wifi_iface_batch
                    ok=$?
                fi
                if [ "$ok" = "0" ]; then
                    wifi reload >/dev/null 2>&1 </dev/null &
                    echo '{"status":"ok"}'
                else
                    echo '{"status":"error","msg":"invalid uci command"}'
                fi
                ;;
            "set_login_bg")
                require_admin || { json_header; echo '{"status":"error","msg":"forbidden"}'; exit 0; }
                name=$(echo "$QUERY_STRING" | tr '&' '\n' | awk -F= '$1=="name" {print substr($0,6); exit}' | while read -r v; do urldecode "$v"; done)
                mime=$(echo "$QUERY_STRING" | tr '&' '\n' | awk -F= '$1=="mime" {print substr($0,6); exit}' | while read -r v; do urldecode "$v"; done)
                json_header
                case "$mime:$name" in
                    image/jpeg:*|image/jpg:*|*:*.jpg|*:*.JPG|*:*.jpeg|*:*.JPEG) ext="jpg" ;;
                    image/png:*|*:*.png|*:*.PNG) ext="png" ;;
                    *) echo '{"status":"error","msg":"仅支持 jpg 或 png 图片"}'; exit 0 ;;
                esac
                mkdir -p /www/cpe/assets /etc/config
                tmp="/tmp/cpe_login_bg.$$"
                read_body > "$tmp"
                if [ ! -s "$tmp" ]; then
                    rm -f "$tmp"
                    echo '{"status":"error","msg":"图片数据为空"}'
                    exit 0
                fi
                size=$(wc -c < "$tmp" 2>/dev/null || echo 0)
                if [ "$size" -gt 5242880 ]; then
                    rm -f "$tmp"
                    echo '{"status":"error","msg":"图片大小不能超过 5MB"}'
                    exit 0
                fi
                out="/www/cpe/assets/login-bg.$ext"
                rm -f /www/cpe/assets/login-bg.jpg /www/cpe/assets/login-bg.png 2>/dev/null || true
                mv "$tmp" "$out"
                chmod 644 "$out" 2>/dev/null || true
                echo "/cpe/assets/login-bg.$ext" > "$LOGIN_BG_CONF"
                echo "{\"status\":\"ok\",\"path\":\"/cpe/assets/login-bg.$ext\"}"
                ;;
            *)
                json_header
                echo '{"status":"error","msg":"unknown action"}'
                ;;
        esac
        ;;
esac
