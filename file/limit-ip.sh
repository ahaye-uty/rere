#!/bin/bash
# ========================================================
# IP Limiter for SSH & Xray
# Enforce max simultaneous sessions/IP connections per user
# Supports per-user limit (1 or 2) from limit-ip.db
# Fallback to global default from limit-ip file
# Runs via cron every 1 minute
#
# SSH/Dropbear: dihitung per-SESI aktif (anak sshd/dropbear
#   yang dimiliki user), bukan unique IP. Lebih akurat utk
#   koneksi via HTTP Custom / SSH WebSocket — semuanya berasal
#   dari 127.0.0.1 (nginx -> proxy -> sshd/dropbear) sehingga
#   counting unique IP selalu = 1 dan limit tidak akan kena.
# Xray: tetap dihitung per-unique IP dari access.log.
# ========================================================

LIMIT_FILE="/usr/local/etc/xray/limit-ip"
DB_FILE="/usr/local/etc/xray/limit-ip.db"
LOG_FILE="/var/log/limit-ip.log"
CHAIN_NAME="LIMIT-IP"

# Read global default limit
if [[ -f "$LIMIT_FILE" ]]; then
    DEFAULT_LIMIT=$(cat "$LIMIT_FILE" | tr -d '[:space:]')
else
    DEFAULT_LIMIT=2
fi
[[ ! "$DEFAULT_LIMIT" =~ ^[0-9]+$ ]] && DEFAULT_LIMIT=2
[[ "$DEFAULT_LIMIT" -lt 1 ]] && DEFAULT_LIMIT=2

# Get per-user limit (from DB, fallback to global default)
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

# List PIDs sshd/dropbear/sshd-session/sshd-auth yang dimiliki user.
# Setelah autentikasi sukses, sshd & dropbear fork child yang berjalan
# sebagai user; jadi banyaknya PID = banyaknya sesi SSH aktif user tsb.
get_user_ssh_pids() {
    local user="$1"
    ps -u "$user" -o pid=,comm= 2>/dev/null \
        | awk '$2 ~ /^(sshd|sshd-session|sshd-auth|dropbear)$/ {print $1}'
}

# ===== SSH / Dropbear Limiter =====
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
            # Kill semua sesi user supaya next-connect kembali dalam limit.
            for pid in $pids; do
                kill -9 "$pid" 2>/dev/null
            done
        fi
    done
}

# ===== Xray Limiter (iptables-based, no xray restart needed) =====
# Uses access.log to find IPs per user (same method as cek-vmess/cek-vless)
limit_xray() {
    local access_log="/var/log/xray/access.log"
    [[ ! -f "$access_log" ]] && return
    [[ ! -s "$access_log" ]] && return

    # Ensure iptables chain exists
    iptables -N "$CHAIN_NAME" 2>/dev/null
    iptables -C INPUT -j "$CHAIN_NAME" 2>/dev/null || iptables -I INPUT -j "$CHAIN_NAME"

    # Flush old rules (re-evaluate every run)
    iptables -F "$CHAIN_NAME" 2>/dev/null

    # Get all xray users from config (### = vmess, #& = vless, #! = trojan)
    local all_users
    all_users=$(grep -E '^(###|#&|#!) ' /usr/local/etc/xray/config.json 2>/dev/null | awk '{print $2}' | sort -u)
    [[ -z "$all_users" ]] && return

    for user in $all_users; do
        local LIMIT
        LIMIT=$(get_user_limit "$user")

        # Get unique source IPs (same parsing as cek-vmess: field 3, strip tcp:, get IP before port)
        local user_ips
        user_ips=$(grep -w "$user" "$access_log" | tail -n 500 | cut -d " " -f 3 | sed 's/tcp://g' | cut -d ":" -f 1 | sort -u | grep -oP '\d+\.\d+\.\d+\.\d+')

        local ip_count
        ip_count=$(echo "$user_ips" | grep -c .)
        [[ "$ip_count" -le "$LIMIT" ]] && continue

        log_msg "XRAY LIMIT: user=$user ips=$ip_count/$LIMIT -> blocking excess"

        # Keep the first $LIMIT IPs, block the rest
        local blocked
        blocked=$(echo "$user_ips" | tail -n +"$((LIMIT + 1))")

        for ip in $blocked; do
            iptables -A "$CHAIN_NAME" -s "$ip" -p tcp -m multiport --dports 443,80,2443,2081,2082,1013 -j DROP
            log_msg "XRAY BLOCK: ip=$ip user=$user"
        done
    done
}

# Run
limit_ssh
limit_xray
