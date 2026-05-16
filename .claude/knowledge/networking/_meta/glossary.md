---
knowledge_domain: vpn
layer: meta
last_researched: 2026-05-16
ttl_days: 365
sources_checked: []
---

# Глоссарий VPN/обхода блокировок

Единый словарь терминов, чтобы не разъяснять одно и то же в каждом документе.
Алфавитный порядок. Каждый термин — определение в 1-3 строки + кросс-ссылка на
reference-файл если есть.

---

## A

**Active probing** — техника цензора: после того как заметил подозрительное
соединение, активно подключается к серверу с разными probe-запросами, чтобы
определить, VPN это или нет. Reality защищает от active probing тем, что
показывает реальный сайт. См. `_reference/vpn-protocols.md` §1.7.

**AmneziaWG (AWG)** — форк WireGuard с обфускацией handshake (изменяет
магические байты + добавляет junk-пакеты), чтобы обойти TSPU-сигнатуру
148-байтного WG handshake. См. `_reference/vpn-protocols.md` §1.3.

**ASN (Autonomous System Number)** — номер автономной сети, единица
маршрутизации интернета. Например, Hetzner = AS24940, Cloudflare = AS13335.
ТСПУ может блокировать или throttle'ить целые ASN.

## C

**CDN (Content Delivery Network)** — сеть распределённых серверов для
ускорения доставки контента. Cloudflare, Fastly, Akamai, Bunny. Используется
для fronting — пряча VPN-сервер за инфраструктурой популярного CDN.

**ClientHello** — первое сообщение TLS handshake от клиента к серверу.
Содержит SNI, версии TLS, cipher suites, расширения. Объект анализа DPI.

**Curtain (16-KB curtain)** — конкретный механизм TSPU-throttling с июня 2025:
к подозрительному IP (Hetzner, OVH, DO, CF) после ~15-20 KB полученных данных
TCP-пакеты с сервера прекращаются. Имитация «обрыва соединения».

## D

**Domain fronting** — техника обхода, в которой SNI поля и HTTP Host header
указывают на разные домены. Клиент подключается к легитимному CDN-IP с
SNI=cdn.example.com, а внутри HTTPS просит Host=hidden.actual.target. Сейчас
заблокирован у большинства крупных CDN (CF, AWS, Google запретили).

**DPI (Deep Packet Inspection)** — глубокий анализ содержимого пакетов на
уровне сетевого оборудования. ТСПУ работает через DPI: видит сигнатуры
протоколов, fingerprint TLS, паттерны handshake.

**DoH/DoT (DNS over HTTPS / over TLS)** — шифрование DNS-запросов.
Затрудняет DNS-фильтрацию провайдеров, но не помогает против DPI.

## E

**ECH (Encrypted Client Hello)** — расширение TLS, шифрующее SNI внутри
ClientHello. В РФ блокируется отдельно — TSPU дропает любые TLS-соединения
с ECH. См. `_reference/fronting-strategies.md`.

**ESNI (Encrypted SNI)** — предшественник ECH (deprecated). Аналогичный
статус в РФ — заблокирован.

## F

**Fingerprint (отпечаток)** — уникальные характеристики, по которым можно
распознать клиент. JA3/JA4 — хеши параметров TLS ClientHello (cipher order,
extensions). Reality использует uTLS, чтобы имитировать fingerprint Chrome
или Firefox.

**Fronting** — общий термин для маскировки реального адресата за легитимным.
Виды: domain fronting (разные SNI и Host), host fronting (Reality —
SNI=microsoft.com, но реальный сервер не там), CDN fronting (через
инфраструктуру CDN).

## G

**GFW (Great Firewall)** — система интернет-цензуры КНР. Опережает TSPU
на ~2 года технически. То, что блокируется в GFW сегодня, придёт в РФ
через 6-12 мес.

**gRPC transport** — транспорт Xray/sing-box поверх HTTP/2. В 2024-2025
популярен, в 2026 — статус нужно сверять с `_reference/transports.md` §6.

## H

**Handshake** — рукопожатие, обмен установочными сообщениями двух сторон
протокола перед обменом данными. WG handshake — 148 байт, узнаваем DPI
по сигнатуре. OpenVPN handshake — серия P-ACK пакетов.

**HTTPUpgrade** — транспорт Xray. HTTP/1.1 запрос с заголовком Upgrade,
после ответа 101 — туннель внутри TCP-соединения. Альтернатива
WebSocket — проще, ближе к нативному HTTP. См. `_reference/transports.md` §4.

**Hysteria2** — UDP-протокол поверх QUIC с агрессивным congestion control
(BBR-like). Сильнее справляется с потерями на нестабильных каналах.
Внутри — обфускация Salamander. См. `_reference/transports.md` §8.

## J

**JA3 / JA4** — хеши TLS ClientHello fingerprint. JA3 — md5 от
(version, ciphers, extensions, elliptic_curves, ec_point_formats). JA4 — новее,
с TLS 1.3 поддержкой. По JA3/JA4 видно «это Chrome / это curl / это Xray».

**Junk packets** — фиктивные пакеты, которые AmneziaWG отправляет до
реального handshake, чтобы сбить с толку DPI-сигнатуры.

