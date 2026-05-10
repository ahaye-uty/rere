#!/bin/bash
# ========================================================
# Set IP Limit per User (SSH only)
# Ubah limit IP untuk akun SSH (1 atau 2 IP).
# DB shared lokasi /usr/local/etc/xray/limit-ip.db.
# ========================================================

DB_FILE="/usr/local/etc/xray/limit-ip.db"
LIMIT_FILE="/usr/local/etc/xray/limit-ip"

if [[ -f "$LIMIT_FILE" ]]; then
    DEFAULT_LIMIT=$(cat "$LIMIT_FILE" | tr -d '[:space:]')
else
    DEFAULT_LIMIT=2
fi
[[ ! "$DEFAULT_LIMIT" =~ ^[0-9]+$ ]] && DEFAULT_LIMIT=2

touch "$DB_FILE" 2>/dev/null || true

RED='\e[31m'
GREEN='\e[32m'
YELLOW='\e[33m'
CYAN='\e[36m'
NC='\e[0m'
BOLD='\e[1m'

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

clear
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "          ${BOLD}SET IP LIMIT PER USER (SSH only)${NC}"
echo -e "          Default: ${CYAN}${DEFAULT_LIMIT} IP${NC} per user"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo -e " ${BOLD}═══ Akun SSH ═══${NC}"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
# Hanya user-account beneran (UID >= 1000), bukan daemon
# system seperti `sshd` yang juga punya shell /usr/sbin/nologin.
ssh_users=$(awk -F: '($7=="/bin/false" || $7=="/usr/sbin/nologin" || $7=="/sbin/nologin") && $3>=1000 {print $1}' /etc/passwd)
if [[ -n "$ssh_users" ]]; then
    for u in $ssh_users; do
        lim=$(get_user_limit "$u")
        if [[ "$lim" == "1" ]]; then
            echo -e " $u — limit: ${YELLOW}${lim} IP${NC}"
        else
            echo -e " $u — limit: ${GREEN}${lim} IP${NC}"
        fi
    done
else
    echo -e " ${CYAN}(tidak ada akun SSH)${NC}"
fi

echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo -e " ${BOLD}Pilihan:${NC}"
echo -e " 1. Ubah limit 1 user"
echo -e " 2. Set semua SSH ke limit tertentu"
echo -e " 3. Ubah default global"
echo -e " 0. Kembali"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
read -p "Pilih: " pilih

case $pilih in
1)
    read -p "Input Username: " target_user
    if [[ -z "$target_user" ]]; then
        echo -e "${RED}Username kosong.${NC}"
        sleep 2
        exec "$0"
    fi
    if ! echo "$ssh_users" | grep -qw "$target_user"; then
        echo -e "${RED}User SSH '$target_user' tidak ditemukan.${NC}"
        sleep 2
        exec "$0"
    fi
    current=$(get_user_limit "$target_user")
    echo -e "User: ${YELLOW}$target_user${NC} — limit saat ini: ${CYAN}$current IP${NC}"
    read -p "Set limit IP (1/2): " new_limit
    if [[ "$new_limit" != "1" && "$new_limit" != "2" ]]; then
        echo -e "${RED}Hanya 1 atau 2.${NC}"
        sleep 2
        exec "$0"
    fi
    sed -i "/^$target_user /d" "$DB_FILE" 2>/dev/null
    echo "$target_user $new_limit" >> "$DB_FILE"
    echo -e "${GREEN}Berhasil!${NC} $target_user → limit ${CYAN}$new_limit IP${NC}"
    sleep 2
    exec "$0"
    ;;
2)
    read -p "Set semua akun SSH ke limit (1/2): " new_limit
    if [[ "$new_limit" != "1" && "$new_limit" != "2" ]]; then
        echo -e "${RED}Hanya 1 atau 2.${NC}"
        sleep 2
        exec "$0"
    fi
    count=0
    for u in $ssh_users; do
        sed -i "/^$u /d" "$DB_FILE" 2>/dev/null
        echo "$u $new_limit" >> "$DB_FILE"
        count=$((count + 1))
    done
    echo -e "${GREEN}Berhasil!${NC} $count akun SSH → limit ${CYAN}$new_limit IP${NC}"
    sleep 2
    exec "$0"
    ;;
3)
    echo -e "Default global saat ini: ${CYAN}$DEFAULT_LIMIT IP${NC}"
    read -p "Set default baru (1/2): " new_default
    if [[ "$new_default" != "1" && "$new_default" != "2" ]]; then
        echo -e "${RED}Hanya 1 atau 2.${NC}"
        sleep 2
        exec "$0"
    fi
    echo "$new_default" > "$LIMIT_FILE"
    echo -e "${GREEN}Berhasil!${NC} Default global → ${CYAN}$new_default IP${NC}"
    echo -e "(User yang sudah di-set manual tidak terpengaruh)"
    sleep 3
    exec "$0"
    ;;
0)
    menu 2>/dev/null || true
    ;;
*)
    exec "$0"
    ;;
esac
