#!/bin/bash
# ========================================================
# patch-menu-quota.sh
#
# Tambah submenu "Cek Xray Quota" dan "Set Xray Quota" ke main menu.
# Entry baru "16. Cek Xray Quota" + "17. Set Xray Quota" beserta case-nya.
#
# Idempotent: aman di-run berkali-kali.
#
# Argumen: $1 = path direktori menu (default /usr/local/sbin)
# ========================================================

set -e

DIR="${1:-/usr/local/sbin}"
MENU="$DIR/menu"

if [ ! -d "$DIR" ]; then
    echo "[patch-menu-quota] ERROR: dir $DIR tidak ada."
    exit 1
fi

if [ ! -f "$MENU" ]; then
    echo "[patch-menu-quota] WARNING: $MENU tidak ada, skip patch entry."
    exit 0
fi

if grep -q "cek-quota" "$MENU" && grep -q "set-quota" "$MENU"; then
    echo "[patch-menu-quota] $MENU: sudah ter-patch, skip."
    exit 0
fi

# Cari anchor di urutan prioritas:
#   1. "Set IP Limit" (dari patch-menu-limit.sh)  -> entry baru 16/17
#   2. "Cek IP Limit"
#   3. "Menu Fail2ban"
#   4. "Seting SlowDNS"
if ! grep -q "Cek Xray Quota" "$MENU"; then
    if grep -q "Set IP Limit" "$MENU"; then
        sed -i '/Set IP Limit/a echo -e " 16. Cek Xray Quota                                 "' "$MENU"
    elif grep -q "Cek IP Limit" "$MENU"; then
        sed -i '/Cek IP Limit/a echo -e " 16. Cek Xray Quota                                 "' "$MENU"
    elif grep -q "Menu Fail2ban" "$MENU"; then
        sed -i '/Menu Fail2ban/a echo -e " 16. Cek Xray Quota                                 "' "$MENU"
    elif grep -q "Seting SlowDNS" "$MENU"; then
        sed -i '/Seting SlowDNS/a echo -e " 16. Cek Xray Quota                                 "' "$MENU"
    else
        echo "[patch-menu-quota] WARNING: tidak menemukan anchor menu, skip."
        exit 0
    fi
fi

if ! grep -q "Set Xray Quota" "$MENU"; then
    sed -i '/Cek Xray Quota/a echo -e " 17. Set Xray Quota                                 "' "$MENU"
fi

if ! grep -q "16) cek-quota" "$MENU"; then
    sed -i '/^\*) menu ;;/i 16) cek-quota ;;' "$MENU"
fi
if ! grep -q "17) set-quota" "$MENU"; then
    sed -i '/^\*) menu ;;/i 17) set-quota ;;' "$MENU"
fi

# Verifikasi
if ! grep -q "Cek Xray Quota" "$MENU"; then
    echo "[patch-menu-quota] ERROR: gagal menambah entry 'Cek Xray Quota' di $MENU." >&2
    exit 1
fi
if ! grep -q "Set Xray Quota" "$MENU"; then
    echo "[patch-menu-quota] ERROR: gagal menambah entry 'Set Xray Quota' di $MENU." >&2
    exit 1
fi
if ! grep -q "16) cek-quota" "$MENU"; then
    echo "[patch-menu-quota] ERROR: gagal menambah case '16) cek-quota' di $MENU." >&2
    exit 1
fi
if ! grep -q "17) set-quota" "$MENU"; then
    echo "[patch-menu-quota] ERROR: gagal menambah case '17) set-quota' di $MENU." >&2
    exit 1
fi

echo "[patch-menu-quota] $MENU: entry + case ditambahkan (terverifikasi)."
