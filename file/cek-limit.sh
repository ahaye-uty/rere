#!/bin/bash
# ========================================================
# Cek IP Limit (SSH-only display + NoobzVPN)
# Tampilkan status sesi aktif per user SSH.
# User yang melebihi limit ditandai [OVER].
#
# Counting per-SESSION: match cmdline "sshd: USER [priv]" (one per
# authenticated OpenSSH session) + user-owned dropbear processes.
# Sama dengan logic yang dipakai built-in menu "Cek SSH Login",
# jadi angkanya cocok antar tampilan. Akurat juga untuk koneksi
# via HTTP Custom / SSH WebSocket (loopback 127.0.0.1, tapi tiap
# device tetap dapet privsep parent sendiri).
#
# Xray (vmess/vless/trojan) dan UDP-Custom tidak di-display di sini
# karena IP limit-nya sengaja dilepas (tidak bisa enforce aman tanpa
# proxy_protocol untuk Xray; udp-custom architecture tidak compatible
# dengan per-device limiting di network layer).
# ========================================================

LIMIT_FILE="/usr/local/etc/xray/limit-ip"
DB_FILE="/usr/local/etc/xray/limit-ip.db"
LOG_FILE="/var/log/limit-ip.log"

if [[ -f "$LIMIT_FILE" ]]; then
    DEFAULT_LIMIT=$(cat "$LIMIT_FILE" | tr -d '[:space:]')
else
    DEFAULT_LIMIT=2
fi
[[ ! "$DEFAULT_LIMIT" =~ ^[0-9]+$ ]] && DEFAULT_LIMIT=2

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

get_user_ssh_pids() {
    # Detect authenticated SSH sessions for a user.
    # Match cmdline "sshd: USER [priv]" (post-auth privsep parent) +
    # user-owned dropbear processes. Selaras dengan built-in menu
    # opsi 3 "Cek SSH Login" yang grep "[priv]" di ps -- jadi count
    # di sini cocok dengan yang muncul di sana.
    local user="$1"
    ps -eo pid=,args= 2>/dev/null | awk -v u="$user" '
        {
            pid=$1
            $1=""
            sub(/^[ \t]+/, "")
            if ($0 == "sshd: " u " [priv]") print pid
        }
    '
    pgrep -u "$user" -x dropbear 2>/dev/null
}

get_peer_ip_for_pid() {
    local pid="$1"
    ss -tnpH 2>/dev/null \
        | awk -v p="pid=$pid," '$0 ~ p {print $5; exit}' \
        | sed -E 's/:[0-9]+$//; s/^\[//; s/\]$//'
}

RED='\e[31m'
GREEN='\e[32m'
YELLOW='\e[33m'
CYAN='\e[36m'
NC='\e[0m'
BOLD='\e[1m'

clear
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "           ${BOLD}CEK IP LIMIT (SSH only)${NC}"
echo -e "           Default limit: ${CYAN}${DEFAULT_LIMIT}${NC} per user"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo -e " ${BOLD}═══ SSH / Dropbear (sesi aktif) ═══${NC}"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

ssh_bandel=0
ssh_total=0

# Hanya user-account beneran (UID >= 1000), bukan daemon
# system seperti `sshd` yang juga punya shell /usr/sbin/nologin.
users=$(awk -F: '($7=="/bin/false" || $7=="/usr/sbin/nologin" || $7=="/sbin/nologin") && $3>=1000 {print $1}' /etc/passwd)

for user in $users; do
    user_limit=$(get_user_limit "$user")
    pids=$(get_user_ssh_pids "$user")
    [[ -z "$pids" ]] && continue

    session_count=$(echo "$pids" | grep -c .)
    ssh_total=$((ssh_total + 1))

    if [[ "$session_count" -gt "$user_limit" ]]; then
        ssh_bandel=$((ssh_bandel + 1))
        echo -e " ${RED}${BOLD}[OVER]${NC} ${YELLOW}$user${NC} — ${RED}$session_count${NC}/${user_limit} sesi"
    else
        echo -e " ${GREEN}[OK]${NC}   $user — ${GREEN}$session_count${NC}/${user_limit} sesi"
    fi

    for pid in $pids; do
        ip=$(get_peer_ip_for_pid "$pid")
        if [[ -z "$ip" ]]; then
            ip="(unknown)"
            label=""
        elif [[ "$ip" == "127.0.0.1" || "$ip" == "::1" ]]; then
            label=" ${CYAN}(WS/loopback)${NC}"
        else
            label=""
        fi
        echo -e "         └─ pid=$pid $ip$label"
    done
done

if [[ "$ssh_total" -eq 0 ]]; then
    echo -e " ${CYAN}(tidak ada user SSH yang aktif)${NC}"
fi

echo ""
echo -e " ${BOLD}═══ NoobzVPN ═══${NC}"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

NZ_DB="/etc/noobzvpns/db_user.json"

if [[ -f "$NZ_DB" ]] && command -v jq &>/dev/null; then
    jq -r '.users | keys[]' "$NZ_DB" 2>/dev/null | while read username; do
        user_info=$(jq -r ".users[\"$username\"]" "$NZ_DB")
        devices=$(echo "$user_info" | jq -r ".devices")
        active_devices=$(echo "$user_info" | jq -r '.statistic.active_devices[]?' 2>/dev/null)
        active_count=$(echo "$active_devices" | grep -c . 2>/dev/null)
        [[ -z "$active_devices" ]] && active_count=0

        if [[ "$active_count" -gt 0 ]]; then
            if [[ "$active_count" -gt "$devices" ]]; then
                echo -e " ${RED}${BOLD}[OVER]${NC} ${YELLOW}$username${NC} — ${RED}$active_count${NC}/$devices device"
            else
                echo -e " ${GREEN}[OK]${NC}   $username — ${GREEN}$active_count${NC}/$devices device"
            fi
        fi
    done
else
    echo -e " ${CYAN}(NoobzVPN DB tidak ditemukan)${NC}"
fi

echo ""
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ "$ssh_bandel" -gt 0 ]]; then
    echo -e " ${RED}${BOLD}Total user SSH bandel: $ssh_bandel${NC} (akan di-kick cron berikutnya)"
else
    echo -e " ${GREEN}${BOLD}Semua user SSH dalam limit${NC}"
fi
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo -e " ${BOLD}═══ Log Limit Terakhir ═══${NC}"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ -f "$LOG_FILE" ]] && [[ -s "$LOG_FILE" ]]; then
    tail -n 10 "$LOG_FILE" | while read -r line; do
        if echo "$line" | grep -q "LIMIT\|BLOCK"; then
            echo -e " ${RED}$line${NC}"
        else
            echo -e " $line"
        fi
    done
else
    echo -e " ${CYAN}(belum ada log)${NC}"
fi
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
