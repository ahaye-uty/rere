<p align="center">
  <img src="https://readme-typing-svg.herokuapp.com?color=red&center=true&vCenter=true&lines=Welcome+to+PROJECT+RERECHAN+[VPN]" alt="Project Rerechan VPN">
</p>

---

<h1 align="center">📡 Project Rerechan VPN</h1>
<p align="center">
  Powerful and secure VPN service with advanced features for all your needs.
</p>

## Docs Index

> [**Docs Index**](#Docs-Index)

> [**About**](#About)

> [**Install**](#Install)

> [**IP Limit (SSH only)**](#-ip-limit-ssh-only)

> [**Bandwidth Quota (Xray + SSH)**](#-bandwidth-quota-xray--ssh)

> [**Account Manager CLI**](#-account-manager-cli)

> [**Port Information**](#Port-Information)

> [**Uninstall**](#-uninstall)

> [**Donate**](#Donate)

---

## About

This autoscript is a lifetime free autoscript with simple xray x noobzvpns multiport all os features. Xray-core supports vmess/vless/trojan over WebSocket, gRPC, and HTTPUpgrade transports.

---
## Install

``🚀 Installation Guide``
```html
apt update && apt install wget curl screen gnupg openssl perl binutils -y && wget -O install.sh "https://raw.githubusercontent.com/ahaye-uty/rere/main/install.sh" && chmod +x install.sh && screen -S fn ./install.sh; if [ $? -ne 0 ]; then rm -f install.sh; fi
```

> Cukup satu command di atas. Fresh install sudah otomatis termasuk:
> - Inbound HTTPUpgrade (`/vless-hup`, `/vmess-hup`, `/trojan-hup`)
> - IP-limit untuk SSH (cron `*/1 * * * *` jalan otomatis)
> - **Bandwidth quota tracker untuk Xray + SSH** (cron `* * * * *`).
>   Pas install ada 2 prompt:
>   `Default quota Xray (GB) [250]:` lalu `Default quota SSH (GB) [250]:`.
>   Saran: `50` untuk HP, `250` untuk STB OpenWRT, `0` untuk unlimited (track only).
> - Menu option **14. Cek IP Limit** / **15. Set IP Limit**
> - Menu option **16. Cek Xray Quota** / **17. Set Xray Quota**
> - Menu option **18. Cek SSH Quota** / **19. Set SSH Quota**
> - Prompt `Limit IP (1/2)` di `add-ssh` / `add-ssh-gege`
> - CLI wrapper `sshman` / `vmessman` / `vlessman` / `trojanman`

``If it stops in the middle of the process``
```html
screen -r fn
```
---

## 🛡️ IP Limit (SSH only)

Limit jumlah device per akun **SSH/Dropbear** (1 atau 2 IP). Di-enforce dengan menghitung child process `sshd` / `sshd-session` / `sshd-auth` / `dropbear` yang dimiliki user — jadi akurat juga untuk koneksi via HTTP Custom / SSH WebSocket (semua loopback `127.0.0.1`, tapi tiap device = 1 child process). Cron jalan tiap 1 menit; kalau over-limit, semua sesi user tsb di-`kill -9`. Device reconnect → cuma N pertama (= limit) yang berhasil.

**Tidak menyentuh iptables sama sekali** → tidak ada risiko block IP HP / admin secara permanen.

**Catatan:** IP limit ini hanya berlaku untuk **SSH/Dropbear**. Xray (vmess/vless/trojan) **tidak** di-limit karena akan butuh `proxy_protocol` end-to-end di nginx → xray supaya real client IP bisa di-extract — tanpa itu, semua koneksi WS terlihat dari `127.0.0.1` dan iptables block bakal merusak proxy chain.

File DB: `/usr/local/etc/xray/limit-ip.db` (format: `<user> <limit>`). Default global: `/usr/local/etc/xray/limit-ip` (default isinya `2`).

Menu utama:
- **14. Cek IP Limit** — tampilkan sesi aktif per user + status NoobzVPN
- **15. Set IP Limit** — ubah limit per user / set semua / ubah default global

Utility lain via shell:
```bash
cek-limit                 # tampilkan status (sama dengan menu 14)
set-limit                 # ubah limit (sama dengan menu 15)
/usr/local/bin/limit-ip   # paksa enforce sekarang (cron jalan otomatis tiap 1 menit)
```

**UDP-Custom tidak di-limit.** `udp-custom` v1.4 itu single-process daemon yang tidak fork per client dan tidak expose per-user session info, jadi limit per-device tidak bisa di-enforce dengan reliable di network layer. Untuk akun yang butuh limit ketat, arahkan user pakai mode SSH/WS instead of UDP-Custom-only.

---

## 📊 Bandwidth Quota (Xray + SSH)

Anti-abuse / anti-share berbasis **kuota bandwidth bulanan per-akun**, bukan per-IP. Cocok buat case STB OpenWRT yang nge-tunnel seluruh isi rumah lewat 1 akun — IP limit gak ke-detect (semua share 1 public IP), tapi kuota bandwidth pasti tembus duluan dari akun normal HP.

Dua sistem terpisah, jalan paralel:

|                       | **Xray quota**                        | **SSH quota**                                  |
|-----------------------|---------------------------------------|------------------------------------------------|
| Coverage              | vmess / vless / trojan                | OpenSSH + Dropbear + SSH-WS + SSH-SSL          |
| Counter source        | `xray api statsquery -reset`          | iptables `QUOTA-SSH` (OUTPUT) + `QUOTA-SSH-IN` (INPUT, via CONNMARK) |
| Blokir saat overlimit | rewrite UUID/password jadi sentinel di `config.json` → `systemctl restart xray` | `usermod -L <user>` + `pkill -KILL -u <user>` (TIDAK block IP di iptables) |
| State DB              | `/usr/local/etc/xray/quota-xray.db`   | `/usr/local/etc/quota-ssh.db`                  |
| Default per-akun      | `/usr/local/etc/quota-xray.conf`      | `/usr/local/etc/quota-ssh.conf`                |
| Menu                  | **16. Cek Xray Quota** / **17. Set Xray Quota** | **18. Cek SSH Quota** / **19. Set SSH Quota** |
| Cron                  | `* * * * * quota-xray` + `1 0 1 * * quota-xray --monthly-reset` | `* * * * * quota-ssh` + `2 0 1 * * quota-ssh --monthly-reset` |

Setiap row di DB: `USER|LIMIT_MB|USED_BYTES|STATUS|RESET_DATE` (pipe-separated). `STATUS` ∈ `active | blocked | unlimited`. `LIMIT_MB=0` artinya unlimited (cuma di-track, no auto-block). `RESET_DATE` = tanggal reset bulanan berikutnya (= tanggal 1 bulan depan); reset bulanan otomatis nge-zero `USED_BYTES` + auto-unblock semua user yang blocked.

### Default quota saat install

Fresh install nanya dua-duanya:

```
─── Default Quota Xray (per akun) ───
  -  50  : HP customer (pemakaian normal)
  - 250  : STB OpenWRT (bandwidth besar, default)
  -   0  : Unlimited (track only, no auto-block)
 Default quota Xray (GB) [250]: _

─── Default Quota SSH (per akun) ───
  -  50  : HP customer (pemakaian normal)
  - 250  : STB OpenWRT (bandwidth besar, default)
  -   0  : Unlimited (track only, no auto-block)
 Default quota SSH (GB) [250]: _
```

Jawaban disimpan di `/usr/local/etc/quota-{xray,ssh}.conf` (`DEFAULT_QUOTA_MB=<MB>`). Admin bisa edit conf-nya langsung kapan aja tanpa rerun install. **DB row user yang udah ada gak di-overwrite** saat re-deploy — kuota custom per-user yang sudah di-set lewat menu 17 / 19 tetep dipertahankan.

> **GB binary vs GB desimal.** Prompt ambil angka GB lalu kali `1024`. Jadi `250 → 256000 MB` ≈ 268 GB desimal. Kalau mau pas 250 GB desimal yang biasa di-advertise ISP, isi `244` (≈ 244 GiB ≈ 250 GB desimal).

### Bootstrap di VPS existing (tanpa fresh install)

Kalau VPS udah jalan tapi belum punya fitur quota, jalanin satu-baris:

```bash
# Xray quota
bash <(curl -sL https://raw.githubusercontent.com/ahaye-uty/rere/main/file/activate-quota.sh)

# SSH quota
bash <(curl -sL https://raw.githubusercontent.com/ahaye-uty/rere/main/file/activate-quota-ssh.sh)
```

Pertama kali jalan, masing-masing nanya default quota (sama persis kayak fresh install). Re-run berikutnya **skip prompt** kalau conf udah ada (pilihan admin di-preserve).

### CLI wrapper

```bash
# Status (read-only)
cek-quota            # tampilkan usage + quota + status semua user Xray
cek-quota-ssh        # tampilkan usage + quota + status semua user SSH (+ PENDNG row buat akun yg belum kena cron tick)

# Manage interaktif (set quota, reset, block, unblock — numbered picker)
set-quota            # menu untuk Xray  (juga di main menu opsi 17)
set-quota-ssh        # menu untuk SSH    (juga di main menu opsi 19)

# Manage langsung tanpa menu
quota-xray --reset            # reset usage SEMUA user xray + auto-unblock
quota-xray --reset <user>     # reset 1 user
quota-xray --block <user>     # block manual
quota-xray --unblock <user>   # unblock manual
quota-xray --monthly-reset    # alias --reset (dipanggil cron awal bulan)

quota-ssh  --reset            # idem untuk SSH
quota-ssh  --reset <user>
quota-ssh  --block <user>
quota-ssh  --unblock <user>
quota-ssh  --monthly-reset
```

### Ganti default global tanpa edit script

```bash
echo "DEFAULT_QUOTA_MB=51200"  > /usr/local/etc/quota-xray.conf    # 50 GB untuk paket HP
echo "DEFAULT_QUOTA_MB=256000" > /usr/local/etc/quota-ssh.conf     # 250 GB untuk paket STB
```

Conf di-source tiap cron tick + tiap kali `cek-quota` / `cek-quota-ssh` jalan, jadi gak perlu restart apa-apa. Akun *baru* (yang belum ada di DB) pake default baru; akun *lama* tetep pake kuota custom yang udah ke-set.

### Detail teknis SSH quota (CONNMARK bidirectional)

`-m owner --uid-owner` di iptables cuma match di chain `OUTPUT` — kalo cuma count itu, **bytes download bakal ke-undercount drastis** (request kecil, response besar masuk lewat INPUT tanpa socket-owner). Solusinya:

1. Di chain `QUOTA-SSH` (OUTPUT): rule `-m owner --uid-owner <UID> -j CONNMARK --set-mark <UID>` nge-tag setiap connection yang dibuka user, lalu rule kedua `-m owner --uid-owner <UID> ... -j RETURN` nge-count outgoing bytes-nya.
2. Di chain `QUOTA-SSH-IN` (INPUT): rule `-m connmark --mark <UID> ... -j RETURN` nge-count incoming bytes untuk setiap conntrack entry yang udah di-tag tadi.
3. Cron tiap menit: `iptables-save -c` → parse `[pkts:bytes]` + comment per-user → SUM OUT + IN → `iptables -Z` reset counter → tambahin ke `USED_BYTES` di DB.

User yang di-block: `/etc/shadow` line-nya di-backup ke `/usr/local/etc/quota-ssh-blocked/<user>`, terus `usermod -L` + `pkill -KILL -u`. Reversible 100% lewat `quota-ssh --unblock`. **Tidak ada IP block di iptables** — admin gak akan accidentally lock dirinya sendiri.

> Filter user yang ke-track: UID ≥ 1000 **AND** shell ∈ `/usr/sbin/nologin | /bin/false | /sbin/nologin`. Admin user (shell login normal, root, dll) **otomatis ke-skip** — bukan kandidat reseller account.

---

## 👤 Account Manager CLI

Wrapper CLI buat manajemen akun dari shell (selain menu interaktif). Cocok untuk integrasi bot Telegram / API.

**SSH (`sshman`) — dengan IP limit:**
```bash
sshman add <username> <password> [iplimit 1/2]    # default iplimit = 2
sshman check <username>
sshman del <username>
sshman unlock <username>                          # reset faillock + pam_tally2
```

**Xray (`vmessman` / `vlessman` / `trojanman`) — tanpa IP limit:**
```bash
vmessman  add | check | renew | del  <username> [days]   # default 30 hari
vlessman  add | check | renew | del  <username> [days]
trojanman add | check | renew | del  <username> [days]
```

---

## 🌐 Port Information
| **Service**                    | **Port(s)**                              |
|--------------------------------|------------------------------------------|
| **XRAY Vmess WS TLS**          | 443, 2443                                |
| **XRAY Vmess WS None TLS**     | 80, 2080, 2082                           |
| **XRAY Vmess gRPC**            | 443, 2443                                |
| **XRAY Vmess HTTPUpgrade TLS** | 443, 2443                                |
| **XRAY Vmess HTTPUpgrade NTLS**| 80, 2080, 2082                           |
| **XRAY Vless WS TLS**          | 443, 2443                                |
| **XRAY Vless WS None TLS**     | 80, 2080, 2082                           |
| **XRAY Vless gRPC**            | 443, 2443                                |
| **XRAY Vless HTTPUpgrade TLS** | 443, 2443                                |
| **XRAY Vless HTTPUpgrade NTLS**| 80, 2080, 2082                           |
| **XRAY Trojan WS**             | 443, 2443                                |
| **XRAY Trojan gRPC**           | 443, 2443                                |
| **XRAY Trojan HTTPUpgrade**    | 443, 2443                                |
| **NoobzVPN HTTP**              | 80, 2080, 2082                           |
| **NoobzVPN HTTP(S)**           | 443, 2443                                |
| **UDP Custom**                 | 443, 2443, 80, 36712, 1-65535            |
| **SOCKS5**                     | 1080, 443, 2443                          |
| **SSH Direct (OpenSSH)**       | 22, 109, 443, 80, 3303                   |
| **SSH SSL/TLS (stunnel)**      | 443, 80                                  |
| **SSH Dropbear**               | 111                                      |
| **SSH WS TLS**                 | 443, 2443                                |
| **SSH WS HTTP**                | 80, 2080, 2082                           |
| **SLOWDNS**                    | 5300, 53                                 |

> **SSH SSL/TLS + Xray HUP/WS-TLS dengan SNI bebas (inject bug-host)** —
> arsitektur "edge-mux": TLS publik diterminasi dulu oleh `stunnel` (cert
> xray), lalu bytes plain-textnya dirute oleh `sslh-internal` berdasarkan
> protokol — HTTP → nginx → xray, SSH → OpenSSH:22. Karena routing
> dilakukan setelah dekripsi (bukan dari SNI), klien inject yang pakai SNI
> apa pun (`live.iflix.com`, `bug.id`, dll) tetap bisa konek di kedua
> jenis layanan: xray HUP/WS-TLS dan SSH SSL.
>
> **SSH Direct di port 443/80** adalah raw SSH (tanpa TLS) yang dimultiplex oleh sslh. Untuk inject app yang pakai mode HTTP-only / payload custom tanpa TLS.

---

## 🧹 Uninstall

Hapus tuntas autoscript Rere dari VPS — stop+disable semua service, apt purge package proxy-spesifik, hapus config dir + binary + systemd unit + cron entry + iptables rules, dan (opsional) hapus akun VPN. **Destructive, idempotent.**

```bash
bash <(curl -sL https://raw.githubusercontent.com/ahaye-uty/rere/main/file/uninstall.sh)
```

Script bakal nanya konfirmasi (ketik `UNINSTALL` huruf besar) sebelum eksekusi. Flag opsional:

| Flag              | Efek                                                                   |
|-------------------|------------------------------------------------------------------------|
| `--yes` / `-y`    | Skip prompt konfirmasi (untuk pemakaian otomatis).                     |
| `--keep-packages` | Jangan `apt purge` (cuma hapus config + service + binary).             |
| `--keep-users`    | Jangan hapus akun VPN (UID ≥ 1000 + shell `nologin` / `false`).        |

Yang **DI-HAPUS**:
- Service: `xray`, `nginx`, `sslh`, `sslh-internal`, `stunnel-ssh`, `dropbear`, `udp-custom`, `noobzvpns`, `badvpn`, `proxy`, `server` (REST API), `danted`, `fail2ban`.
- Package (apt purge): `sslh`, `stunnel4`, `dante-server`, `libnginx-mod-stream`, `nginx`, `fail2ban`, `dropbear`.
- Xray-core (lewat installer XTLS standar atau `rm`).
- Cron entries: `limit-ip`, `quota-xray`, `quota-ssh`, `xp`, `backup`, `access.log` rotator.
- iptables: chain `QUOTA-SSH`, `QUOTA-SSH-IN`, `LIMIT-UDP-CUSTOM`, `LIMIT-IP` (kalau ada) + NAT redirect 443/80 yang dipasang installer.
- File: `/usr/local/etc/{xray,quota-*}`, `/etc/{udp,noobzvpns,sslh,stunnel,api,issue.net,xray,nginx,fail2ban,danted.conf}`, `/var/log/{xray,quota-*}`, `/root/{.acme.sh,.config/rclone,domain,.ip}`, `/etc/current_version`.
- Binary CLI: `menu`, `add-*` / `del-*` / `cek-*` / `set-*`, `sshman` / `vmessman` / `vlessman` / `trojanman`, `quota-xray` / `quota-ssh`, `limit-ip`, `proxy`, `badvpn`, `/usr/bin/{server,noobzvpns}`.
- Revert modifikasi: hapus `Port 109` + `Port 3303` + `Banner` di `sshd_config`, `nameserver 1.1.1.1` di `/etc/resolv.conf`, auto-run `menu` di `/root/.profile`.
- (Default) Akun VPN: semua user UID ≥ 1000 dengan shell `/usr/sbin/nologin` / `/bin/false` / `/sbin/nologin`.

Yang **TIDAK DI-HAPUS**:
- Akun admin (shell login normal) + `root`.
- SSH host keys.
- Hostname, networking dasar OS.
- Package umum (curl, wget, jq, iptables, dll).

> **Catatan:** kalau VPS-nya cuma dipakai buat autoscript Rere doang, **reinstall OS dari panel provider** jauh lebih bersih + cepet (5-10 menit) drpd pake script ini. Pake `uninstall.sh` kalau emang ada data lain di VPS yang gak boleh ke-wipe.

Setelah script selesai, disarankan `reboot` supaya port 443/80 ke-release total + service residual ke-clean.

---
## PATH CUSTOM
- vmess websocket
`/vmess` (also reachable via the `/` multipath upstream)

- vless websocket
`/vless`

- trojan websocket
`/trojan-ws`

- httpupgrade paths (vmess / vless / trojan)
`/vmess-hup` `/vless-hup` `/trojan-hup`

- gRPC service names
`vmess-grpc` `vless-grpc` `trojan-grpc`

---

## ALPN
---
| Protocol   | Description                |
|------------|----------------------------|
| HTTP/1.1   | Standard HTTP              |
| h2         | HTTP/2 (Multiplexing)      |
---

## OS Support

- Debian 10 -> 12 [ Tested ]
- Ubuntu 20.04 -> 24.04 [ Tested ]
- Kali Linux Rolling [ Tested ]
- Other? [ Soon ]

Detail: Ubuntu. We have tried testing on all LTS and Non LTS versions with code .04 and .10

---

## REST API

[API](./API.md)

---

## BIOT Plugin
- BOT TELEGRAM GUI SCRIPT 
- BOT NOTIFICATION AUTO BACKUP DATABASE

---

## Support

Please join the following Telegram groups and channels to get information about Patches or things related to improving script functions.
- Telegram : [Rerechan02](https://t.me/Rerechan02)
- Telegram Channel : [Project Rerechan](https://t.me/project_rerechan)


## DONATE
- BTC
`1GS4zqRvi1nLJU39mvudJCumuVT6Txkr6w`
---
- USDT TRON(TRC20)
`TEqnt3ahz1mQvyfQPdkYsXufDxEaiyFFXV`
---
- TRX [ Network TRX ]
`TEqnt3ahz1mQvyfQPdkYsXufDxEaiyFFXV`
---
- BNB
`0x5320479f39d88b3739b86bfcc8c96c986baa5746`
---
- ETH
`0x0492aed81dfbfbafdc7b2f88afd4f494c3f6fcb7`
---
- DOGE
`DDXTGN6iNa4BGkYYkE46VY5yS2rrcv3bgh`
---
