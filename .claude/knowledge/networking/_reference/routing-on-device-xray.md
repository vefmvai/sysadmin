---
knowledge_domain: vpn
layer: reference
last_researched: 2026-05-22
ttl_days: 60
sources_checked:
  - https://xtls.github.io/en/config/routing.html
  - https://xtls.github.io/en/config/inbounds/socks.html
  - https://github.com/XTLS/Xray-core
  - практический опыт настройки (2026-05-22)
---

# Гибкая маршрутизация НА УСТРОЙСТВЕ через Xray (терминал) — для энтузиастов

Этот документ — **альтернативный, НЕ дефолтный** способ для **десктопа**
(macOS/Linux/Windows). Split (РФ → direct, foreign → proxy, реклама → block)
делается локально через Xray-core, запущенный в терминале/как сервис.
Подходит для пользователя, который работает с агентом-сисадмином и не боится
терминала. Дефолт — серверная маршрутизация (`routing-server-3xui.md`).

Читают: персона при запросе «настрой маршрутизацию через Xray на компе»;
скиллы `/configure-vpn-routing`, `/generate-client-config` (desktop-часть).

Связан с:
- `routing-server-3xui.md` (дефолтный путь — split на сервере; тот же Xray-синтаксис)
- `routing-on-device-singbox.md` (то же на ядре sing-box, GUI-клиенты)
- `xray-mac-chain.md` (Xray на Mac для chain-bypass Claude Code — другой сценарий, см. §0)
- `vpn-consultation-flow.md` (сценарий консультации, hub)

---

## §0 Когда этот файл, а когда соседние

| Хочу... | Смотри |
|---|---|
| split РФ/foreign на устройстве, простой клиент с GUI | `routing-on-device-singbox.md` |
| split РФ/foreign на устройстве через Xray в терминале | **этот файл** |
| chain-bypass (VLESS→VLESS) специально для Claude Code на Mac, proxy-only | `xray-mac-chain.md` |
| вообще не настраивать устройство, всё на сервере (дефолт) | `routing-server-3xui.md` |

**Важно про границу с `xray-mac-chain.md`:** тот документ описывает proxy-only
chain (две VLESS-ноды через `dialerProxy`, без route/TUN, только для VSCode/Claude
Code). Здесь — про **полноценный routing-split** по geoip/geosite на устройстве
(весь системный трафик через TUN, развилка РФ/foreign локально). Это разные
сценарии; не смешивать.

---

## §1 Почему Xray на устройстве — рабочая, но нишевая схема

**Плюсы:**
- Xray-синтаксис routing **идентичен серверному** (`routing-server-3xui.md` §4) —
  одни и те же `geosite:ru`, `geoip:ru`, `outboundTag`. Если сисадмин уже умеет
  серверный конфиг, локальный пишется так же.
