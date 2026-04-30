#!/bin/bash
# ========================================================
# patch-menu-fail2ban.sh
#
# Tambah submenu Fail2ban ke main menu (yang di-extract dari main.zip
# upstream). Drop script `menu-fail2ban` ke /usr/local/sbin dan tambah
# entry baru "13. Menu Fail2ban" beserta case-nya di /usr/local/sbin/menu.
#
# Idempotent: aman di-run berkali-kali.
#
# Argumen: $1 = path direktori menu (default /usr/local/sbin)
# ========================================================

set -e

DIR="${1:-/usr/local/sbin}"
MENU="$DIR/menu"
TARGET="$DIR/menu-fail2ban"

if [ ! -d "$DIR" ]; then
    echo "[patch-menu-fail2ban] ERROR: dir $DIR tidak ada."
    exit 1
fi

# ---- 1. Drop menu-fail2ban script ----
cat > "$TARGET" <<'F2BMENU'
#!/usr/bin/env bash
# ========================================================
# Menu Fail2ban
# ========================================================

RED='\e[31m'
GREEN='\e[32m'
YELLOW='\e[33m'
WHITE='\e[97m'
NC='\e[0m'

if ! command -v fail2ban-client >/dev/null 2>&1; then
    clear
    echo -e "${RED}Fail2ban belum terpasang.${NC}"
    echo -e "Pasang dulu dengan:"
    echo -e "  bash <(curl -sL https://raw.githubusercontent.com/sugengagung2020-maker/rere/main/file/setup-fail2ban.sh)"
    echo ""
    read -p "Tekan Enter untuk kembali ke menu utama..." x
    menu
    exit 0
fi

f2b_status_service() {
    if systemctl is-active --quiet fail2ban; then
        echo -e "${GREEN}ON${NC}"
    else
        echo -e "${RED}OFF${NC}"
    fi
}

f2b_total_banned() {
    local total=0 jail count
    for jail in $(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/{print $2}' | tr -d ',\t'); do
        count=$(fail2ban-client status "$jail" 2>/dev/null | awk '/Currently banned/{print $NF}')
        [ -n "$count" ] && total=$((total + count))
    done
    echo "$total"
}

show_menu() {
    clear
    echo -e "─────────────────────────────────────────────────────"
    echo -e "[                Menu Fail2ban                     ]"
    echo -e "─────────────────────────────────────────────────────"
    echo -e " Status service   : $(f2b_status_service)"
    echo -e " Total IP banned  : $(f2b_total_banned)"
    echo -e "─────────────────────────────────────────────────────"
    echo -e " 1. Lihat status semua jail"
    echo -e " 2. Lihat IP yang sedang ke-ban"
    echo -e " 3. Unban IP (manual)"
    echo -e " 4. Restart service fail2ban"
    echo -e " 5. Reload konfigurasi (tanpa restart)"
    echo -e " 6. Lihat log fail2ban (tail 50)"
    echo -e " 7. Edit konfigurasi (jail.local)"
    echo -e " 0. Kembali ke menu utama"
    echo -e "─────────────────────────────────────────────────────"
    read -p "Input option: " opt
    case $opt in
        1) f2b_status_all ;;
        2) f2b_list_banned ;;
        3) f2b_unban_ip ;;
        4) f2b_restart ;;
        5) f2b_reload ;;
        6) f2b_log ;;
        7) f2b_edit ;;
        0) menu ;;
        *) show_menu ;;
    esac
}

