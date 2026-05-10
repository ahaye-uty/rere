#!/bin/bash
# ========================================================
# Cek IP Limit (SSH-only display + NoobzVPN)
# Tampilkan status sesi aktif per user SSH.
# User yang melebihi limit ditandai [OVER].
#
# Counting per-SESSION (sama logic dgn menu built-in opsi 3 "Cek
# SSH Login"):
#   1. Ambil PID dengan tag [priv] di cmdline (privsep parent
#      sshd, one per authenticated session) + PID dropbear aktif.
#   2. Cross-reference tiap PID ke auth.log untuk dapet username
#      (sshd: "Accepted password/publickey for USER ...";
#       dropbear: "... auth succeeded for 'USER' ...").
#   3. Group by USER buat hitung sesi.
#
# Yang di-display cuma VPN account (shell /bin/false atau
# /usr/sbin/nologin + UID >= 1000). User admin VPS yang punya
# interactive shell di-skip supaya output bersih dari noise.
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

get_auth_log() {
    if [[ -f /var/log/auth.log ]]; then
        echo /var/log/auth.log
    elif [[ -f /var/log/secure ]]; then
        echo /var/log/secure
    fi
}

# True kalau user adalah VPN account: UID >= 1000 + shell nologin/
# false. User admin VPS dengan shell /bin/bash dll skip.
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

# Output: baris "PID USERNAME" buat tiap sesi SSH/Dropbear aktif.
# Logic sama persis dgn built-in cek-ssh: PID [priv]/dropbear dari
# ps + auth.log lookup.
build_session_map() {
    local logfile
    logfile=$(get_auth_log)
    [[ -z "$logfile" ]] && return

    # === OpenSSH ===
    local sshd_pids
    sshd_pids=$(ps -eo pid=,args= 2>/dev/null | awk '/\[priv\]$/ {print $1}')
    if [[ -n "$sshd_pids" ]]; then
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

sessions=$(build_session_map)
users=$(echo "$sessions" | awk 'NF==2 {print $2}' | sort -u)

for user in $users; do
    # Skip non-VPN users (admin VPS dengan /bin/bash, daemon, root, dll).
    is_vpn_user "$user" || continue

    user_limit=$(get_user_limit "$user")
    pids=$(echo "$sessions" | awk -v u="$user" '$2 == u {print $1}')
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
