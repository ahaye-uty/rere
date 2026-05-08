#!/bin/bash
# ========================================================
# IP Limiter for SSH & Xray
# Enforce max simultaneous IP connections per user
# Default: 2 IP / user
# Runs via cron every 1 minute
# ========================================================

LIMIT_FILE="/usr/local/etc/xray/limit-ip"
LOG_FILE="/var/log/limit-ip.log"
CHAIN_NAME="LIMIT-IP"

# Read limit (default 2)
if [[ -f "$LIMIT_FILE" ]]; then
    LIMIT=$(cat "$LIMIT_FILE" | tr -d '[:space:]')
else
    LIMIT=2
fi

[[ ! "$LIMIT" =~ ^[0-9]+$ ]] && LIMIT=2
[[ "$LIMIT" -lt 1 ]] && LIMIT=2

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Rotate log if > 1MB
if [[ -f "$LOG_FILE" ]] && [[ $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) -gt 1048576 ]]; then
    tail -n 200 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
fi

# ===== SSH / Dropbear Limiter =====
limit_ssh() {
    local users
    users=$(awk -F: '$7=="/bin/false" {print $1}' /etc/passwd)
    [[ -z "$users" ]] && return

    for user in $users; do
        # Unique IPs from active OpenSSH sessions
        local ssh_ips
        ssh_ips=$(ps aux 2>/dev/null | grep "sshd:.*${user}@" | grep -v grep | awk '{print $NF}' | grep -oP '\d+\.\d+\.\d+\.\d+' | sort -u)

        # Unique IPs from active Dropbear sessions
        local db_ips=""
        if [[ -f "/var/log/auth.log" ]]; then
            local db_pids
            db_pids=$(ps aux 2>/dev/null | grep -i "[d]ropbear" | awk '{print $2}')
            for pid in $db_pids; do
                local ip
                ip=$(grep "dropbear\[$pid\]" /var/log/auth.log 2>/dev/null | grep "Password auth succeeded" | grep -w "$user" | awk '{print $12}' | tail -1)
                [[ -n "$ip" ]] && db_ips="$db_ips $ip"
            done
        fi

        # Combine and count unique IPs
        local all_ips unique_count
        all_ips=$(echo -e "${ssh_ips}\n${db_ips}" | tr ' ' '\n' | grep -oP '\d+\.\d+\.\d+\.\d+' | sort -u)
        unique_count=$(echo "$all_ips" | grep -c .)

        if [[ "$unique_count" -gt "$LIMIT" ]]; then
            log_msg "SSH LIMIT: user=$user ips=$unique_count/$LIMIT -> kill"
            pkill -u "$user" sshd 2>/dev/null
            pkill -u "$user" dropbear 2>/dev/null
        fi
    done
}

# ===== Xray Limiter (iptables-based, no xray restart needed) =====
limit_xray() {
    local access_log="/var/log/xray/access.log"
    [[ ! -f "$access_log" ]] && return
    [[ ! -s "$access_log" ]] && return

    # Ensure iptables chain exists
    iptables -N "$CHAIN_NAME" 2>/dev/null
    iptables -C INPUT -j "$CHAIN_NAME" 2>/dev/null || iptables -I INPUT -j "$CHAIN_NAME"

    # Flush old rules (re-evaluate every run)
    iptables -F "$CHAIN_NAME" 2>/dev/null

    # Get all xray users from config
    local all_users
    all_users=$(grep -E '^(###|#&|#!) ' /usr/local/etc/xray/config.json 2>/dev/null | awk '{print $2}' | sort -u)
    [[ -z "$all_users" ]] && return

    for user in $all_users; do
        # Get unique source IPs for this user from recent access log
        local user_ips
        user_ips=$(grep -w "$user" "$access_log" | tail -n 500 | awk '{print $3}' | sed 's|tcp://||g; s|udp://||g' | cut -d: -f1 | grep -oP '\d+\.\d+\.\d+\.\d+' | sort -u)

        local ip_count
        ip_count=$(echo "$user_ips" | grep -c .)
        [[ "$ip_count" -le "$LIMIT" ]] && continue

        log_msg "XRAY LIMIT: user=$user ips=$ip_count/$LIMIT -> blocking excess"

        # Keep only the first $LIMIT IPs (most seen = allowed), block the rest
        local allowed blocked
        allowed=$(echo "$user_ips" | head -n "$LIMIT")
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