- Xray умеет **chain через `dialerProxy`** (VLESS→VLESS), чего нет в sing-box
  (см. `xray-mac-chain.md` — issue SagerNet/sing-box#1562 закрыт «not planned»).
- Ставится через терминал (`brew`, бинарник с GitHub) — хорошо ложится на работу
  с агентом-сисадмином.

**Минусы / почему нишевая:**
- Нет «приличного» нативного GUI под routing-split (в отличие от
  GUI.for.SingBox для sing-box). Конфиг правится руками в JSON.
- TUN на Xray-core на десктопе — отдельная морока (Xray сам не поднимает
  системный TUN так гладко, как sing-box; часто нужен tun2socks-слой, который
  конфликтен — см. `xray-mac-chain.md` антипаттерн tun2proxy).
- На мобильных Xray-routing руками — только через клиенты вроде v2rayNG/Happ,
  где raw route-конфиг доступен ограниченно.

Вывод: эта схема — для **десктопа энтузиаста**, которому нужен либо chain
(тогда чаще `xray-mac-chain.md`), либо привычный Xray-синтаксис. Для большинства
on-device — проще sing-box (`routing-on-device-singbox.md`); для большинства
вообще — сервер (`routing-server-3xui.md`).

---

## §2 Установка Xray-core

```bash
# macOS
brew install xray

# Linux — официальный установщик
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# Любая ОС — бинарник
# https://github.com/XTLS/Xray-core/releases  (Xray-{os}-{arch}.zip)
```

Запуск: `xray run -config ~/.config/xray/config.json`. Для постоянной работы —
launchd (Mac) / systemd (Linux) / nssm (Windows).

---

## §3 Локальный конфиг: split по geoip/geosite

Структура: SOCKS/HTTP inbound на localhost → routing-правила → outbound
(direct для РФ, upstream для foreign, blackhole для рекламы).

```json
{
  "inbounds": [
    {
      "tag": "socks-in",
      "listen": "127.0.0.1",
      "port": 10808,
      "protocol": "socks",
      "settings": { "udp": true },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }
  ],
  "outbounds": [
    { "tag": "direct",  "protocol": "freedom" },
    { "tag": "blocked", "protocol": "blackhole" },
    {
      "tag": "upstream",
      "protocol": "vless",
      "settings": { "...": "VLESS на РФ-VPS или провайдера" }
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "direct" },
      { "type": "field", "domain": ["geosite:category-ads-all"], "outboundTag": "blocked" },
      { "type": "field", "ip": ["geoip:ru"], "outboundTag": "direct" },
      { "type": "field", "domain": ["geosite:category-ru", "regexp:.+\\.ru$", "regexp:.+\\.su$", "regexp:.+\\.xn--p1ai$"], "outboundTag": "direct" },
      { "type": "field", "domain": ["...явный список РФ-доменов..."], "outboundTag": "direct" },
      { "type": "field", "network": "tcp,udp", "outboundTag": "upstream" }
    ]
  }
}
```

- Порядок правил, geoip/geosite, явный список РФ-доменов — **те же, что в
  `routing-server-3xui.md` §4-5** (это Xray, синтаксис общий).
- `sniffing` на inbound **обязателен** для domain-правил (та же логика, что
  `routing-server-3xui.md` §6) — без него domain не извлекается из TLS SNI.
- `domainStrategy: "IPIfNonMatch"` — Xray резолвит домен в IP и проверяет
  geoip-правила, если не совпало по домену. Важно для полноты РФ-direct.

geoip.dat/geosite.dat Xray тянет автоматически (или кладутся рядом с бинарником).

---

## §4 Как трафик попадает в локальный Xray

Xray поднимает только SOCKS/HTTP **inbound на localhost** — он не перехватывает
системный трафик сам. Варианты «как направить трафик в него»:

1. **System proxy / per-app proxy** — указать приложению `socks5://127.0.0.1:10808`.
   Простой, но ловит только приложения, знающие про прокси (браузер — да,
   произвольная программа — нет). Аналог SOCKS5-режима, см. `vpn-consultation-flow.md` §5.3.
2. **HTTP-bridge через privoxy** — для программ, понимающих только HTTP_PROXY
   (Claude Code/undici не умеет SOCKS5): privoxy `forward-socks5 / 127.0.0.1:10808 .`
   на :8118 (см. `xray-mac-chain.md` §2). Затем `HTTPS_PROXY=http://127.0.0.1:8118`.
3. **TUN через tun2socks-слой** — для перехвата ВСЕГО системного трафика.
   ⚠️ Конфликтен (tun2proxy правит routes/DNS и не чистит — антипаттерн в
   `xray-mac-chain.md`). Если нужен полный TUN-перехват с гибким routing — проще
   взять sing-box (`routing-on-device-singbox.md`), он поднимает TUN нативно.

**Практический вывод:** Xray on-device хорош для **proxy-режима** (браузер +
программы через HTTP_PROXY). Для полного системного TUN-перехвата с routing —
sing-box удобнее.

---

## §5 macOS GUI-приложения и env (грабля)

GUI-приложения на macOS (VSCode) **не наследуют** shell environment. Передать им
proxy можно только через `launchctl setenv` + полный перезапуск приложения:

```bash
launchctl setenv HTTPS_PROXY http://127.0.0.1:8118
launchctl setenv HTTP_PROXY  http://127.0.0.1:8118
# затем quit → open VSCode (кеширует env при старте)
```

Детали и скрипты управления (vpn-on/vpn-off/emergency-reset) — `xray-mac-chain.md` §3-4.

---

## §6 Связи

- **Дефолтный путь (split на сервере, тот же Xray-синтаксис):** `routing-server-3xui.md`
- **On-device через sing-box (GUI, нативный TUN):** `routing-on-device-singbox.md`
- **Xray chain-bypass для Claude Code на Mac (proxy-only):** `xray-mac-chain.md`
- **Сценарий консультации, hub:** `vpn-consultation-flow.md`
- **Теория протоколов:** `vpn-protocols.md`
- **Скиллы:** `/configure-vpn-routing`, `/generate-client-config`
