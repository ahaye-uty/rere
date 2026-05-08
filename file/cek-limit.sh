#!/bin/bash
# ========================================================
# Cek IP Limit - Tampilkan status sesi / IP per user
# Menunjukkan user yang melebihi limit (bandel)
# Supports per-user limit dari limit-ip.db
#
# SSH/Dropbear: dihitung per-SESI aktif (anak sshd/dropbear
#   yang dimiliki user) — akurat utk HTTP Custom / SSH WS
#   yang semua koneksi terlihat dari 127.0.0.1.
# Xray: dihitung per-unique IP dari access.log.
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

# List PIDs sshd/dropbear yang dimiliki user (anak hasil fork
# setelah auth sukses = jumlah sesi aktif).
get_user_ssh_pids() {
    local user="$1"
    ps -u "$user" -o pid=,comm= 2>/dev/null \
        | awk '$2 ~ /^(sshd|sshd-session|sshd-auth|dropbear)$/ {print $1}'
}

# Ambil peer IP (IP klien) dari koneksi TCP yang dipegang PID tsb.
# Untuk SSH WS (HTTP Custom) ini akan return 127.0.0.1 karena
# koneksi ke sshd berasal dari proxy.py loopback.
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
echo -e "           ${BOLD}CEK IP LIMIT PER USER${NC}"
echo -e "           Default limit: ${CYAN}${DEFAULT_LIMIT}${NC} per user"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ===== SSH =====
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

# ===== XRAY =====
echo ""
echo -e " ${BOLD}═══ Xray (Vmess/Vless/Trojan) ═══${NC}"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

access_log="/var/log/xray/access.log"
xray_bandel=0
xray_total=0

if [[ -f "$access_log" ]] && [[ -s "$access_log" ]]; then
    all_users=$(grep -E '^(###|#&|#!) ' /usr/local/etc/xray/config.json 2>/dev/null | awk '{print $2}' | sort -u)

    for user in $all_users; do
        user_limit=$(get_user_limit "$user")
        user_ips=$(grep -w "$user" "$access_log" | tail -n 500 | cut -d " " -f 3 | sed 's/tcp://g' | cut -d ":" -f 1 | sort -u | grep -oP '\d+\.\d+\.\d+\.\d+')
        ip_count=$(echo "$user_ips" | grep -c .)

        if [[ "$ip_count" -gt 0 ]]; then
            xray_total=$((xray_total + 1))

            # Detect protocol type
            proto=""
            grep -q "^### $user " /usr/local/etc/xray/config.json 2>/dev/null && proto="vmess"
            grep -q "^#& $user " /usr/local/etc/xray/config.json 2>/dev/null && proto="vless"
            grep -q "^#! $user " /usr/local/etc/xray/config.json 2>/dev/null && proto="trojan"

            if [[ "$ip_count" -gt "$user_limit" ]]; then
                xray_bandel=$((xray_bandel + 1))
                echo -e " ${RED}${BOLD}[OVER]${NC} ${YELLOW}$user${NC} (${proto}) — ${RED}$ip_count${NC}/${user_limit} IP"
                echo "$user_ips" | while read -r ip; do
                    echo -e "         └─ $ip"
                done
            else
                echo -e " ${GREEN}[OK]${NC}   $user ($proto) — ${GREEN}$ip_count${NC}/${user_limit} IP"
                echo "$user_ips" | while read -r ip; do
                    echo -e "         └─ $ip"
                done
            fi
        fi
    done
fi

if [[ "$xray_total" -eq 0 ]]; then
    echo -e " ${CYAN}(tidak ada user Xray yang aktif)${NC}"
fi

# ===== NOOBZVPN =====
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

# ===== SUMMARY =====
total_bandel=$((ssh_bandel + xray_bandel))
echo ""
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ "$total_bandel" -gt 0 ]]; then
    echo -e " ${RED}${BOLD}Total user bandel: $total_bandel${NC} (SSH: $ssh_bandel, Xray: $xray_bandel)"
else
    echo -e " ${GREEN}${BOLD}Semua user dalam limit${NC}"
fi
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ===== LOG TERAKHIR =====
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
