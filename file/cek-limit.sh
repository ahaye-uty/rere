#!/bin/bash
# ========================================================
# Cek IP Limit (SSH + UDP-Custom + NoobzVPN)
# Tampilkan status sesi aktif per user SSH dan flow per source
# IP untuk UDP-Custom. Yang over-limit ditandai [OVER].
#
# SSH counting: jumlah child sshd/dropbear yang dimiliki user.
# Akurat untuk koneksi via HTTP Custom / SSH WebSocket
# (semua loopback 127.0.0.1, tapi tiap device = 1 child).
#
# UDP-Custom: hanya ditampilkan kalau IP limit UDP di-aktifkan
# (file /usr/local/etc/xray/limit-udp-enabled berisi '1').
# Counting per source IP via conntrack flow ke port udp-custom.
# Semantic: max N concurrent UDP flow per source IP.
#
# Xray (vmess/vless/trojan) tidak di-display di sini karena
# IP limit-nya sengaja dilepas (butuh proxy_protocol untuk akurat).
# ========================================================

LIMIT_FILE="/usr/local/etc/xray/limit-ip"
DB_FILE="/usr/local/etc/xray/limit-ip.db"
LOG_FILE="/var/log/limit-ip.log"
UDP_ENABLE_FILE="/usr/local/etc/xray/limit-udp-enabled"
UDP_PORT_FILE="/usr/local/etc/xray/limit-udp-port"

if [[ -f "$LIMIT_FILE" ]]; then
    DEFAULT_LIMIT=$(cat "$LIMIT_FILE" | tr -d '[:space:]')
else
    DEFAULT_LIMIT=2
fi
[[ ! "$DEFAULT_LIMIT" =~ ^[0-9]+$ ]] && DEFAULT_LIMIT=2

if [[ -f "$UDP_PORT_FILE" ]]; then
    UDP_PORT=$(cat "$UDP_PORT_FILE" | tr -d '[:space:]')
fi
[[ ! "$UDP_PORT" =~ ^[0-9]+$ ]] && UDP_PORT=36712

UDP_ENABLED=0
if [[ -f "$UDP_ENABLE_FILE" ]] \
    && [[ "$(tr -d '[:space:]' < "$UDP_ENABLE_FILE")" == "1" ]]; then
    UDP_ENABLED=1
fi

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
    local user="$1"
    ps -u "$user" -o pid=,comm= 2>/dev/null \
        | awk '$2 ~ /^(sshd|sshd-session|sshd-auth|dropbear)$/ {print $1}'
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
echo -e "           ${BOLD}CEK IP LIMIT${NC}"
echo -e "           Default limit: ${CYAN}${DEFAULT_LIMIT}${NC} per user/IP"
if [[ "$UDP_ENABLED" -eq 1 ]]; then
    echo -e "           UDP-Custom limit: ${GREEN}ON${NC} (port ${CYAN}${UDP_PORT}${NC})"
else
    echo -e "           UDP-Custom limit: ${YELLOW}OFF${NC}"
fi
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo -e " ${BOLD}═══ SSH / Dropbear (sesi aktif) ═══${NC}"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

ssh_bandel=0
ssh_total=0

users=$(awk -F: '$7=="/bin/false" || $7=="/usr/sbin/nologin" || $7=="/sbin/nologin" {print $1}' /etc/passwd)

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
echo -e " ${BOLD}═══ UDP-Custom (per source IP) ═══${NC}"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ "$UDP_ENABLED" -ne 1 ]]; then
    echo -e " ${YELLOW}(IP limit UDP-Custom tidak aktif)${NC}"
    echo -e " ${CYAN}Aktifkan via menu \"Set IP Limit\" -> opsi 4${NC}"
elif ! command -v conntrack >/dev/null 2>&1; then
    echo -e " ${YELLOW}(conntrack belum terpasang -- jalankan: apt install conntrack)${NC}"
else
    udp_total=0
    udp_bandel=0
    udp_list=$(
        conntrack -L -p udp --dport "$UDP_PORT" 2>/dev/null \
            | awk '{
                src=""
                for (i=1; i<=NF; i++) {
                    if ($i ~ /^src=/) { src=substr($i,5); break }
                }
                if (src != "") print src
            }' \
            | sort \
            | uniq -c \
            | sort -rn
    )

    if [[ -z "$udp_list" ]]; then
        echo -e " ${CYAN}(tidak ada flow UDP-Custom aktif)${NC}"
    else
        while read -r line; do
            count=$(echo "$line" | awk '{print $1}')
            ip=$(echo "$line" | awk '{print $2}')
            [[ -z "$count" || -z "$ip" ]] && continue
            udp_total=$((udp_total + 1))
            if [[ "$count" -gt "$DEFAULT_LIMIT" ]]; then
                udp_bandel=$((udp_bandel + 1))
                echo -e " ${RED}${BOLD}[OVER]${NC} ${YELLOW}$ip${NC} — ${RED}$count${NC}/${DEFAULT_LIMIT} flow"
            else
                echo -e " ${GREEN}[OK]${NC}   $ip — ${GREEN}$count${NC}/${DEFAULT_LIMIT} flow"
            fi
        done <<< "$udp_list"

        if [[ "$udp_bandel" -gt 0 ]]; then
            echo -e " ${RED}${BOLD}$udp_bandel IP melebihi limit -- excess flow di-DROP iptables${NC}"
        fi
    fi
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
