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

> [**Port Information**](#Port-Information)

> [**Donate**](#Donate)

---

## About

This autoscript is a lifetime free autoscript with simple xray x noobzvpns multiport all os features. Xray-core supports vmess/vless/trojan over WebSocket, gRPC, and HTTPUpgrade transports.

---
## Install

``🚀 Installation Guide``
```html
apt update && apt install wget curl screen gnupg openssl perl binutils -y && wget -O install.sh "https://raw.githubusercontent.com/sugengagung2020-maker/rere/main/install.sh" && chmod +x install.sh && screen -S fn ./install.sh; if [ $? -ne 0 ]; then rm -f install.sh; fi
```

> Cukup satu command di atas. Inbound HTTPUpgrade (`/vless-hup`, `/vmess-hup`, `/trojan-hup`) sudah otomatis aktif setelah install selesai — tidak perlu lagi menjalankan `refresh-hup.sh` secara manual.

``If it stops in the middle of the process``
```html
screen -r fn
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
| **SSH WS TLS**                 | 443, 2443                                |
| **SSH WS HTTP**                | 80, 2080, 2082                           |
| **SLOWDNS**                    | 5300, 53                                 |

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
