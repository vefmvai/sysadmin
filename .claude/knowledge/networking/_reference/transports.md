---
knowledge_domain: vpn
layer: reference
last_researched: 2026-05-17
ttl_days: 60
sources_checked:
  - https://xtls.github.io/en/config/transport.html
  - https://xtls.github.io/en/config/transports/httpupgrade.html
  - https://xtls.github.io/en/config/transports/mkcp.html
  - https://xtls.github.io/en/config/features/browser_dialer.html
  - https://github.com/XTLS/Xray-core/releases
  - https://github.com/XTLS/Xray-core/discussions/2950
  - https://github.com/XTLS/Xray-core/discussions/3518
  - https://github.com/XTLS/Xray-core/discussions/3638
  - https://github.com/XTLS/Xray-core/discussions/4113
  - https://github.com/XTLS/Xray-core/discussions/5205
  - https://github.com/XTLS/Xray-core/discussions/6040
  - https://github.com/XTLS/Xray-core/issues/4406
  - https://github.com/XTLS/Xray-core/issues/4852
  - https://github.com/XTLS/Xray-core/issues/5631
  - https://github.com/XTLS/Xray-core/issues/5712
  - https://github.com/XTLS/Xray-core/issues/5923
  - https://github.com/XTLS/Xray-core/issues/6048
  - https://github.com/XTLS/Xray-core/issues/6085
  - https://github.com/XTLS/Xray-core/pull/451
  - https://github.com/XTLS/REALITY/blob/main/README.en.md
  - https://github.com/XTLS/Xray-examples/blob/main/VLESS-TCP-XTLS-Vision-REALITY/config_server.jsonc
  - https://sing-box.sagernet.org/configuration/outbound/anytls/
  - https://sing-box.sagernet.org/configuration/outbound/vmess/
  - https://sing-box.sagernet.org/configuration/outbound/vless
  - https://sing-box.sagernet.org/configuration/outbound/tuic/
  - https://sing-box.sagernet.org/configuration/shared/v2ray-transport/
  - https://sing-box.sagernet.org/configuration/shared/tls/
  - https://sing-box.sagernet.org/configuration/shared/http-client/
  - https://v2.hysteria.network/docs/advanced/Full-Server-Config/
  - https://v2.hysteria.network/docs/Changelog/
  - https://v2.hysteria.network/docs/developers/Protocol/
  - https://shadowsocks.org/doc/sip022.html
  - https://github.com/Shadowsocks-NET/shadowsocks-specs/blob/main/2022-1-shadowsocks-2022-edition.md
  - https://github.com/net4people/bbs/issues/58
  - https://github.com/SagerNet/sing-box/issues/1652
  - https://github.com/SagerNet/sing-box/issues/2084
  - https://github.com/apernet/hysteria/issues/1364
  - https://github.com/MHSanaei/3x-ui/issues/3901
  - https://github.com/MetaCubeX/reality/blob/main/README.en.md
  - https://github.com/233boy/Xray/issues/118
  - https://podkop.net/docs/dev/singbox-vs-xray-vs-mihomo/
  - https://habr.com/en/articles/990208/
  - https://onlyapps.org/httpupgrade-replacement-websocket/
  - https://newreleases.io/project/github/XTLS/Xray-core/release/v24.9.30
  - https://newreleases.io/project/github/XTLS/Xray-core/release/v25.5.16
  - https://newreleases.io/project/github/XTLS/Xray-core/release/v26.1.23
  - https://newreleases.io/project/github/SagerNet/sing-box/release/v1.7.0
  - https://newreleases.io/project/github/SagerNet/sing-box/release/v1.12.0
---

# Транспорты Xray/sing-box: карта и выбор

Этот документ — карта **транспортного слоя** двух основных ядер семейства V2Ray:
**Xray-core** (XTLS) и **sing-box** (SagerNet). Объясняет разницу «протокол шифрования»
(VLESS, VMess, Trojan, SS, …) vs «транспорт» (TCP, WS, gRPC, XHTTP, HTTPUpgrade, mKCP,
QUIC), и под какую задачу что брать в 2026 году.

Связан с `_reference/vpn-protocols.md` (там — про сами протоколы) и
`_live/frontline-ru.md` (там — про текущий статус блокировок).