f2b_status_all() {
    clear
    echo -e "${YELLOW}=== Status semua jail ===${NC}"
    fail2ban-client status
    echo ""
    for jail in $(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/{print $2}' | tr -d ',\t'); do
        echo -e "${YELLOW}--- $jail ---${NC}"
        fail2ban-client status "$jail"
        echo ""
    done
    read -p "Tekan Enter untuk kembali..." x
    show_menu
}

f2b_list_banned() {
    clear
    echo -e "${YELLOW}=== Daftar IP banned per jail ===${NC}"
    local jail count ips
    for jail in $(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/{print $2}' | tr -d ',\t'); do
        count=$(fail2ban-client status "$jail" 2>/dev/null | awk '/Currently banned/{print $NF}')
        ips=$(fail2ban-client status "$jail" 2>/dev/null | awk -F: '/Banned IP list/{print $2}')
        echo -e "${WHITE}[$jail]${NC} (currently banned: ${count:-0})"
        if [ -n "$ips" ] && [ "$ips" != "" ]; then
            echo "$ips" | tr ' ' '\n' | sed '/^$/d' | sed 's/^/   - /'
        else
            echo "   (kosong)"
        fi
        echo ""
    done
    read -p "Tekan Enter untuk kembali..." x
    show_menu
}

f2b_unban_ip() {
    clear
    echo -e "${YELLOW}=== Unban IP ===${NC}"
    read -p "Masukkan IP yang mau di-unban: " ip
    if [ -z "$ip" ]; then
        echo -e "${RED}IP kosong, batal.${NC}"
        sleep 2
        show_menu
        return
    fi
    echo ""
    local jail unbanned=0
    for jail in $(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/{print $2}' | tr -d ',\t'); do
        if fail2ban-client set "$jail" unbanip "$ip" 2>/dev/null | grep -q '^1'; then
            echo -e "${GREEN}OK: $ip di-unban dari jail $jail${NC}"
            unbanned=$((unbanned + 1))
        fi
    done
    if [ "$unbanned" -eq 0 ]; then
        echo -e "${YELLOW}IP $ip tidak ditemukan di jail manapun (atau sudah ke-unban).${NC}"
    fi
    echo ""
    read -p "Tekan Enter untuk kembali..." x
    show_menu
}

f2b_restart() {
    clear
    echo -e "${YELLOW}=== Restart fail2ban ===${NC}"
    systemctl restart fail2ban
    sleep 1
    if systemctl is-active --quiet fail2ban; then
        echo -e "${GREEN}OK: fail2ban running.${NC}"
    else
        echo -e "${RED}FAIL: fail2ban tidak running. Cek 'journalctl -u fail2ban -n 30'.${NC}"
    fi
    echo ""
    read -p "Tekan Enter untuk kembali..." x
    show_menu
}

f2b_reload() {
    clear
    echo -e "${YELLOW}=== Reload konfigurasi fail2ban ===${NC}"
    if fail2ban-client reload; then
        echo -e "${GREEN}OK: konfigurasi di-reload.${NC}"
    else
        echo -e "${RED}FAIL: reload error. Cek konfigurasi dengan 'fail2ban-client -t'.${NC}"
    fi
    echo ""
    read -p "Tekan Enter untuk kembali..." x
    show_menu
}

f2b_log() {
    clear
    echo -e "${YELLOW}=== Log fail2ban (tail 50) ===${NC}"
    if [ -f /var/log/fail2ban.log ]; then
        tail -50 /var/log/fail2ban.log
    else
        journalctl -u fail2ban -n 50 --no-pager
    fi
    echo ""
    read -p "Tekan Enter untuk kembali..." x
    show_menu
}

f2b_edit() {
    clear
    echo -e "${YELLOW}=== Edit /etc/fail2ban/jail.local ===${NC}"
    echo -e "Setelah edit, jangan lupa Reload (option 5) atau Restart (4)."
    echo ""
    sleep 1
    if command -v nano >/dev/null 2>&1; then
        nano /etc/fail2ban/jail.local
    else
        ${EDITOR:-vi} /etc/fail2ban/jail.local
    fi
    show_menu
}

show_menu
F2BMENU

chmod +x "$TARGET"
echo "[patch-menu-fail2ban] $TARGET: ditulis."

# ---- 2. Patch main menu ----
if [ ! -f "$MENU" ]; then
    echo "[patch-menu-fail2ban] WARNING: $MENU tidak ada, skip patch entry."
    exit 0
fi

# Idempotent: skip kalau sudah pernah ke-patch.
if grep -q "menu-fail2ban" "$MENU"; then
    echo "[patch-menu-fail2ban] $MENU: sudah ter-patch, skip."
    exit 0
fi

# 2a. Tambah baris "13. Menu Fail2ban" di blok Other Menu sebelum garis penutup.
# Cari baris '12. Seting SlowDNS' lalu tambahkan baris baru setelahnya.
sed -i '/^echo -e " 12\. Seting SlowDNS/a echo -e " 13. Menu Fail2ban                                  "' "$MENU"

# 2b. Tambah case branch '13) menu-fail2ban' sebelum '*) menu ;;'
sed -i '/^\*) menu ;;/i 13) menu-fail2ban ;;' "$MENU"

# Post-patch verifikasi: pastikan entry & case branch BENAR-BENAR ada.
# Kalau upstream main.zip berubah format (mis. label "12. SlowDNS" diubah),
# sed di atas tidak match dan entry tidak ke-tambah — tapi exit code tetap 0.
# Kita catch di sini supaya tidak silent-failure.
if ! grep -q "Menu Fail2ban" "$MENU"; then
    echo "[patch-menu-fail2ban] ERROR: gagal menambah entry 'Menu Fail2ban' di $MENU." >&2
    echo "[patch-menu-fail2ban] Kemungkinan format menu upstream berubah. Cek pattern sed." >&2
    exit 1
fi
if ! grep -q "13) menu-fail2ban" "$MENU"; then
    echo "[patch-menu-fail2ban] ERROR: gagal menambah case branch '13) menu-fail2ban' di $MENU." >&2
    exit 1
fi

echo "[patch-menu-fail2ban] $MENU: entry + case ditambahkan (terverifikasi)."
