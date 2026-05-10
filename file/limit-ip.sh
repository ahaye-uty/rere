#!/bin/bash
# ========================================================
# IP Limiter for SSH/Dropbear (SSH-only, NO iptables)
# Enforce max simultaneous SSH sessions per user.
# Per-user limit dari limit-ip.db, fallback ke global default.
# Dijalankan via cron tiap 1 menit.
#
# Cara enforcement:
#   Hitung proses sshd/sshd-session/sshd-auth/dropbear yang dimiliki
#   user (= jumlah sesi SSH aktif post-auth). Kalau lebih dari limit
#   -> kill -9 semua proses tsb. User tinggal reconnect, sesi balik
#   dalam batas limit. Daemon user `sshd` (UID 111) di-skip lewat
#   filter UID >= 1000 supaya child preauth-nya gak ke-pick.
#
# Tidak menggunakan iptables sama sekali -> tidak ada risiko
# block IP HP user / admin sendiri secara permanen.
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

get_user_ssh_pids() {
    # Detect authenticated SSH sessions for a user.
    #
    # Pendekatan: hitung proses sshd / sshd-session / sshd-auth /
    # dropbear yang DIMILIKI user (post-auth, OpenSSH privsep
    # unprivileged side + dropbear post-setuid). Ini lebih permissive
    # daripada match cmdline "sshd: USER [priv]" -- match cmdline tadi
    # ternyata gak reliable di beberapa env (proctitle bisa beda
    # format atau gak ter-update kalau auth flow lewat WS proxy).
    #
    # Risiko mis-detection terhadap daemon user `sshd` (UID 111) yang
    # juga bisa muncul di sini, di-mitigate di limit_ssh() lewat filter
    # UID >= 1000 -- jadi loop ini gak pernah iterate atas user `sshd`.
    local user="$1"
    ps -u "$user" -o pid=,comm= 2>/dev/null \
        | awk '$2 ~ /^(sshd.*|dropbear.*)$/ {print $1}'
}

limit_ssh() {
    local users
    # Hanya ambil user-account beneran (UID >= 1000), bukan daemon
    # system seperti `sshd` (UID 111) yang juga punya shell
    # /usr/sbin/nologin. Tanpa filter UID, child sshd preauth
    # process bakal di-counted sebagai "sesi sshd" dan ke-kill
    # tiap menit, bikin login user legit gagal authenticate.
    users=$(awk -F: '($7=="/bin/false" || $7=="/usr/sbin/nologin" || $7=="/sbin/nologin") && $3>=1000 {print $1}' /etc/passwd)
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
