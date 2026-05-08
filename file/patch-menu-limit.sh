#!/bin/bash
# ========================================================
# patch-menu-limit.sh
#
# Tambah submenu "Cek IP Limit" ke main menu.
# Entry baru "14. Cek IP Limit" beserta case-nya di /usr/local/sbin/menu.
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

# ---- Patch main menu ----
if [ ! -f "$MENU" ]; then
    echo "[patch-menu-limit] WARNING: $MENU tidak ada, skip patch entry."
    exit 0
fi

# Idempotent: skip kalau sudah pernah ke-patch.
if grep -q "cek-limit" "$MENU"; then
    echo "[patch-menu-limit] $MENU: sudah ter-patch, skip."
    exit 0
fi

# Tambah baris "14. Cek IP Limit" setelah entry terakhir di Other Menu.
# Cari baris yang mengandung 'Menu Fail2ban' (option 13, dari patch sebelumnya).
# Kalau belum ada fail2ban, cari 'Seting SlowDNS' (option 12).
if grep -q "Menu Fail2ban" "$MENU"; then
    sed -i '/Menu Fail2ban/a echo -e " 14. Cek IP Limit                                   "' "$MENU"
elif grep -q "Seting SlowDNS" "$MENU"; then
    sed -i '/Seting SlowDNS/a echo -e " 14. Cek IP Limit                                   "' "$MENU"
else
    echo "[patch-menu-limit] WARNING: tidak menemukan anchor menu, skip."
    exit 0
fi

# Tambah case branch '14) cek-limit' sebelum '*) menu ;;'
sed -i '/^\*) menu ;;/i 14) cek-limit ;;' "$MENU"

# Post-patch verifikasi
if ! grep -q "Cek IP Limit" "$MENU"; then
    echo "[patch-menu-limit] ERROR: gagal menambah entry 'Cek IP Limit' di $MENU." >&2
    exit 1
fi
if ! grep -q "14) cek-limit" "$MENU"; then
    echo "[patch-menu-limit] ERROR: gagal menambah case branch '14) cek-limit' di $MENU." >&2
    exit 1
fi

echo "[patch-menu-limit] $MENU: entry + case ditambahkan (terverifikasi)."
