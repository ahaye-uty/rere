#!/bin/bash
# ========================================================
# patch-menu-ports.sh
#
# Update tampilan port di script add-ssh / add-ssh-gege (yang
# di-download dari main.zip upstream) supaya ikut arsitektur
# edge-mux: tambah baris SSH SSL/TLS dan SSH Direct, perluas
# port WS HTTP/TLS dan Socks5.
#
# Idempotent: aman di-run berkali-kali; baris baru hanya
# di-tambah kalau belum ada.
#
# Argumen: $1 = path direktori berisi add-ssh* (default /usr/local/sbin)
# ========================================================

set -e

DIR="${1:-/usr/local/sbin}"

if [ ! -d "$DIR" ]; then
    echo "[patch-menu-ports] ERROR: dir $DIR tidak ada."
    exit 1
fi

patch_file() {
    local f="$1"
    if [ ! -f "$f" ]; then
        return 0
    fi
    # Idempotent: skip kalau sudah punya marker baris SSH SSL.
    if grep -qE 'Port SSH SSL' "$f"; then
        echo "[patch-menu-ports] $f: sudah ter-patch, skip."
        return 0
    fi

    # ------ HTML/Telegram block (baris dengan <b>...</b><code>...</code>) ------
    # Update Port OpenSSH -> SSH Direct (multiport list)
    sed -i 's|<b>Port OpenSSH:</b> <code>443</code>|<b>Port SSH Direct:</b> <code>22, 109, 443, 80, 3303</code>\n<b>Port SSH SSL/TLS:</b> <code>443, 80</code>|' "$f"
    # Update Port WS HTTP / TLS / Socks5 multiport
    sed -i 's|<b>Port WS HTTP:</b> <code>80, 2082</code>|<b>Port WS HTTP:</b> <code>80, 2080, 2082</code>|' "$f"
    sed -i 's|<b>Port WS TLS:</b> <code>443</code>|<b>Port WS TLS:</b> <code>443, 2443</code>|' "$f"
    sed -i 's|<b>Port Socks5:</b> <code>443, 1080</code>|<b>Port Socks5:</b> <code>1080, 443, 2443</code>|' "$f"

    # ------ Plain echo block ------
    sed -i 's|^\(echo -e "\)\( *\)Port OpenSSH: 443"|\1\2Port SSH Direct: 22, 109, 443, 80, 3303"\n\1\2Port SSH SSL/TLS: 443, 80"|' "$f"
    sed -i 's|^\(echo -e "\)\( *\)Port WS HTTP: 80, 2082"|\1\2Port WS HTTP: 80, 2080, 2082"|' "$f"
    sed -i 's|^\(echo -e "\)\( *\)Port WS TLS: 443"|\1\2Port WS TLS: 443, 2443"|' "$f"
    sed -i 's|^\(echo -e "\)\( *\)Port Socks5: 443, 1080"|\1\2Port Socks5: 1080, 443, 2443"|' "$f"

    echo "[patch-menu-ports] $f: ter-patch."
}

for f in add-ssh add-ssh-gege; do
    patch_file "$DIR/$f"
done