## M

**mKCP** — транспорт Xray, KCP-протокол поверх UDP с обфускацией под
видеостриминг/utp. Реликвия в 2026, статус — см. `_reference/transports.md` §7.

**Multi-hop (каскад)** — VPN-цепочка из двух+ серверов: клиент → сервер A →
сервер B → интернет. Скрывает реальный destination от сервера A и реальный
source от сервера B. См. `_reference/vpn-protocols.md` §4.

## P

**Padding (паддинг)** — добавление случайных байтов в пакеты, чтобы
скрыть реальные размеры данных. Защита от анализа размеров (length-based
fingerprint).

**Plugin chain** — последовательность плагинов в Shadowsocks: ss-server
→ v2ray-plugin → реальный TCP-сокет. Каждый плагин добавляет уровень
обфускации.

## Q

**QUIC** — транспорт от Google поверх UDP. Используется Hysteria2 и TUIC.
TSPU блокирует «неопознанный UDP» с 2025, но QUIC к легитимным сервисам
(YouTube, Google) проходит — паразитировать сложно.

## R

**Reality** — TLS-replacement протокол от XTLS-команды (см.
`_reference/vpn-protocols.md` §1.7). Использует TLS handshake к реальному
популярному сайту (donor); при правильном клиентском ключе подменяет
сертификат и пробрасывает в Xray. Защищает от active probing «нативно».

**Reality-handshake** — само рукопожатие Reality. С клиента видится как
обычный TLS handshake к donor-сайту, на сервере Reality перехватывает
и переключает на VPN, если клиент авторизован.

## S

**Shadowsocks 2022 (SS2022)** — новая ревизия SS с AEAD-2022 шифрами
(`2022-blake3-chacha20-poly1305`, `2022-blake3-aes-256-gcm`). Защищена от
replay-атак и active probing лучше старой SS. См. `_reference/transports.md` §11.

**ShadowTLS** — техника маскировки SS под TLS-соединение к легитимному сайту.
v3 — текущая ревизия. См. `_reference/transports.md` §10.

**SNI (Server Name Indication)** — расширение TLS, в котором клиент сообщает
серверу имя хоста, к которому подключается (нужно для виртуального хостинга).
Передаётся открытым текстом в ClientHello — главный объект DPI-фильтрации.

## T

**Throttling (троттлинг)** — преднамеренное замедление трафика без полной
блокировки. ТСПУ throttle'ит TLS 1.3 к ряду ASN с июня 2025 (см. Curtain).

**Trojan** — протокол маскировки под HTTPS: клиент подключается к серверу
по TLS, в начале передаёт hash от пароля; если совпало — туннель, если
нет — отдаётся реальный сайт по fallback. Уязвим к active probing если
fallback не настроен или поддельный. См. `_reference/vpn-protocols.md` §1.6.

**TSPU (ТСПУ, Технические Средства Противодействия Угрозам)** — российская
система DPI-фильтрации, аналог GFW. Установлена в инфраструктуре провайдеров
с 2019, активна с 2022, активна с серьёзными возможностями с 2024.

**TUIC v5** — UDP-протокол поверх QUIC, конкурент Hysteria2. См.
`_reference/transports.md` §9.

## U

**uTLS** — Go-библиотека, имитирующая fingerprint реального браузера.
Используется в Reality и других VPN-клиентах, чтобы JA3/JA4 не отличался
от настоящего Chrome/Firefox/Safari.

## V

**VLESS** — лёгкий протокол передачи данных без шифрования (шифрует обёртка
типа TLS или Reality). Эволюция VMess — без VMess-специфичных слабостей.
См. `_reference/vpn-protocols.md` §1.7.

**vless://** — URI-формат для импорта VLESS-конфига в клиента.
`vless://uuid@host:port?security=reality&sni=...&pbk=...&type=...#name`

**VMess** — классический протокол V2Ray с встроенным шифрованием и
аутентификацией. Имеет известные слабости fingerprinting, в 2026
вытеснен VLESS.

## W

**WARP** — VPN-сервис от Cloudflare поверх WireGuard, бесплатный для
персонального использования. Может использоваться как outbound для своего
Xray. См. `_reference/fronting-strategies.md` §4.

**WebSocket transport** — транспорт Xray/sing-box поверх ws://. Часто
используется как фронт за Nginx с другим сертификатом и доменом.

**WireGuard (WG)** — современный VPN-протокол с минимальным handshake (148 байт).
В РФ-2026 заблокирован TSPU полностью — handshake-fingerprint виден.
Решение — AmneziaWG.

## X

**XHTTP** — транспорт Xray (с 2024-2025). Stream-вверх + chunked-вниз поверх
HTTP/1.1 или /2. Может работать через TLS 1.2 — обход блокировки TLS 1.3
к подозрительным ASN. См. `_reference/transports.md` §3.

**XTLS** — расширение TLS от Xray-команды. Включает Reality и xtls-rprx-vision
(flow для оптимизации throughput).

**xtls-rprx-vision** — flow для VLESS+TLS/Reality. Снижает overhead TLS
для длинных стримов (видео, большие загрузки). Обозначается в URI как
`flow=xtls-rprx-vision`.
