#!/bin/bash
# ========================================================
# patch-menu-limit.sh
#
# Tambah submenu "Cek IP Limit" dan "Set IP Limit" ke main menu.
# Entry baru "14. Cek IP Limit" + "15. Set IP Limit" beserta case-nya.
#
# Idempotent: aman di-run berkali-kali.
#
# Argumen: $1 = path direktori menu (default /usr/local/sbin)
# ========================================================

set -e

DIR="${1:-/usr/local/sbin}"
MENU="$DIR/menu"

if [ ! -d "$DIR" ]; then
    echo "[patch-menu-limit] ERROR: dir $DIR tidak ada."
    exit 1
fi

if [ ! -f "$MENU" ]; then
    echo "[patch-menu-limit] WARNING: $MENU tidak ada, skip patch entry."
    exit 0
fi

if grep -q "cek-limit" "$MENU" && grep -q "set-limit" "$MENU"; then
    echo "[patch-menu-limit] $MENU: sudah ter-patch, skip."
    exit 0
fi

if ! grep -q "Cek IP Limit" "$MENU"; then
    if grep -q "Menu Fail2ban" "$MENU"; then
        sed -i '/Menu Fail2ban/a echo -e " 14. Cek IP Limit                                   "' "$MENU"
    elif grep -q "Seting SlowDNS" "$MENU"; then
        sed -i '/Seting SlowDNS/a echo -e " 14. Cek IP Limit                                   "' "$MENU"
    else
        echo "[patch-menu-limit] WARNING: tidak menemukan anchor menu, skip."
        exit 0
    fi
fi

if ! grep -q "Set IP Limit" "$MENU"; then
    sed -i '/Cek IP Limit/a echo -e " 15. Set IP Limit                                   "' "$MENU"
fi

if ! grep -q "14) cek-limit" "$MENU"; then
    sed -i '/^\*) menu ;;/i 14) cek-limit ;;' "$MENU"
fi
if ! grep -q "15) set-limit" "$MENU"; then
    sed -i '/^\*) menu ;;/i 15) set-limit ;;' "$MENU"
fi

if ! grep -q "Cek IP Limit" "$MENU"; then
    echo "[patch-menu-limit] ERROR: gagal menambah entry 'Cek IP Limit' di $MENU." >&2
    exit 1
fi
if ! grep -q "Set IP Limit" "$MENU"; then
    echo "[patch-menu-limit] ERROR: gagal menambah entry 'Set IP Limit' di $MENU." >&2
    exit 1
fi
if ! grep -q "14) cek-limit" "$MENU"; then
    echo "[patch-menu-limit] ERROR: gagal menambah case '14) cek-limit' di $MENU." >&2
    exit 1
fi
if ! grep -q "15) set-limit" "$MENU"; then
    echo "[patch-menu-limit] ERROR: gagal menambah case '15) set-limit' di $MENU." >&2
    exit 1
fi

echo "[patch-menu-limit] $MENU: entry + case ditambahkan (terverifikasi)."