---

## §1 Зачем отдельный документ о транспортах

Частая путаница. Когда говорят «VLESS» — имеют в виду протокол шифрования и
аутентификации. Когда говорят «WebSocket» — имеют в виду транспорт. Между ними
есть **матрица сочетаний**: VLESS поверх WS, VLESS поверх XHTTP, VLESS поверх
Reality+RAW, VMess поверх gRPC, Trojan поверх HTTP/2 и т.д.

Транспорт определяет:
- **Как выглядит трафик снаружи** (для DPI). WebSocket = HTTP-upgrade handshake;
  gRPC = HTTP/2; XHTTP = настоящий HTTP-stream к настоящему серверу.
- **Через что можно проксировать.** WebSocket и HTTPUpgrade — через любой
  reverse-proxy (nginx, caddy). gRPC — через HTTP/2-aware proxy. XHTTP — через
  любой HTTP-сервер.
- **Какие CDN поддерживают.** Cloudflare поддерживает WebSocket; HTTPUpgrade —
  не поддерживает Cloudflare Workers (HIGH: Xray-core discussion #2950).
- **Скорость.** XHTTP в режиме `packet-up` — медленнее, чем `stream-up`, но
  совместим с большим количеством веб-серверов и CDN.

---

## §2 Матрица «транспорт × ядро × CDN»

| Транспорт | Xray | sing-box | Cloudflare CDN | Cloudflare Workers | Когда применять |
|---|---|---|---|---|---|
| **TCP (raw)** | ✅ | ✅ | ❌ | ❌ | База, голый TCP, обычно с TLS/Reality |
| **WebSocket** | ✅ | ✅ | ✅ | ✅ | Через CDN; высокая совместимость |
| **HTTP/2 transport** | ✅ | ✅ | ✅ | ✅ | Менее популярно с появлением XHTTP |
| **HTTPUpgrade** | ✅ | ✅ (с v1.7.0) | ✅ | ❌ | Чуть быстрее WS, но **рекомендуется заменить на XHTTP** (HIGH: xtls.github.io) |
| **gRPC** | ✅ | ✅ | ⚠️ ограничения | ❌ | Высокая совместимость, но больше DPI-внимания |
| **QUIC (transport)** | ⚠️ | ✅ (несовместим с Xray-имплементацией) | ❌ | ❌ | Базовый QUIC для goнативных протоколов; в РФ — блокируется как «неопознанный UDP» |
| **mKCP** | ✅ (реструктурирован) | ❌ | ❌ | ❌ | Реликвия; см. §7 |
| **XHTTP** | ✅ (с v24.9.30) | ❌ | ✅ | ✅ | Современный стандарт; обход TLS 1.3 throttling |

**Источник веса HIGH:** официальные доки `xtls.github.io` и `sing-box.sagernet.org`,
release-notes на newreleases.io.

---

## §3 XHTTP (детально)

**XHTTP** — современный транспорт Xray-core, появился в **`v24.9.30`** (30.09.2024)
как объединение исторических `SplitHTTP` (появился 18.06.2024) и `HTTP` транспортов.
В одной обёртке: header padding, XMUX, REALITY-совместимость, HTTP/3.

Источники: [xtls.github.io news](https://xtls.github.io/en/about/news.html),
[Xray-core release v24.9.30](https://newreleases.io/project/github/XTLS/Xray-core/release/v24.9.30).

### 3.1 Режимы (`mode`)

| Режим | uplink/downlink | Когда применять |
|---|---|---|
| **`packet-up`** | разделены | Медленнее, но совместим с большинством веб-серверов и CDN |
| **`stream-up`** | разделены (HTTP/2 stream) | Рекомендуется с XTLS; быстрее `packet-up` |
| **`stream-one`** | НЕ разделены (один stream) | Default при REALITY (в некоторых конфигурациях) |
| **`auto`** | Зависит от контекста | В `v25.5.16` для TLS-клиентов → `packet-up`; для REALITY → `stream-one` |

**Невалидный mode = ошибка валидации конфига** (HIGH: source code Xray-core).

### 3.2 ALPN

- При включённом TLS/REALITY — default ALPN = `"h2"` (HTTP/2)
- Без TLS — HTTP/1.1
- Явно установленный `"h3"` → HTTP/3 (QUIC) — см. discussion #4113

### 3.3 XMUX параметры

`maxConcurrency`, `hMaxRequestTimes`, `hMaxReusableSecs`, `UplinkDataPlacement`
(`auto` | `body` | `cookie` | `header` — **только при `mode: packet-up`**).

Источник: [Xray-core discussion #6040](https://github.com/XTLS/Xray-core/discussions/6040).

### 3.4 Зачем XHTTP создан (предполагаемая мотивация)

В источниках **нет прямой цитаты maintainer-ов** о том, что XHTTP создан как ответ
на TLS 1.3 throttling ASN-уровня (16-KB curtain). Это **частая интерпретация
сообщества**, но maintainer-ы её не подтверждали явно. Документировано только:
консолидация SplitHTTP+HTTP, добавление padding/XMUX/REALITY/HTTP/3.

**Практический эффект, однако, реален:** XHTTP за реальным Nginx с TLS 1.2
сертификатом — обходит curtain Cloudflare/Hetzner/DO, потому что dest-сервер
выглядит как обычный сайт на другом ASN.

❓ Уточнить: явная мотивация maintainer-ов (не подтверждено: 2026-05-17).

### 3.5 Известные баги XHTTP

| Issue | Версия | Симптом | Workaround |
|---|---|---|---|
| **#4406** | recent Release | Memory leak при использовании xhttp+vless+reality+xPaddingBytes+stats. Issue закрыт как «not planned» | Уменьшить scMaxBufferedPosts, отключить stats; обходное решение не предложено |
| **#5631** | v26.1.31 | `sessionPlacement: "path"` валит запуск (на Windows — `unsupported session placement: path`) | Не использовать `sessionPlacement: path` |
| **#5923** | recent | XHTTP+REALITY к **локальному nginx** — `unexpected ccs message`. TCP+REALITY к тому же nginx работает | Использовать удалённый nginx; не локальный |
| **#6048** | recent | VLESS+XHTTP+REALITY — серверные ошибки `failed to read client hello` | Не определён |
| **#6085** | v26.5.3, v26.4.25 | TLS handshake `bad certificate` для XHTTP при валидном Let's Encrypt | Откатиться на более раннюю версию |
| **#5739** | — | Browser Dialer игнорирует `sessionId` и `seqStr` в `packet-up` | Не используется в продакшне |
| **#2997** | — | Host header регистрозависим; нельзя добавить header key `"host"` | Использовать `Host` (с большой H) |

### 3.6 Клиентская поддержка XHTTP

- ✅ **Xray-core** (нативно)
- ✅ **Shadowrocket TF** (iOS)
- ✅ **v2rayN** (Windows)
- ✅ **v2rayNG** (Android)
- ❌ **sing-box** (НЕ поддерживает) — HIGH: подтверждено 2 источниками
  ([podkop.net](https://podkop.net/docs/dev/singbox-vs-xray-vs-mihomo/),
  [Habr 990208](https://habr.com/en/articles/990208/))
- ❌ **Mihomo / Clash.Meta** (НЕ поддерживает)

**Критическое следствие:** Hiddify и Karing (iOS/Android клиенты, построенные на
sing-box) **не могут подключаться к XHTTP-серверам**. Для XHTTP на клиентах нужны
**Xray-ядра**: FoxRay/v2RayTun (iOS), v2rayNG (Android), v2rayN (Windows).

### 3.7 Важная заметка про версии

«XHTTP под активной разработкой, важно чтобы версии Xray на клиенте и сервере
совпадали — иначе странные глюки или вообще не работает» (Habr 990208).

---

## §4 HTTPUpgrade

**HTTPUpgrade** — транспорт через стандартный HTTP/1.1 `Upgrade`-механизм
(аналог WebSocket-handshake, но без полной WebSocket-обёртки). Добавлен в:
- Xray-core — давно
- **sing-box `v1.7.0`** (06.12.2023) — HIGH: [release notes](https://newreleases.io/project/github/SagerNet/sing-box/release/v1.7.0)

### 4.1 Когда HTTPUpgrade vs WebSocket vs XHTTP

**Официальная рекомендация XTLS:**
> «It is recommended to switch to XHTTP to avoid significant traffic fingerprints
> such as HTTPUpgrade's» (HIGH: [xtls.github.io](https://xtls.github.io/en/config/transports/httpupgrade.html))

Т.е. HTTPUpgrade рассматривается как промежуточный шаг, не финальное решение.

### 4.2 Известный баг

[Issue #3426](https://github.com/XTLS/Xray-core/issues/3426): core меняет
регистр букв в заголовках (`Sec-WebSocket` → `sec-websocket`, `Connection: Upgrade`
→ `connection: upgrade`). Firewall может детектировать эту аномалию.

---

## §5 WebSocket transport

Классика. Работает поверх HTTP-upgrade handshake. Поддерживается Xray, sing-box,
Mihomo, всеми клиентами. Работает через Cloudflare CDN и Cloudflare Workers
(HIGH: discussion #2950).

Минусы:
- Заметный fingerprint (Sec-WebSocket-Key, Sec-WebSocket-Version)
- Для обхода — обязательно за TLS с реальным доменом и валидным сертификатом

В РФ-2026 — работает, но больше DPI-внимания. Под TLS 1.3 к подозрительным ASN
попадает под 16-KB curtain.

---

## §6 gRPC transport

HTTP/2-based RPC. Поддерживается Xray и sing-box. Cloudflare CDN поддерживает с
ограничениями (нужны определённые tier-планы), Workers — не поддерживает.

В РФ-2026 — работает, но активно мониторится. Под TLS 1.3 — попадает под curtain.

---

## §7 mKCP

**KCP-based транспорт поверх UDP** с обфускацией под видеостриминг/utp.
Появился в V2Ray давно, в Xray был унаследован.

### 7.1 Реструктуризация в 2026

HIGH: [xtls.github.io/mkcp](https://xtls.github.io/en/config/transports/mkcp.html) +
[233boy/Xray issue #118](https://github.com/233boy/Xray/issues/118):

> «Additionally, the previously default mKCP obfuscation has also been removed.
> To connect to a legacy server, you need to configure `mkcp-original` in FinalMask.»

То есть в 2026 mKCP-конфиги **сломались для тех, кто обновился до новой версии
Xray** — параметры `header` и `seed` мигрированы в новую секцию `finalmask/udp`.
Для legacy-серверов нужен `mkcp-original` в FinalMask.

### 7.2 mKCP в 2026 — статус

- ✅ В Xray есть, продолжает поддерживаться
- ❌ В sing-box — НЕ поддерживается
- 🟡 В РФ — UDP-блокировки лета 2025 (Banzaev/Amnezia HIGH: «РКН почти полностью
  заблокировал неидентифицированный UDP-трафик») делают mKCP уязвимым

**Discussion [#3638](https://github.com/XTLS/Xray-core/discussions/3638):** есть
запрос на новую обфускацию mKCP под QUIC. Не реализовано.

### 7.3 Когда использовать mKCP

В РФ-2026 — не рекомендуется. В странах без UDP-фильтрации — может быть выбран
для высокой скорости (изначально оптимизирован под latency vs throughput).

---

## §8 Hysteria2 (как отдельный протокол-транспорт)

**Hysteria2** — это **самостоятельный VPN-протокол поверх QUIC**, а не транспорт
для VLESS/VMess. Отдельная архитектура. Поддерживается:
- ✅ **sing-box** — нативный Hysteria2 outbound
- ✅ **Xray-core с `v26.1.23`** (Hysteria2 outbound добавлен)
- ✅ **apernet/hysteria** — оригинальная реализация

### 8.1 Особенности

| Фича | Описание | Источник |
|---|---|---|
| **Salamander obfs** | XOR-обфускация UDP-пакетов случайно выглядящими байтами; общий password на клиенте и сервере | [hysteria.network docs](https://v2.hysteria.network/docs/Changelog/) HIGH |
| **Congestion control** | BBR (3 профиля: standard, conservative, aggressive) и Reno | [hysteria.network full-server-config](https://v2.hysteria.network/docs/advanced/Full-Server-Config/) HIGH |
| **Masquerade modes** | `file` (статический файл-сервер), `proxy` (reverse-proxy на upstream URL), `string` (отдаёт строку) | [hysteria.network full-server-config](https://v2.hysteria.network/docs/advanced/Full-Server-Config/) HIGH |
| **Protocol layer** | QUIC-based, документация на developers/Protocol | [hysteria.network protocol](https://v2.hysteria.network/docs/developers/Protocol/) HIGH |

### 8.2 Известные баги Hysteria2

- **apernet/hysteria #1364:** obfs causes crash в v2.6.1
- **Xray-core #5712:** feature request на поддержку `hysteria2 obfs (Salamander)`
  в Xray-core — означает, что на момент создания issue Xray не поддерживал
  Salamander нативно
- **3X-UI #3901:** feature request на native UI поддержку Hysteria2 — статус
  под обсуждением

### 8.3 Статус в РФ-2026

Banzaev (Amnezia, HIGH): Hysteria2 — в списке протоколов, **работающих в РФ при
правильной конфигурации**, наряду с XRay (VLESS/VMess/Trojan), NaiveProxy.

Но: ЛЕТО 2025 — РКН блокирует «неопознанный UDP». Hysteria2 требует **обязательно
masquerade под легитимный HTTPS** (mode `proxy` с upstream на реальный домен) или
risk быть отброшенным как «неопознанный UDP».

---

## §9 TUIC v5

**TUIC** — UDP-протокол поверх QUIC, конкурент Hysteria2. Документирован только в
sing-box (`udp_relay_mode: native|quic`, `udp_over_stream`, `zero_rtt`).

**В Xray официальной поддержки TUIC НЕ найдено.**

В РФ-2026 — те же проблемы что у Hysteria2: UDP-фильтрация. Меньше production-
опыта чем у Hysteria2 (TUIC более «нишевый»).

---

## §10 ShadowTLS v3

**ShadowTLS** — техника маскировки Shadowsocks под TLS-соединение к легитимному
сайту. v3 — текущая ревизия.

Поддерживается:
- ✅ **sing-box** (нативно)
- ❌ **Xray-core** (нет нативной поддержки на 2026-05-17 в официальных доках)
- ✅ Отдельная реализация **ShadowTLS by ihciah** (на Go и Rust)

Статус в РФ — рабочий вариант, но требует правильно настроенного `dest`-сайта
(аналогично Reality).

---

## §11 Shadowsocks 2022 (SS2022) — современный SS

**SS2022** = SIP022 edition — следующая ревизия Shadowsocks с устранением старых
криптографических слабостей. Спецификация:
[shadowsocks.org/sip022](https://shadowsocks.org/doc/sip022.html) HIGH.

### 11.1 Что изменилось

| Аспект | Classic SS | SS2022 (SIP022) |
|---|---|---|
| KDF | HKDF_SHA1 (obsolete, уязвимости) | **BLAKE3 key derivation** |
| TCP cipher | AEAD AES-GCM/ChaCha20-Poly1305 | `2022-blake3-aes-128-gcm`, `2022-blake3-aes-256-gcm`, `2022-blake3-chacha20-poly1305` (+ chacha12/chacha8 для слабых CPU) |
| UDP | AEAD per-packet (replay уязвимости) | XChaCha20-Poly1305 + random nonce per message |
| Anti-probing | Уязвим (issue Xray #625) | В спеке **обязательно** тайминг-нейтральное закрытие |

### 11.2 Парадокс «SS как outbound DC-to-DC работает, а как direct client→server — нет»

Наблюдение из практики (без HIGH-источника):

- **Client → SS-server (direct):** TSPU видит SS-handshake → active probing → блокировка
- **RU-VPS → SS-server (DC-to-DC, multi-hop outbound):** трансграничный B2B-трафик
  режется мягче; SS как outbound из RU-VPS в загр.SS-сервер работает

Причина: ТСПУ применяет более жёсткие правила к **исходящему пользовательскому
трафику в загр-зону**, чем к DC-to-DC трафику между серверами (это обычная картина
для облачных синхронизаций).

❓ **Прямого подтверждения этого механизма в источниках — нет.** Косвенно
поддерживается:
- Habr (MEDIUM) о различиях DPI на разных типах трафика
- Banzaev (HIGH) подтверждает что SS plain «детектируется», но не уточняет
  тип трафика

Это **расхождение зафиксировано в `_meta/conflicts.md`**.

### 11.3 Поддержка в реализациях

- ✅ **sing-box** — да (с известным историческим багом `2022-blake3-chacha20-poly1305`
  multi-user, sing-box #1652)
- ✅ **Xray** — да (по issue [#1029](https://github.com/XTLS/Xray-core/issues/1029))
- ⚠️ **shadowsocks-libev** — отсутствие `2022-blake3-chacha20-poly1305` (issue #2960)
- ✅ **OutlineVPN** — поддержка SS2022 + устойчивость к active probing
  (HIGH: net4people/bbs #58)

### 11.4 v2ray-plugin и simple-obfs (legacy)

Plugin-chain: SS-server → v2ray-plugin → реальный TCP-сокет.

Эти плагины **исторические**, не обновлялись активно в 2025-2026. Свежих данных
о статусе в РФ — нет. ❓ Уточнить (не подтверждено: 2026-05-17).

---

## §12 sing-box vs Xray feature matrix (May 2026)

| Feature | sing-box | Xray |
|---|---|---|
| **Транспорты** | | |
| TCP (raw) | ✅ | ✅ |
| WebSocket | ✅ (улучшен v1.1) | ✅ |
| HTTP/2 transport | ✅ | ✅ |
| HTTPUpgrade | ✅ (v1.7.0+) | ✅ |
| gRPC | ✅ | ✅ |
| QUIC (как transport) | ✅ (несовместим с Xray-QUIC) | ⚠️ |
| mKCP | ❌ | ✅ (реструктурирован 2026) |
| **XHTTP** | ❌ | ✅ (v24.9.30+) |
| **Протоколы (outbound)** | | |
| VLESS | ✅ | ✅ |
| VMess | ✅ | ✅ |
| Trojan | ✅ | ✅ |
| Shadowsocks (вкл. SS2022) | ✅ | ✅ |
| **TUIC** | ✅ | ❌ |
| **NaiveProxy** | ✅ | ❌ |
| **AnyTLS** | ✅ (v1.12.0+) | ❌ |
| WireGuard | ✅ (deprecated) | ✅ |
| Hysteria2 outbound | ✅ | ✅ (v26.1.23+) |
| **Security/flow** | | |
| REALITY (server) | ⚠️ КОНФЛИКТ доков | ✅ (v1.8.0+) |
| `xtls-rprx-vision` | ⚠️ КОНФЛИКТ доков | ✅ (нативно) |
| XUDP (VMess) | ✅ (v1.1+) | ✅ |
| TUN inbound | ✅ | ✅ (v26.1.23: UDP FullCone NAT) |
| HTTP-client | ✅ (v1.14.0+, HTTP 1/2/3) | n/a |

### 12.1 КОНФЛИКТ в sing-box доках по REALITY/Vision

В sing-box есть противоречие:
- VLESS-страница: `flow: "xtls-rprx-vision"` указан как валидное значение
- TLS shared-страница: `reality` помечен как **unsupported/deprecated**
- [singbox-internals](https://singbox-internals.hidandelion.com/protocols/vless.html)
  утверждает: sing-box НЕ имплементирует Vision/XTLS

❓ Требует подтверждения от maintainer-ов sing-box. Зафиксировано в `_meta/conflicts.md`.

**Практический совет:** для REALITY+Vision-сервера — используйте Xray-клиентов
(FoxRay, v2rayN, v2rayNG). Для REALITY без Vision — sing-box работает (Hiddify,
Karing).

---

## §13 VLESS+Reality 2026 — best practices для donor-сайта

Reality прячется за реальным TLS handshake к другому сайту. Правильный выбор
**donor (поле `dest`/`serverName`)** критичен.

### 13.1 Что НЕ использовать

HIGH: [XTLS/REALITY README](https://github.com/XTLS/REALITY/blob/main/README.en.md)

- ❌ **Cloudflare** как dest — сервер становится port-forward для CF, **traffic-утечка** после сканирования
- ❌ **Крупные сайты с CDN в стране (РФ):** Google, Yandex, многие. Имеют локальные CDN — соединение к локальным IP, не к зарубежным. Из перспективы ТСПУ это «нормальная картина», но **не маскировка**, потому что Reality реально соединяется с зарубежным донором.
- ❌ **Microsoft до 2022:** имел CDN в РФ — был непригоден.

### 13.2 Что использовать

- ✅ **Microsoft с 2022:** отключил CDN в РФ — теперь подходит как dest. Конкретно `www.microsoft.com`, `update.microsoft.com`.
- ✅ **GitHub:** `github.com`, `objects.githubusercontent.com`
- ✅ **Apple:** `www.apple.com`, `swdist.apple.com`
- ✅ **Любой популярный сайт без CDN в стране-наблюдателе**, отдающий TLS 1.3 + HTTP/2 + валидный сертификат

### 13.3 uTLS fingerprint

Параметр `fingerprint`, default = `"chrome"`. Опции: `"chrome"`, `"firefox"`,
`"safari"`, `"random"` / `"randomized"`.

**Известный баг:** `chrome_pq` fingerprint **НЕ работает** с VLESS+XTLS-REALITY
(sing-box #2084, Xray-core #4852). Работают: `chrome`, `firefox`, `edge`.

### 13.4 Reality fallback

Если client-hello не проходит REALITY-проверку (неправильный pubkey/shortId или
вообще не Reality-клиент) — соединение **проксируется на реальный `dest`-сайт**,
который видит легитимный TLS handshake. Это и есть «маскировка».

### 13.5 Версии Xray

- ≥ **`v1.6.3`** — REALITY впервые попал в Xray
- ≥ **`v1.8.0`** — REALITY стабилен
- 🟡 **June 1, 2026 UTC** — scheduled disable `allowInsecure: true`. Конфиги с
  этим полем без миграции перестанут работать в новых релизах. Migration window
  открыт.

### 13.6 Рекомендуемая комбинация для РФ-2026

```
VLESS + TCP + REALITY + xtls-rprx-vision + uTLS(chrome или firefox)
```

С dest = `www.microsoft.com` или `github.com` (без CDN в РФ).

Источник: [Xray-core discussion #3518](https://github.com/XTLS/Xray-core/discussions/3518),
[Xray-examples](https://github.com/XTLS/Xray-examples/blob/main/VLESS-TCP-XTLS-Vision-REALITY/config_server.jsonc).

---

## §14 Decision tree «какой транспорт под задачу»

```
Задача: установить VPN на свой загр.VPS для повседневного использования из РФ
├── Цель — обход блокировок DPI
│   ├── Нужен максимум защиты от 16-KB curtain → XHTTP за реальным Nginx с TLS 1.2
│   │   └── НО: клиенты только Xray (FoxRay, v2rayN, v2rayNG); НЕ Hiddify/Karing
│   ├── Нужна универсальность по клиентам → VLESS+TCP+REALITY+Vision
│   │   └── Работает на Hiddify/Karing (через sing-box REALITY без Vision) и Xray-клиентах
│   └── Нужна мобильная батарея + UDP-устойчивость → Hysteria2 с masquerade
│       └── UDP — риск блокировки в РФ-2026
├── Цель — multi-hop через свой RU-VPS
│   ├── RU-VPS → загр.VPS outbound: VLESS+Reality или SS2022 (DC-to-DC режется мягче)
│   └── Клиент → RU-VPS: внутри РФ, маскировка не нужна — голый VLESS-TCP
└── Цель — CDN-fronting (за Cloudflare Workers)
    └── WebSocket — единственный совместимый транспорт
```

Подробнее по fronting-стратегиям — `_reference/fronting-strategies.md`.

---

## §15 Связи с другими документами

- `_reference/vpn-protocols.md` — сами протоколы (VLESS, VMess, Trojan, SS, WG, …)
- `_reference/fronting-strategies.md` — Cloudflare-fronting, альтернативные CDN
- `_reference/3x-ui-panel.md` — какие транспорты доступны в UI панели 3X-UI
- `_reference/client-apps.md` — какие клиенты какие транспорты поддерживают
- `_live/frontline-ru.md` — какие транспорты сейчас работают в РФ
- `_meta/conflicts.md` — расхождения источников (REALITY в sing-box, SS DC-to-DC)
