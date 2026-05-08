#!/bin/bash
# ========================================================
# Set IP Limit per User (SSH only)
# Ubah limit IP untuk akun SSH (1 atau 2 IP).
# DB shared lokasi /usr/local/etc/xray/limit-ip.db.
# ========================================================

DB_FILE="/usr/local/etc/xray/limit-ip.db"
LIMIT_FILE="/usr/local/etc/xray/limit-ip"
UDP_ENABLE_FILE="/usr/local/etc/xray/limit-udp-enabled"

if [[ -f "$LIMIT_FILE" ]]; then
    DEFAULT_LIMIT=$(cat "$LIMIT_FILE" | tr -d '[:space:]')
else
    DEFAULT_LIMIT=2
fi
[[ ! "$DEFAULT_LIMIT" =~ ^[0-9]+$ ]] && DEFAULT_LIMIT=2

UDP_ENABLED=0
if [[ -f "$UDP_ENABLE_FILE" ]] \
    && [[ "$(tr -d '[:space:]' < "$UDP_ENABLE_FILE")" == "1" ]]; then
    UDP_ENABLED=1
fi

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
ssh_users=$(awk -F: '$7=="/bin/false" || $7=="/usr/sbin/nologin" || $7=="/sbin/nologin" {print $1}' /etc/passwd)
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
if [[ "$UDP_ENABLED" -eq 1 ]]; then
    echo -e " UDP-Custom limit: ${GREEN}ON${NC} (max ${CYAN}${DEFAULT_LIMIT}${NC} flow / source IP)"
else
    echo -e " UDP-Custom limit: ${YELLOW}OFF${NC}"
fi
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo -e " ${BOLD}Pilihan:${NC}"
echo -e " 1. Ubah limit 1 user (SSH)"
echo -e " 2. Set semua SSH ke limit tertentu"
echo -e " 3. Ubah default global"
if [[ "$UDP_ENABLED" -eq 1 ]]; then
    echo -e " 4. UDP-Custom limit: ${GREEN}ON${NC}  -> matikan"
else
    echo -e " 4. UDP-Custom limit: ${YELLOW}OFF${NC} -> nyalakan"
fi
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
4)
    echo -e "${BOLD}UDP-Custom limit${NC}"
    echo -e "  Per-source-IP concurrent flow limit pada port UDP-custom (default 36712)."
    echo -e "  Bukan ban IP -- hanya quota: max ${CYAN}${DEFAULT_LIMIT}${NC} flow simultan/IP."
    echo -e "  TIDAK menyentuh port 443/80 (HTTP-custom & SSH-WS aman)."
    echo -e "  Semantic per-IP, bukan per-user (udp-custom v1.4 tidak expose"
    echo -e "  per-user session info, jadi enforce hanya bisa di network layer)."
    echo ""
    if [[ "$UDP_ENABLED" -eq 1 ]]; then
        read -p "UDP-Custom limit AKTIF. Matikan? (y/n): " yn
        if [[ "$yn" =~ ^[yY]$ ]]; then
            echo "0" > "$UDP_ENABLE_FILE"
            /usr/local/bin/limit-ip >/dev/null 2>&1
            echo -e "${GREEN}UDP-Custom limit dimatikan.${NC} Chain LIMIT-UDP-CUSTOM dihapus."
        fi
    else
        read -p "UDP-Custom limit MATI. Aktifkan? (y/n): " yn
        if [[ "$yn" =~ ^[yY]$ ]]; then
            echo "1" > "$UDP_ENABLE_FILE"
            if ! command -v conntrack >/dev/null 2>&1; then
                echo -e "${YELLOW}Install conntrack tools (untuk cek-limit)...${NC}"
                apt-get install -y conntrack >/dev/null 2>&1 || true
            fi
            /usr/local/bin/limit-ip >/dev/null 2>&1
            echo -e "${GREEN}UDP-Custom limit aktif.${NC} Max ${CYAN}${DEFAULT_LIMIT}${NC} flow/IP pada port UDP-custom."
            echo -e "${CYAN}Cek dengan: cek-limit${NC}"
        fi
    fi
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
