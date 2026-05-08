#!/bin/bash
# ========================================================
# patch-add-limit.sh (SSH only)
#
# Patch add-ssh & add-ssh-gege untuk menambah pilihan
# "Limit IP" (1 atau 2) saat buat akun. Data disimpan di
# /usr/local/etc/xray/limit-ip.db (format: <user> <limit>).
#
# Xray scripts (add-vmess / add-vless / add-tr) TIDAK
# di-patch karena IP limit hanya berlaku untuk SSH.
#
# Idempotent: aman di-run berkali-kali.
# Argumen: $1 = path direktori scripts (default /usr/local/sbin)
# ========================================================

set -e

DIR="${1:-/usr/local/sbin}"
DB_FILE="/usr/local/etc/xray/limit-ip.db"

if [ ! -d "$DIR" ]; then
    echo "[patch-add-limit] ERROR: dir $DIR tidak ada."
    exit 1
fi

mkdir -p "$(dirname "$DB_FILE")" 2>/dev/null || true
touch "$DB_FILE" 2>/dev/null || true

SSH_SNIPPET='read -p "Limit IP (1/2) [default 2]: " iplimit\n[[ "$iplimit" != "1" ]] \&\& iplimit=2\necho "$username $iplimit" >> /usr/local/etc/xray/limit-ip.db'

patched=0

for script in add-ssh add-ssh-gege; do
    FILE="$DIR/$script"
    [ ! -f "$FILE" ] && continue
    if grep -q "Limit IP" "$FILE"; then
        echo "[patch-add-limit] $script: sudah ter-patch, skip."
        continue
    fi
    if grep -q 'read -p "Expired ( Days ): " masa' "$FILE"; then
        sed -i '/read -p "Expired ( Days ): " masa/a '"$SSH_SNIPPET" "$FILE"
        echo "[patch-add-limit] $script: patched."
        patched=$((patched + 1))
    else
        echo "[patch-add-limit] WARNING: $script: pattern 'Expired' tidak ditemukan, skip."
    fi
done

echo "[patch-add-limit] Total patched: $patched scripts."
