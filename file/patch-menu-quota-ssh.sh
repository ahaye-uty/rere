#!/bin/bash
# ========================================================
# patch-menu-quota-ssh.sh
#
# Tambah submenu "Cek SSH Quota" dan "Set SSH Quota" ke main menu.
# Entry baru "18. Cek SSH Quota" + "19. Set SSH Quota" beserta case-nya.
#
# Idempotent: aman di-run berkali-kali.
#
# Argumen: $1 = path direktori menu (default /usr/local/sbin)
# ========================================================

set -e

DIR="${1:-/usr/local/sbin}"
MENU="$DIR/menu"

if [ ! -d "$DIR" ]; then
    echo "[patch-menu-quota-ssh] ERROR: dir $DIR tidak ada."
    exit 1
fi

if [ ! -f "$MENU" ]; then
    echo "[patch-menu-quota-ssh] WARNING: $MENU tidak ada, skip patch entry."
    exit 0
fi

if grep -q "cek-quota-ssh" "$MENU" && grep -q "set-quota-ssh" "$MENU"; then
    echo "[patch-menu-quota-ssh] $MENU: sudah ter-patch, skip."
    exit 0
fi

# Cari anchor di urutan prioritas:
#   1. "Set Xray Quota" (dari patch-menu-quota.sh, PR #12)
#   2. "Set IP Limit"   (dari patch-menu-limit.sh, PR #11)
#   3. "Cek Xray Quota"
#   4. "Cek IP Limit"
#   5. "Menu Fail2ban"
if ! grep -q "Cek SSH Quota" "$MENU"; then
    if grep -q "Set Xray Quota" "$MENU"; then
        sed -i '/Set Xray Quota/a echo -e " 18. Cek SSH Quota                                  "' "$MENU"
    elif grep -q "Set IP Limit" "$MENU"; then
        sed -i '/Set IP Limit/a echo -e " 18. Cek SSH Quota                                  "' "$MENU"
    elif grep -q "Cek Xray Quota" "$MENU"; then
        sed -i '/Cek Xray Quota/a echo -e " 18. Cek SSH Quota                                  "' "$MENU"
    elif grep -q "Cek IP Limit" "$MENU"; then
        sed -i '/Cek IP Limit/a echo -e " 18. Cek SSH Quota                                  "' "$MENU"
    elif grep -q "Menu Fail2ban" "$MENU"; then
        sed -i '/Menu Fail2ban/a echo -e " 18. Cek SSH Quota                                  "' "$MENU"
    else
        echo "[patch-menu-quota-ssh] WARNING: tidak menemukan anchor menu, skip."
        exit 0
    fi
fi

if ! grep -q "Set SSH Quota" "$MENU"; then
    sed -i '/Cek SSH Quota/a echo -e " 19. Set SSH Quota                                  "' "$MENU"
fi

if ! grep -q "18) cek-quota-ssh" "$MENU"; then
    sed -i '/^\*) menu ;;/i 18) cek-quota-ssh ;;' "$MENU"
fi
if ! grep -q "19) set-quota-ssh" "$MENU"; then
    sed -i '/^\*) menu ;;/i 19) set-quota-ssh ;;' "$MENU"
fi

if ! grep -q "Cek SSH Quota" "$MENU"; then
    echo "[patch-menu-quota-ssh] ERROR: gagal menambah entry 'Cek SSH Quota' di $MENU." >&2
    exit 1
fi
if ! grep -q "Set SSH Quota" "$MENU"; then
    echo "[patch-menu-quota-ssh] ERROR: gagal menambah entry 'Set SSH Quota' di $MENU." >&2
    exit 1
fi
if ! grep -q "18) cek-quota-ssh" "$MENU"; then
    echo "[patch-menu-quota-ssh] ERROR: gagal menambah case '18) cek-quota-ssh' di $MENU." >&2
    exit 1
fi
if ! grep -q "19) set-quota-ssh" "$MENU"; then
    echo "[patch-menu-quota-ssh] ERROR: gagal menambah case '19) set-quota-ssh' di $MENU." >&2
    exit 1
fi

echo "[patch-menu-quota-ssh] $MENU: entry + case ditambahkan (terverifikasi)."
