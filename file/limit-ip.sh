#!/bin/bash
# ========================================================
# IP Limiter for SSH/Dropbear (SSH-only, NO iptables)
# Enforce max simultaneous SSH sessions per user.
# Per-user limit dari limit-ip.db, fallback ke global default.
# Dijalankan via cron tiap 1 menit.
#
# Cara deteksi (sama dengan menu built-in "Cek SSH Login"):
#   1. Ambil PID yang lagi punya tag [priv] di cmdline (OpenSSH
#      privsep parent) + PID dropbear yang aktif.
#   2. Cross-reference tiap PID dengan auth.log entry-nya:
#        sshd[PID]:    Accepted password|publickey for USER ...
#        dropbear[PID]: Password|Pubkey auth succeeded for 'USER'
#   3. Mapping PID -> USER. Group by USER buat hitung sesi.
#
# Cara enforcement:
#   Kalau jumlah PID untuk satu user > limit, kill -9 PID2 tsb.
#   User tinggal reconnect, sesi balik dalam batas limit. Tidak
#   nyentuh iptables.
#
# User yang di-limit cuma VPN account (shell /bin/false atau
# /usr/sbin/nologin + UID >= 1000). User admin VPS dengan shell
# interactive (/bin/bash dll) di-skip supaya gak ngebanned diri
# sendiri. Daemon user `sshd` (UID 111) juga ke-skip karena UID
# filter.
#
# Xray (vmess/vless/trojan) dan UDP-Custom tidak di-limit di sini.
# ========================================================

LIMIT_FILE="/usr/local/etc/xray/limit-ip"
DB_FILE="/usr/local/etc/xray/limit-ip.db"
LOG_FILE="/var/log/limit-ip.log"

# Read global default limit
if [[ -f "$LIMIT_FILE" ]]; then
    DEFAULT_LIMIT=$(cat "$LIMIT_FILE" | tr -d '[:space:]')
else
    DEFAULT_LIMIT=2
fi
[[ ! "$DEFAULT_LIMIT" =~ ^[0-9]+$ ]] && DEFAULT_LIMIT=2
[[ "$DEFAULT_LIMIT" -lt 1 ]] && DEFAULT_LIMIT=2

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

get_auth_log() {
    if [[ -f /var/log/auth.log ]]; then
        echo /var/log/auth.log
    elif [[ -f /var/log/secure ]]; then
        echo /var/log/secure
    fi
}

# True kalau user adalah VPN account: UID >= 1000 + shell nologin/
# false (= account yang dibuat lewat sshman/add-ssh). User admin
# VPS dengan shell /bin/bash dll bakal return false -- gak masuk
# loop enforcement.
is_vpn_user() {
    local user="$1"
    local uid shell
    uid=$(id -u "$user" 2>/dev/null)
    [[ -z "$uid" || "$uid" -lt 1000 ]] && return 1
    shell=$(getent passwd "$user" 2>/dev/null | awk -F: '{print $7}')
    case "$shell" in
        /bin/false|/usr/sbin/nologin|/sbin/nologin) return 0 ;;
        *) return 1 ;;
    esac
}

# Output: baris "PID USERNAME" buat tiap sesi SSH/Dropbear yang
# authenticated saat ini. Sama logic dengan built-in cek-ssh menu
# opsi 3 (PID [priv] dari ps + auth.log lookup).
build_session_map() {
    local logfile
    logfile=$(get_auth_log)
    [[ -z "$logfile" ]] && return

    # === OpenSSH ===
    # PID [priv] = privsep parent post-auth (one per session).
    local sshd_pids
    sshd_pids=$(ps -eo pid=,args= 2>/dev/null | awk '/\[priv\]$/ {print $1}')
    if [[ -n "$sshd_pids" ]]; then
        # Build PID->USER map dari semua "sshd[PID]: Accepted ... for USER"
        # entries (password / publickey / keyboard-interactive). Map.
        local sshd_log
        sshd_log=$(grep -E "sshd\[[0-9]+\]:[[:space:]]+Accepted (password|publickey|keyboard-interactive) for " "$logfile" 2>/dev/null \
                   | sed -E 's/.*sshd\[([0-9]+)\]:[[:space:]]+Accepted [^ ]+ for ([^ ]+).*/\1 \2/' \
                   | awk 'NF==2 {map[$1]=$2} END {for (p in map) print p, map[p]}')
        local pid user
        for pid in $sshd_pids; do
            user=$(echo "$sshd_log" | awk -v p="$pid" '$1 == p {print $2; exit}')
            [[ -n "$user" ]] && echo "$pid $user"
        done
    fi

    # === Dropbear ===
    local dpids
    dpids=$(pgrep -x dropbear 2>/dev/null)
    if [[ -n "$dpids" ]]; then
        local dropbear_log
        dropbear_log=$(grep -E "dropbear\[[0-9]+\]:.*(Password|Pubkey) auth succeeded for " "$logfile" 2>/dev/null \
                       | sed -E "s/.*dropbear\[([0-9]+)\]:.*succeeded for '([^']+)'.*/\1 \2/" \
                       | awk 'NF==2 {map[$1]=$2} END {for (p in map) print p, map[p]}')
        local pid user
        for pid in $dpids; do
            user=$(echo "$dropbear_log" | awk -v p="$pid" '$1 == p {print $2; exit}')
            [[ -n "$user" ]] && echo "$pid $user"
        done
    fi
}

limit_ssh() {
    local sessions users user
    sessions=$(build_session_map)
    [[ -z "$sessions" ]] && return

    users=$(echo "$sessions" | awk '{print $2}' | sort -u)
    [[ -z "$users" ]] && return

    for user in $users; do
        # Skip non-VPN users (admin VPS dengan /bin/bash, daemon, root, dll)
        is_vpn_user "$user" || continue

        local LIMIT pids count pid
        LIMIT=$(get_user_limit "$user")
        pids=$(echo "$sessions" | awk -v u="$user" '$2 == u {print $1}')
        count=$(echo "$pids" | grep -c .)

        if [[ "$count" -gt "$LIMIT" ]]; then
            log_msg "SSH LIMIT: user=$user sessions=$count/$LIMIT -> kill"
            for pid in $pids; do
                kill -9 "$pid" 2>/dev/null
            done
        fi
    done
}

# Cleanup leftover UDP-Custom limit chain from previous versions.
# (Older limit-ip.sh installed iptables chain LIMIT-UDP-CUSTOM; we
# don't want it sticking around after upgrade.)
cleanup_legacy_udp_chain() {
    command -v iptables >/dev/null 2>&1 || return
    if iptables -L LIMIT-UDP-CUSTOM -n >/dev/null 2>&1; then
        while iptables -D INPUT -j LIMIT-UDP-CUSTOM 2>/dev/null; do :; done
        iptables -F LIMIT-UDP-CUSTOM 2>/dev/null
        iptables -X LIMIT-UDP-CUSTOM 2>/dev/null
        log_msg "cleanup: removed legacy chain LIMIT-UDP-CUSTOM"
    fi
}

limit_ssh
cleanup_legacy_udp_chain
