#!/bin/bash
# ========================================================
# Set IP Limit per User
# Ubah limit IP untuk akun SSH dan Xray
# Pilihan: 1 IP atau 2 IP
# ========================================================

DB_FILE="/usr/local/etc/xray/limit-ip.db"
LIMIT_FILE="/usr/local/etc/xray/limit-ip"

# Read global default
if [[ -f "$LIMIT_FILE" ]]; then
    DEFAULT_LIMIT=$(cat "$LIMIT_FILE" | tr -d '[:space:]')
else
    DEFAULT_LIMIT=2
fi
[[ ! "$DEFAULT_LIMIT" =~ ^[0-9]+$ ]] && DEFAULT_LIMIT=2

# Buat DB kalau belum ada
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
echo -e "          ${BOLD}SET IP LIMIT PER USER${NC}"
echo -e "          Default: ${CYAN}${DEFAULT_LIMIT} IP${NC} per user"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ===== SSH Users =====
echo ""
echo -e " ${BOLD}═══ Akun SSH ═══${NC}"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ssh_users=$(awk -F: '$7=="/bin/false" {print $1}' /etc/passwd)
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

# ===== Xray Users =====
echo ""
echo -e " ${BOLD}═══ Akun Xray (Vmess/Vless/Trojan) ═══${NC}"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
xray_users=$(grep -E '^(###|#&|#!) ' /usr/local/etc/xray/config.json 2>/dev/null | awk '{print $2}' | sort -u)
if [[ -n "$xray_users" ]]; then
    for u in $xray_users; do
        lim=$(get_user_limit "$u")
        proto=""
        grep -q "^### $u " /usr/local/etc/xray/config.json 2>/dev/null && proto="vmess"
        grep -q "^#& $u " /usr/local/etc/xray/config.json 2>/dev/null && proto="vless"
        grep -q "^#! $u " /usr/local/etc/xray/config.json 2>/dev/null && proto="trojan"
        if [[ "$lim" == "1" ]]; then
            echo -e " $u ($proto) — limit: ${YELLOW}${lim} IP${NC}"
        else
            echo -e " $u ($proto) — limit: ${GREEN}${lim} IP${NC}"
        fi
    done
else
    echo -e " ${CYAN}(tidak ada akun Xray)${NC}"
fi

echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo -e " ${BOLD}Pilihan:${NC}"
echo -e " 1. Ubah limit 1 user"
echo -e " 2. Set semua SSH ke limit tertentu"
echo -e " 3. Set semua Xray ke limit tertentu"
echo -e " 4. Ubah default global"
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
    # Cek user exists
    found=0
    echo "$ssh_users" | grep -qw "$target_user" && found=1
    echo "$xray_users" | grep -qw "$target_user" && found=1
    if [[ "$found" -eq 0 ]]; then
        echo -e "${RED}User '$target_user' tidak ditemukan.${NC}"
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
    # Hapus entry lama, tambah baru
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
    read -p "Set semua akun Xray ke limit (1/2): " new_limit
    if [[ "$new_limit" != "1" && "$new_limit" != "2" ]]; then
        echo -e "${RED}Hanya 1 atau 2.${NC}"
        sleep 2
        exec "$0"
    fi
    count=0
    for u in $xray_users; do
        sed -i "/^$u /d" "$DB_FILE" 2>/dev/null
        echo "$u $new_limit" >> "$DB_FILE"
        count=$((count + 1))
    done
    echo -e "${GREEN}Berhasil!${NC} $count akun Xray → limit ${CYAN}$new_limit IP${NC}"
    sleep 2
    exec "$0"
    ;;
4)
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
    menu
    ;;
*)
    exec "$0"
    ;;
esac
