#!/bin/bash
# ========================================================
# IP Limiter for SSH/Dropbear (SSH-only) + optional UDP-Custom
#
# SSH/Dropbear:
#   Per-user limit dari limit-ip.db, fallback ke global default.
#   Hitung child sshd/sshd-session/sshd-auth/dropbear yang dimiliki
#   user (= jumlah sesi SSH aktif). Kalau lebih dari limit -> kill -9
#   semua sesi user. User reconnect, balik dalam batas limit.
#   TIDAK menggunakan iptables sama sekali.
#
# UDP-Custom (opt-in, default OFF):
#   udp-custom v1.4 (ePro) adalah single-process daemon yang tidak
#   fork per client, jadi process-counting tidak applicable.
#   Sebagai gantinya pakai iptables `connlimit` pada port UDP
#   tujuan udp-custom (default 36712) saja -- TIDAK menyentuh
#   port 443/80 (HTTP-custom & SSH-WS aman).
#   Semantic: max N concurrent UDP flow per source IP (bukan ban
#   IP -- hanya quota).
#
#   Aktifkan: echo 1 > /usr/local/etc/xray/limit-udp-enabled
#             (atau via menu 'Set IP Limit' -> opsi UDP Custom)
#   Limit value: ikut /usr/local/etc/xray/limit-ip (global default).
#   Port UDP: /usr/local/etc/xray/limit-udp-port (default 36712).
#
# Dijalankan via cron tiap 1 menit.
# ========================================================

LIMIT_FILE="/usr/local/etc/xray/limit-ip"
DB_FILE="/usr/local/etc/xray/limit-ip.db"
LOG_FILE="/var/log/limit-ip.log"
UDP_ENABLE_FILE="/usr/local/etc/xray/limit-udp-enabled"
UDP_PORT_FILE="/usr/local/etc/xray/limit-udp-port"
UDP_CHAIN="LIMIT-UDP-CUSTOM"

# Read global default limit
if [[ -f "$LIMIT_FILE" ]]; then
    DEFAULT_LIMIT=$(cat "$LIMIT_FILE" | tr -d '[:space:]')
else
    DEFAULT_LIMIT=2
fi
[[ ! "$DEFAULT_LIMIT" =~ ^[0-9]+$ ]] && DEFAULT_LIMIT=2
[[ "$DEFAULT_LIMIT" -lt 1 ]] && DEFAULT_LIMIT=2

# Read UDP-custom port (default udp-custom default 36712)
if [[ -f "$UDP_PORT_FILE" ]]; then
    UDP_PORT=$(cat "$UDP_PORT_FILE" | tr -d '[:space:]')
fi
[[ ! "$UDP_PORT" =~ ^[0-9]+$ ]] && UDP_PORT=36712

get_user_limit() {
    local username="$1"
    if [[ -f "$DB_FILE" ]]; then
        local db_limit
        db_limit=$(grep -w "^$username" "$DB_FILE" 2>/dev/null | tail -1 | awk '{print $2}')
        if [[ "$db_limit" =~ ^[0-9]+$ ]] && [[ "$db_limit" -ge 1 ]]; then
            echo "$db_limit"
            return
        fi
    fi
    echo "$DEFAULT_LIMIT"
}

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Rotate log if > 1MB
if [[ -f "$LOG_FILE" ]] && [[ $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) -gt 1048576 ]]; then
    tail -n 200 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
fi

get_user_ssh_pids() {
    local user="$1"
    ps -u "$user" -o pid=,comm= 2>/dev/null \
        | awk '$2 ~ /^(sshd|sshd-session|sshd-auth|dropbear)$/ {print $1}'
}

limit_ssh() {
    local users
    users=$(awk -F: '$7=="/bin/false" || $7=="/usr/sbin/nologin" || $7=="/sbin/nologin" {print $1}' /etc/passwd)
    [[ -z "$users" ]] && return

    for user in $users; do
        local LIMIT pids count
        LIMIT=$(get_user_limit "$user")
        pids=$(get_user_ssh_pids "$user")
        count=$(echo "$pids" | grep -c .)

        if [[ "$count" -gt "$LIMIT" ]]; then
            log_msg "SSH LIMIT: user=$user sessions=$count/$LIMIT -> kill"
            for pid in $pids; do
                kill -9 "$pid" 2>/dev/null
            done
        fi
    done
}

# --------------------------------------------------------
# UDP-Custom: per-source-IP concurrent flow limit (opt-in)
# --------------------------------------------------------
udp_custom_remove_chain() {
    while iptables -D INPUT -j "$UDP_CHAIN" 2>/dev/null; do :; done
    iptables -F "$UDP_CHAIN" 2>/dev/null
    iptables -X "$UDP_CHAIN" 2>/dev/null
}

udp_custom_install_chain() {
    local limit="$1"
    local port="$2"

    iptables -N "$UDP_CHAIN" 2>/dev/null || iptables -F "$UDP_CHAIN"
    iptables -A "$UDP_CHAIN" -p udp --dport "$port" \
        -m connlimit --connlimit-above "$limit" --connlimit-mask 32 \
        -j DROP 2>>"$LOG_FILE"

    if ! iptables -C INPUT -j "$UDP_CHAIN" 2>/dev/null; then
        iptables -I INPUT 1 -j "$UDP_CHAIN"
    fi
}

udp_custom_chain_limit() {
    iptables -S "$UDP_CHAIN" 2>/dev/null \
        | awk '/--connlimit-above/ {for(i=1;i<=NF;i++) if($i=="--connlimit-above") {print $(i+1); exit}}'
}

limit_udp_custom() {
    command -v iptables >/dev/null 2>&1 || return

    local enabled=0
    if [[ -f "$UDP_ENABLE_FILE" ]]; then
        local v
        v=$(cat "$UDP_ENABLE_FILE" | tr -d '[:space:]')
        [[ "$v" == "1" ]] && enabled=1
    fi

    if [[ "$enabled" -ne 1 ]]; then
        if iptables -L "$UDP_CHAIN" -n >/dev/null 2>&1; then
            udp_custom_remove_chain
            log_msg "UDP-CUSTOM LIMIT: disabled, chain $UDP_CHAIN removed"
        fi
        return
    fi

    local desired_limit="$DEFAULT_LIMIT"
    local current_limit=""

    if iptables -L "$UDP_CHAIN" -n >/dev/null 2>&1; then
        current_limit=$(udp_custom_chain_limit)
        if [[ "$current_limit" == "$desired_limit" ]] \
            && iptables -C INPUT -j "$UDP_CHAIN" 2>/dev/null; then
            return
        fi
    fi

    udp_custom_install_chain "$desired_limit" "$UDP_PORT"
    log_msg "UDP-CUSTOM LIMIT: chain $UDP_CHAIN installed (port=$UDP_PORT, max=$desired_limit/IP)"
}

limit_ssh
limit_udp_custom
