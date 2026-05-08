#!/bin/bash
# ========================================================
# Cek IP Limit - Tampilkan status IP per user
# Menunjukkan user yang melebihi limit (bandel)
# ========================================================

LIMIT_FILE="/usr/local/etc/xray/limit-ip"
LOG_FILE="/var/log/limit-ip.log"

# Read limit
if [[ -f "$LIMIT_FILE" ]]; then
    LIMIT=$(cat "$LIMIT_FILE" | tr -d '[:space:]')
else
    LIMIT=2
fi
[[ ! "$LIMIT" =~ ^[0-9]+$ ]] && LIMIT=2

RED='\e[31m'
GREEN='\e[32m'
YELLOW='\e[33m'
CYAN='\e[36m'
NC='\e[0m'
BOLD='\e[1m'

clear
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "           ${BOLD}CEK IP LIMIT PER USER${NC}"
echo -e "           Limit aktif: ${CYAN}${LIMIT} IP${NC} per user"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ===== SSH =====
echo ""
echo -e " ${BOLD}═══ SSH / Dropbear ═══${NC}"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

AUTH_LOG="/var/log/auth.log"
[[ -f "/var/log/secure" ]] && AUTH_LOG="/var/log/secure"

ssh_bandel=0
ssh_total=0

if [[ -f "$AUTH_LOG" ]]; then
    grep -i "Accepted password for\|Password auth succeeded" "$AUTH_LOG" > /tmp/.cek-limit-auth.tmp 2>/dev/null

    users=$(awk -F: '$7=="/bin/false" {print $1}' /etc/passwd)
    ssh_pids=$(ps aux 2>/dev/null | grep "\[priv\]" | grep -v grep | awk '{print $2}')
    db_pids=$(ps aux 2>/dev/null | grep -i "[d]ropbear" | awk '{print $2}')

    for user in $users; do
        user_ips=""

        for pid in $ssh_pids; do
            ip=$(grep "sshd\[$pid\]" /tmp/.cek-limit-auth.tmp 2>/dev/null | grep "Accepted password for $user " | awk '{print $11}' | tail -1)
            [[ -n "$ip" ]] && user_ips="$user_ips $ip"
        done

        for pid in $db_pids; do
            ip=$(grep "dropbear\[$pid\]" /tmp/.cek-limit-auth.tmp 2>/dev/null | grep -w "$user" | awk '{print $12}' | tail -1)
            [[ -n "$ip" ]] && user_ips="$user_ips $ip"
        done

        unique_ips=$(echo "$user_ips" | tr ' ' '\n' | grep -oP '\d+\.\d+\.\d+\.\d+' | sort -u)
        ip_count=$(echo "$unique_ips" | grep -c .)

        if [[ "$ip_count" -gt 0 ]]; then
            ssh_total=$((ssh_total + 1))
            if [[ "$ip_count" -gt "$LIMIT" ]]; then
                ssh_bandel=$((ssh_bandel + 1))
                echo -e " ${RED}${BOLD}[OVER]${NC} ${YELLOW}$user${NC} — ${RED}$ip_count${NC}/$LIMIT IP"
                echo "$unique_ips" | while read -r ip; do
                    echo -e "         └─ $ip"
                done
            else
                echo -e " ${GREEN}[OK]${NC}   $user — ${GREEN}$ip_count${NC}/$LIMIT IP"
                echo "$unique_ips" | while read -r ip; do
                    echo -e "         └─ $ip"
                done
            fi
        fi
    done
    rm -f /tmp/.cek-limit-auth.tmp
fi

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
        user_ips=$(grep -w "$user" "$access_log" | tail -n 500 | cut -d " " -f 3 | sed 's/tcp://g' | cut -d ":" -f 1 | sort -u | grep -oP '\d+\.\d+\.\d+\.\d+')
        ip_count=$(echo "$user_ips" | grep -c .)

        if [[ "$ip_count" -gt 0 ]]; then
            xray_total=$((xray_total + 1))

            # Detect protocol type
            proto=""
            grep -q "^### $user " /usr/local/etc/xray/config.json 2>/dev/null && proto="vmess"
            grep -q "^#& $user " /usr/local/etc/xray/config.json 2>/dev/null && proto="vless"
            grep -q "^#! $user " /usr/local/etc/xray/config.json 2>/dev/null && proto="trojan"

            if [[ "$ip_count" -gt "$LIMIT" ]]; then
                xray_bandel=$((xray_bandel + 1))
                echo -e " ${RED}${BOLD}[OVER]${NC} ${YELLOW}$user${NC} (${proto}) — ${RED}$ip_count${NC}/$LIMIT IP"
                echo "$user_ips" | while read -r ip; do
                    echo -e "         └─ $ip"
                done
            else
                echo -e " ${GREEN}[OK]${NC}   $user ($proto) — ${GREEN}$ip_count${NC}/$LIMIT IP"
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

DB_FILE="/etc/noobzvpns/db_user.json"
noobz_bandel=0
noobz_total=0

if [[ -f "$DB_FILE" ]] && command -v jq &>/dev/null; then
    jq -r '.users | keys[]' "$DB_FILE" 2>/dev/null | while read username; do
        user_info=$(jq -r ".users[\"$username\"]" "$DB_FILE")
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
