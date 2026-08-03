#!/bin/sh
CONFIG_FILE="/etc/config/redsocks2"
ALT_CONFIG_FILE="/etc/config/redsokcs2"
SESSIONS_FILE="/tmp/cpe_sessions"

json_header() {
    echo "Content-type: application/json"
    echo ""
}

require_admin() {
    token="$HTTP_X_CPE_TOKEN"
    [ -n "$token" ] || token=$(echo "$QUERY_STRING" | grep -o 'token=[^&]*' | cut -d= -f2)
    [ -n "$token" ] || token=$(echo "$QUERY_STRING" | grep -o '_cpe_token=[^&]*' | cut -d= -f2)
    [ -n "$token" ] || return 1
    now=$(date +%s)
    awk -F'|' -v t="$token" -v now="$now" '$1==t && $3=="admin" && $4>now {ok=1} END {exit ok?0:1}' "$SESSIONS_FILE" 2>/dev/null
}

if ! require_admin; then
    json_header
    echo '{"code": 1, "msg": "unauthorized"}'
    exit 0
fi

if [ "$REQUEST_METHOD" = "POST" ]; then
    cat > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    if [ -f "/etc/init.d/redsocks2" ]; then
        /etc/init.d/redsocks2 restart >/dev/null 2>&1 &
    fi
    json_header
    echo '{"code": 0, "msg": "success"}'
    exit 0
fi

echo "Content-type: text/plain"
echo ""
if [ -f "$CONFIG_FILE" ]; then
    cat "$CONFIG_FILE"
elif [ -f "$ALT_CONFIG_FILE" ]; then
    cat "$ALT_CONFIG_FILE"
else
    echo 'base { log_debug = off; log_info = off; log = "file:/dev/null"; daemon = on; redirector= iptables; }'
fi
