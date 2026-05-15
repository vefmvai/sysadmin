# Sing-box vs Xray: сравнение + boilerplate-конфиги

**Дата:** 2026-05-15
**Назначение:** материал для агента-сисадмина (когда выбирать какое ядро,
готовые шаблоны клиентских конфигов sing-box).
**Уровень доверия:**
- **Высокий** — для фактов из официальной документации (`sing-box.sagernet.org`,
  `xtls.github.io`), README обоих репо на GitHub, страниц миграции sing-box.
- **Средний** — для оценок «де-факто стандарта» и сценариев из issue-трекеров
  и сторонних обзоров (NTC, Medium, Cure VPN).
- **Низкий / непроверено** — там, где есть только один сторонний источник
  (явно помечено `[непроверено]`).

> Этот файл — справочник для принятия решений и стартовая точка для генерации
> клиентских конфигов. **Конфиги, попадающие в скиллы/боевую инфру, должны
> сверяться с актуальной версией документации sing-box того релиза, что стоит
> у пользователя** — формат меняется почти в каждой минорной версии
> (см. Блок C, «Подводные камни»).

---

## Блок A. Сравнительная карта sing-box vs Xray

### A.1 Происхождение и поддержка

| Параметр | sing-box | Xray-core |
|---|---|---|
| Год появления | 2022 [1] | 2020 (форк v1.0.0 от v2fly-core) [2] |
| Автор / организация | nekohasekai / SagerNet [1] | XTLS organization (Project X) [2] |
| Лицензия | GPL v3.0 [1] | Mozilla Public License 2.0 [2] |
| Текущая версия (на 2026-05-15) | 1.13.12 (релиз 2026-05-15) [1] | v26.3.27 (релиз 2026-03-27) [2] |
| GitHub stars | 33.8k [1] | 38.6k [2] |
| Forks | 4k [1] | 5.4k [2] |
| Релизов всего | — | 114 [2] |
| Язык реализации | Go 96.7%, Shell 1.8%, Obj-C 1.1% [1] | Go 99.7% [2] |
| Self-описание | «The universal proxy platform» [3] | «Xray, Penetrates Everything. Also the best v2ray-core» [2] |

**Заметки:**
- Xray старше sing-box примерно на два года и развивался как форк v2ray
  с фокусом на новые «свои» протоколы (VLESS, XTLS, Reality, XHTTP).
- sing-box сделан «с нуля» в 2022 как универсальная платформа, поглотившая
  идеи v2ray/clash/leaf. Цель — единый бинарь для всех платформ
  (Android/iOS/macOS/Linux/Windows/router) [3] [4].
- Обе кодовые базы — почти полностью Go. Это означает похожий профиль
  производительности и зависимостей.

### A.2 Поддержка протоколов

Источники для таблицы — официальные списки протоколов в документации [3] [5] [6].

| Протокол | sing-box inbound | sing-box outbound | Xray inbound | Xray outbound |
|---|---|---|---|---|
| VLESS | ✅ | ✅ | ✅ | ✅ |
| VMess | ✅ | ✅ | ✅ | ✅ |
| Trojan | ✅ | ✅ | ✅ | ✅ |
| Shadowsocks | ✅ | ✅ | ✅ | ✅ |
| Hysteria (v1) | ✅ | ✅ | ✅ (с issues) | ✅ |
| Hysteria 2 | ✅ | ✅ | ⚠️ заявлен, но сломан | ⚠️ outbound ок, inbound с багами |
| TUIC | ✅ | ✅ | ❌ | ❌ |
| ShadowTLS | ✅ | ✅ | ❌ | ❌ |
| AnyTLS | ✅ | ✅ | ❌ | ❌ |
| Naive | ✅ | ✅ | ❌ | ❌ |
| WireGuard | ⚠️ через endpoints (1.11+) | ✅ (legacy deprecated, заменён endpoints) | ✅ (с известными issues, см. ниже) | ✅ |
| SOCKS | ✅ | ✅ | ✅ | ✅ |
| HTTP | ✅ | ✅ | ✅ | ✅ |
| Mixed (SOCKS+HTTP на одном порту) | ✅ | — | ❌ (требует двух inbound) | — |
| Direct (inbound) | ✅ | — | ⚠️ dokodemo-door [7] | — |
| Tor | ❌ | ✅ | ❌ | ❌ |
| SSH (как proxy) | ❌ | ✅ | ❌ | ❌ |
| DNS (как outbound) | ❌ | ✅ | ❌ | ✅ |
| TUN | ✅ | — | ✅ (заявлен) [8] | — |
| Redirect (Linux netfilter) | ✅ | — | ❌ | — |
| TProxy (Linux) | ✅ | — | ❌ | — |
| Cloudflared | ✅ | — | ❌ | — |
| Selector (manual выбор) | — | ✅ | ❌ (есть balancers, синтаксис другой) | ❌ |
| URLTest (auto best) | — | ✅ | ❌ (есть balancers через observatory) | ❌ |
| Reality (TLS обфускация) | ✅ как TLS-слой | ✅ как TLS-слой | ✅ (родина протокола) | ✅ |
| XTLS Vision (xtls-rprx-vision) | ✅ через flow= в VLESS [9] | ✅ через flow= [9] | ✅ | ✅ |
| XHTTP transport | ⚠️ как «http» транспорт | ⚠️ | ✅ (родина) | ✅ |
| Blackhole (DROP outbound) | — | ✅ (тип `block`, в 1.11 заменён route action `reject`) | — | ✅ |

**Ключевые наблюдения:**

1. **TUIC, ShadowTLS, AnyTLS, Naive** — только sing-box. Xray этих
   протоколов не поддерживает (ни как inbound, ни как outbound) [5] [6].
2. **Hysteria 2 inbound** — теоретически есть в Xray, но по issue tracker'у
   на 2026 год сломан: «Hysteria2 inbound starts successfully, receives UDP
   packets, but sends no response packets and client always times out»
   (issue #5921) и «Discord WebRTC lag in TUN mode, while sing-box Hysteria2
   works normally» (issue #6039) [8]. На практике для Hysteria 2 inbound
   де-факто используется sing-box или нативный Hysteria-server.
3. **Reality** — изобретён в Xray (это была основная фича XTLS-команды),
   но sing-box получил полноценную поддержку как клиента и сервера [9].
4. **TUN** — у Xray есть как inbound тип, но в issue trackers видна
   деградация производительности по сравнению с sing-box (та же issue #6039) [8].
5. **WireGuard inbound в Xray** — issue #4760 «Bad wireguard inbound design» [10]
   указывает на нестабильность; на практике WireGuard выносят в отдельный демон
   (boringtun/wireguard-go), а Xray использует как outbound.
6. **VLESS+Reality + Vision flow** — поддерживают оба, но Xray
   считается «домом» этой комбинации (быстрее получает фиксы и оптимизации).

### A.3 Формат конфига

| Аспект | sing-box | Xray |
|---|---|---|
| Базовый формат | JSON [3] | JSON (исторически от v2ray) [2] |
| Альтернативные форматы | YAML, TOML (через CLI флаги при компиляции, экспериментально) | Нет; через сторонние конвертеры |
| Top-level секции | `log`, `dns`, `ntp`, `certificate`, `certificate_providers`, `http_clients`, `endpoints`, `inbounds`, `outbounds`, `route`, `services`, `experimental` [3] | `log`, `api`, `dns`, `routing`, `policy`, `inbounds`, `outbounds`, `transport`, `stats`, `reverse`, `fakedns` |
| Валидатор / dry-run | `sing-box check -c config.json` (встроенный) | `xray test -c config.json` (встроенный) |
| Multi-hop через chain | ✅ через поле `detour` на outbound [11] | ✅ через `proxySettings.tag` в outbound (StreamSettings sockopt + chain) |
| Балансировщик | ✅ типы outbound `selector` и `urltest` [12] [13] | ✅ через `routing.balancers` + `observatory` (более сложный синтаксис) |
| Импорт конфига друг друга | ❌ полный конфиг несовместим | ❌ полный конфиг несовместим |
| Импорт share-link | ✅ `vless://`, `vmess://`, `trojan://`, `tuic://`, `hysteria2://`, `ss://` через клиентские UI (Hiddify, NekoBox) [14] | ✅ через 3X-UI/Marzban и клиентов |

**Важное:** конфиги конвертируемы только на уровне отдельных серверов
(через share-link), а не на уровне полного workflow (с маршрутизацией, DNS,
правилами). Если оператор переезжает с Xray на sing-box или наоборот —
маршрутизация и DNS-блок переписываются вручную.

### A.4 Маршрутизация

#### sing-box: rule_set + route.rules

В sing-box 1.8+ маршрутизация построена на двух уровнях [15]:

- **`route.rules[]`** — список правил с условиями (см. полный список ниже).
- **`route.rule_sets[]`** — именованные наборы условий, которые подгружаются
  локально или удалённо (`type: "remote"`, `type: "local"`, `type: "inline"`),
  обновляются с интервалом, могут использоваться в `rule_set` поле правил.

**Условия rule в sing-box (часть, актуально на 1.14)** [16]:

| Поле | Назначение | Версия |
|---|---|---|
| `domain` | точное совпадение домена | — |
| `domain_suffix` | суффикс домена | — |
| `domain_keyword` | keyword | — |
| `domain_regex` | regex | — |
| `geosite` | категория geosite (DEPRECATED 1.8, REMOVED 1.12) | до 1.12 |
| `geoip` | гео-база IP (DEPRECATED 1.8) | до 1.12 |
| `ip_cidr` | CIDR назначения | — |
| `ip_is_private` | непубличный IP | 1.8+ |
| `port` / `port_range` | порт назначения | — |
| `source_ip_cidr` | CIDR источника | — |
| `process_name` | имя процесса (Linux/Win/macOS) | — |
| `process_path` / `process_path_regex` | путь к бинарю | 1.10+ |
| `package_name` / `package_name_regex` | Android-пакет | 1.14+ |
| `rule_set` | ссылка на именованный rule-set | 1.8+ |
| `network` | tcp/udp | — |
| `network_type` / `network_is_expensive` / `network_is_constrained` | тип сети (Wi-Fi/cellular) | 1.11+ |
| `wifi_ssid` / `wifi_bssid` | конкретная Wi-Fi | — |
| `interface_address` | адрес интерфейса | 1.13+ |
| `source_mac_address` / `source_hostname` | MAC/hostname клиента | 1.14+ |
| `clash_mode` | global/rule/direct | — |
| `protocol` | http/tls/dns/quic | — |
| `client` | определённый клиент (по UA) | 1.10+ |
| `action` | accept/reject/hijack-dns/resolve | — |
| `invert` | инверсия условия | — |

#### Xray: routing.rules

В Xray маршрутизация — это `routing.rules[]` с условиями (`domain`, `ip`,
`port`, `network`, `source`, `user`, `inboundTag`, `protocol`, `attrs`)
и встроенные `geosite:CN`, `geoip:RU` (загружаются из бинарных файлов
`geosite.dat`/`geoip.dat` в рабочей директории). Xray использует
**v2fly-rules-dat** (geoip и geosite.dat в текстовом формате, потом
компилируются) или **Loyalsoldier/v2ray-rules-dat** как сторонний поставщик.

**Ключевая разница:** sing-box ушёл от формата `.dat` (geoip/geosite) в сторону
бинарных rule-set'ов в собственном формате (.srs), которые сам же sing-box
скачивает и обновляет по интервалу. Xray остался на старом формате `.dat`.

#### DNS

- В **sing-box** DNS — самостоятельная top-level секция (`dns.servers`,
  `dns.rules`, `dns.final`) со своим набором правил, отдельным от `route.rules`.
  С версии 1.12.0 формат DNS-сервера переехал с string-адреса на explicit
  type-based: `{"type": "udp", "server": "1.1.1.1"}` вместо `{"address": "1.1.1.1"}` [17].
  Fakeip — отдельный тип DNS-сервера (см. B.7).
- В **Xray** DNS — секция `dns` со встроенными правилами (`servers[]` со
  специфичными `domains` и `expectIPs`); сниффинг через `inbounds[].sniffing`.

### A.5 Платформы

| Платформа | sing-box | Xray |
|---|---|---|
| Linux (amd64/arm64) | ✅ | ✅ |
| Windows | ✅ | ✅ |
| macOS | ✅ + Apple-нативный клиент | ✅ |
| iOS | ✅ + App Store клиент (SagerNet/sing-box-for-apple) | ❌ (Xray-core не имеет нативного iOS-клиента; используется только через сторонние клиенты, чаще обёрнутые в sing-box или own стек) |
| Android | ✅ + SagerNet client / Hiddify / NekoBox | ✅ через сторонние клиенты (v2rayNG, X-flutter) |
| Docker | ✅ | ✅ |
| OpenWrt / роутеры | ✅ (пакет в OpenWrt) | ✅ (xray-fw4, passwall) |

**Ключевая разница:** sing-box официально поддерживает iOS из коробки
(App Store + tunnel provider), это сделало его де-факто стандартом для
мобильных клиентов через Hiddify/SFI. У Xray-core нативного iOS-приложения
нет.

### A.6 Производительность

Прямых публично-цитируемых бенчмарков «sing-box vs Xray» на 2026 год немного.
Найденное:

- **DarkCat09/sb-vs-xray** (Forgejo, git.dc09.ru) — сравнение на синтетических
  iperf3-тестах. Результаты: «Both proxies are almost the same speed. Xray was
  sometimes a bit faster» [18]. URL источника:
  https://git.dc09.ru/DarkCat09/sb-vs-xray (требует ручной проверки актуальной
  методологии).
- Сторонние обзоры [4] [19] описывают паттерн: «sing-box лучше масштабируется
  на enterprise high-concurrency сценариях за счёт Go concurrency model;
  Xray иногда быстрее на single-stream throughput». Это `[непроверено]`
  как абсолютные числа — конкретных цифр (Mbps на ядро, RAM/connection)
  в открытом доступе на 2026 нет.

**Практический вывод:** для домашнего использования (1-10 одновременных
коннектов на семью) разница в производительности нерелевантна — выбор
делается по фичам, а не по скорости.

### A.7 Зрелость и use cases

**Продукты на sing-box:**
- **Hiddify** (Hiddify-Manager, Hiddify-app, Hiddify-Next) — основной
  серверный продукт + кроссплатформенный клиент. Использует и sing-box, и
  Xray параллельно как два движка протоколов [20].
- **SagerNet/sing-box-for-android** и **SagerNet/sing-box-for-apple** —
  нативные клиенты от автора ядра.
- **NekoBox** (Android) — клиент на базе sing-box.
- **Karing**, **GUI.for.SingBox** — десктопные клиенты.

**Продукты на Xray:**
- **3X-UI** (MHSanaei/3x-ui) — самая популярная панель для Xray-серверов.
- **Marzban** (Gozargah/Marzban) — альтернативная панель с user management.
- **X-UI** (vaxilu/x-ui) — оригинальная панель (legacy, заменена 3X-UI).
- **v2rayNG** (Android), **v2rayN** (Windows) — клиенты, под капотом Xray.
- **Streisand** (iOS) — клиент с собственным движком, но конфиги Xray-совместимые.

**Де-факто стандарт по ролям:**
- **Сервер** — Xray через 3X-UI или Marzban. Причины: зрелые панели с
  user management, статистикой, multi-user, готовые скрипты установки,
  большая аудитория туториалов на русском [см. .planning/vpn-research.md
  Блок 2 — детали 3X-UI].
- **Клиент** — sing-box через Hiddify-app или SFI/SFA (нативные).
  Причины: единый бинарь под все ОС, поддержка iOS, гибкая маршрутизация
  через `rule_set`, fakeip DNS.

### A.8 Decision tree: когда какое ядро

**Используй Xray (серверная сторона):**
- Нужна панель с user management, статистикой, лимитами трафика —
  3X-UI / Marzban на Xray.
- Только VLESS+Reality / VMess / Trojan / Shadowsocks как протоколы.
- Уже есть инфраструктура на Xray, переезд не оправдан.

**Используй sing-box (серверная сторона):**
- Нужен **Hysteria 2 inbound** (Xray сломан, см. A.2).
- Нужен **TUIC inbound** (Xray не поддерживает вообще).
- Нужен **ShadowTLS / AnyTLS / Naive** (Xray не поддерживает).
- Нужна **мульти-протокольная точка**: VLESS+Reality на 443/TCP +
  Hysteria 2 на 443/UDP + TUIC на 8443/UDP — sing-box один инстанс,
  Xray потребовал бы либо запуск Hysteria-server отдельно, либо отказ
  от Hysteria.

**Используй sing-box (клиентская сторона) — почти всегда:**
- iOS — других вариантов фактически нет.
- Android / macOS / Linux / Windows desktop — sing-box через Hiddify-app
  даёт самый богатый UI и поддержку всех протоколов.
- Нужны fakeip DNS, rule-set с авто-обновлением, process-based маршрутизация.

**Используй Xray (клиентская сторона) — узкие случаи:**
- Уже привык к v2rayNG / v2rayN, не хочешь переучиваться.
- Нужна старая обвязка (старые share-link форматы, специфичный workflow).

**Гибридная архитектура (на практике у большинства):**

```
[Сервер: Ubuntu VPS]                    [Клиент: macOS / iOS / Android]
  └─ Xray-core (через 3X-UI)             └─ sing-box (через Hiddify-app)
     ├─ VLESS+Reality :443/TCP                ├─ tun inbound (system VPN)
     └─ Shadowsocks-2022 :8388                ├─ vless outbound → server
                                              ├─ rule_set: geoip-ru → direct
                                              └─ default → vless outbound
```

---

## Блок B. Boilerplate-конфиги sing-box

**Важное:** все JSON ниже — для sing-box 1.13.x. Если у пользователя
старее (1.10 и ниже) — смотрите Блок C по migration notes.

### B.1 Минимальный клиент с одним VLESS+Reality outbound

**Источник:** sing-box docs `/configuration/outbound/vless/` [21]
+ `/configuration/shared/tls/` [22] + полная схема outbound в исходниках.

```json
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": 2080
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "vless-out",
      "server": "your.server.example.com",
      "server_port": 443,
      "uuid": "00000000-0000-0000-0000-000000000000",
      "flow": "xtls-rprx-vision",
      "network": "tcp",
      "tls": {
        "enabled": true,
        "server_name": "www.cloudflare.com",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": "REALITY_PUBLIC_KEY_FROM_SERVER",
          "short_id": "SHORT_ID_FROM_SERVER"
        }
      }
    },
    {
      "type": "direct",
      "tag": "direct-out"
    }
  ],
  "route": {
    "final": "vless-out",
    "auto_detect_interface": true
  }
}
```

**Что делает:**
- Поднимает локальный mixed-прокси на `127.0.0.1:2080` (SOCKS5 + HTTP на одном порту).
- Весь трафик уходит в VLESS+Reality outbound.
- `flow: "xtls-rprx-vision"` — XTLS Vision (требует совместимости сервера).
- `utls.fingerprint: "chrome"` — маскирует TLS handshake под Chrome.
- `reality.public_key` и `short_id` — берутся с сервера (где `private_key`
  у Xray; сервер по `private_key` генерирует `public_key`).

### B.2 Клиент с маршрутизацией «РФ напрямую, остальное через VPN»

**Источник:** sing-box docs `/configuration/rule-set/` [15] + репозиторий
`SagerNet/sing-geoip` [23].

```json
{
  "log": { "level": "info" },
  "dns": {
    "servers": [
      { "type": "udp", "tag": "dns-local", "server": "1.1.1.1" }
    ]
  },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": 2080
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "vless-out",
      "server": "your.server.example.com",
      "server_port": 443,
      "uuid": "00000000-0000-0000-0000-000000000000",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "www.cloudflare.com",
        "utls": { "enabled": true, "fingerprint": "chrome" },
        "reality": {
          "enabled": true,
          "public_key": "REALITY_PUBLIC_KEY",
          "short_id": "SHORT_ID"
        }
      }
    },
    { "type": "direct", "tag": "direct-out" }
  ],
  "route": {
    "rule_sets": [
      {
        "type": "remote",
        "tag": "geoip-ru",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs",
        "update_interval": "1d"
      },
      {
        "type": "remote",
        "tag": "geosite-category-ru",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ru.srs",
        "update_interval": "1d"
      }
    ],
    "rules": [
      {
        "rule_set": ["geoip-ru", "geosite-category-ru"],
        "outbound": "direct-out"
      },
      {
        "ip_is_private": true,
        "outbound": "direct-out"
      }
    ],
    "final": "vless-out",
    "auto_detect_interface": true
  }
}
```

**Что делает:**
- Скачивает с `SagerNet/sing-geoip` и `SagerNet/sing-geosite` (ветка
  `rule-set/`, файлы `.srs` — бинарный формат, который понимает sing-box) [23] [24].
- Обновляет раз в сутки (`update_interval: "1d"`).
- Правила: если домен попадает в `geosite-category-ru` (российские домены)
  или IP — в `geoip-ru` — идём напрямую. Приватные сети (`192.168.x.x`,
  `10.x.x.x`) — тоже напрямую. Всё остальное — через VLESS.

**Заметка по URL:** sing-box официальная документация **не публикует
прямые URL** rule-set'ов. URL выше — паттерн из репозитория `SagerNet/sing-geoip`
(ветка `rule-set/`). Перед использованием в скилле — проверить, что ветка
`rule-set/` существует на момент использования. Альтернатива — собирать
.srs локально через `sing-box rule-set compile`.

### B.3 Клиент с selector (несколько серверов с переключением вручную)

**Источник:** `/configuration/outbound/selector/` [12].

```json
{
  "outbounds": [
    {
      "type": "vless",
      "tag": "server-de",
      "server": "de.example.com",
      "server_port": 443,
      "uuid": "...",
      "flow": "xtls-rprx-vision",
      "tls": { "enabled": true, "server_name": "...", "reality": { "enabled": true, "public_key": "...", "short_id": "..." } }
    },
    {
      "type": "vless",
      "tag": "server-nl",
      "server": "nl.example.com",
      "server_port": 443,
      "uuid": "...",
      "flow": "xtls-rprx-vision",
      "tls": { "enabled": true, "server_name": "...", "reality": { "enabled": true, "public_key": "...", "short_id": "..." } }
    },
    {
      "type": "vless",
      "tag": "server-jp",
      "server": "jp.example.com",
      "server_port": 443,
      "uuid": "...",
      "flow": "xtls-rprx-vision",
      "tls": { "enabled": true, "server_name": "...", "reality": { "enabled": true, "public_key": "...", "short_id": "..." } }
    },
    {
      "type": "selector",
      "tag": "select",
      "outbounds": ["server-de", "server-nl", "server-jp"],
      "default": "server-de",
      "interrupt_exist_connections": false
    },
    { "type": "direct", "tag": "direct-out" }
  ],
  "route": {
    "final": "select"
  },
  "experimental": {
    "clash_api": {
      "external_controller": "127.0.0.1:9090"
    }
  }
}
```

**Что делает:**
- Три сервера + outbound типа `selector`. Маршрут указывает на `select`.
- Переключение между серверами — через Clash API (`external_controller`)
  или GUI клиента (Hiddify-app, NekoBox умеют переключать selector через UI).
- `interrupt_exist_connections: false` — открытые соединения не рвутся при
  переключении [12].

**Важное:** документация подчёркивает «The selector can currently only be
managed through the Clash API integration feature» [12] — переключение
программное, через API; без UI нужен `clash_api` блок в `experimental`.

### B.4 Клиент с urltest (автоматический выбор лучшего по latency)

**Источник:** `/configuration/outbound/urltest/` [13].

```json
{
  "outbounds": [
    { "type": "vless", "tag": "server-de", "...": "..." },
    { "type": "vless", "tag": "server-nl", "...": "..." },
    { "type": "vless", "tag": "server-jp", "...": "..." },
    {
      "type": "urltest",
      "tag": "auto",
      "outbounds": ["server-de", "server-nl", "server-jp"],
      "url": "https://www.gstatic.com/generate_204",
      "interval": "3m",
      "tolerance": 50,
      "idle_timeout": "30m",
      "interrupt_exist_connections": false
    }
  ],
  "route": {
    "final": "auto"
  }
}
```

**Параметры (из официальной документации):**
- `url` — endpoint для проверки. Дефолт: `https://www.gstatic.com/generate_204`.
- `interval` — частота проверки. Дефолт: `3m`.
- `tolerance` — порог в миллисекундах: если новый лучший лучше текущего
  меньше чем на `tolerance` мс, переключения не будет. Дефолт: 50.
- `idle_timeout` — после какого простоя cleanup. Дефолт: `30m`.

### B.5 Multi-hop через два VLESS outbound

**Источник:** sing-box docs `/configuration/shared/dial/` (поле `detour`) [11].

```json
{
  "outbounds": [
    {
      "type": "vless",
      "tag": "hop1-vless",
      "server": "first.hop.example.com",
      "server_port": 443,
      "uuid": "...",
      "flow": "xtls-rprx-vision",
      "tls": { "enabled": true, "server_name": "...", "reality": { "enabled": true, "public_key": "...", "short_id": "..." } }
    },
    {
      "type": "vless",
      "tag": "hop2-vless",
      "server": "second.hop.example.com",
      "server_port": 443,
      "uuid": "...",
      "flow": "xtls-rprx-vision",
      "detour": "hop1-vless",
      "tls": { "enabled": true, "server_name": "...", "reality": { "enabled": true, "public_key": "...", "short_id": "..." } }
    }
  ],
  "route": {
    "final": "hop2-vless"
  }
}
```

**Что делает:**
- `hop2-vless` имеет поле `detour: "hop1-vless"`. Это значит, что
  все исходящие соединения от `hop2` ходят не напрямую в интернет, а
  через `hop1` [11].
- Трафик: клиент → hop1 → hop2 → интернет.

**Подводный камень:** документация sing-box указывает «If enabled, all
other fields will be ignored» — речь идёт о dial-полях (`bind_interface`,
`routing_mark` и т.п.), а не о `server`/`server_port`/`tls`/`uuid`.
**Требует ручной проверки** на реальном инстансе, что multi-hop через
два VLESS+Reality действительно работает: Reality чувствителен к
fingerprint'ам, и проксированный handshake может ломаться.
Для проверенного multi-hop часто используют Shadowsocks → VLESS+Reality
вместо VLESS → VLESS (см. соседний документ `.planning/vpn-research.md`
блок 4 — там детали из контекста Xray).

### B.6 TUN-mode для desktop (Linux/macOS/Windows)

**Источник:** `/configuration/inbound/tun/` [25].

```json
{
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "tun0",
      "address": ["172.18.0.1/30", "fdfe:dcba:9876::1/126"],
      "mtu": 9000,
      "auto_route": true,
      "auto_redirect": true,
      "strict_route": true,
      "stack": "mixed"
    }
  ],
  "outbounds": [
    { "type": "vless", "tag": "vless-out", "...": "..." },
    { "type": "direct", "tag": "direct-out" }
  ],
  "route": {
    "auto_detect_interface": true,
    "final": "vless-out"
  }
}
```

**Особенности по платформам (из документации):**
- **Linux:** `auto_redirect: true` обязателен — даёт лучшую производительность
  чем tproxy и автоматическую интеграцию с nftables. «Always recommended on Linux».
- **Windows:** `strict_route: true` — предотвращает DNS-утечки.
- **macOS / iOS:** native per-interface DNS configuration используется
  автоматически.
- **Android:** при использовании как VPN — `route.override_android_vpn`
  обязателен для приоритета TUN-маршрутизации.

**Важное:** поля `address` (с 1.10+) заменили устаревшие `inet4_address`
и `inet6_address`. Если у пользователя 1.9 и ниже — нужен старый формат
с раздельными полями [17].

**Запуск (Linux):** требует root или CAP_NET_ADMIN. На macOS — system
VPN extension. На iOS — only через нативный SFI/Hiddify-app (нельзя
запустить sing-box CLI с TUN).

### B.7 Конфиг с fakeip DNS

**Источник:** `/configuration/dns/server/fakeip/` [26]. Доступен с
sing-box 1.12.0.

```json
{
  "dns": {
    "servers": [
      {
        "type": "fakeip",
        "tag": "fakeip-server",
        "inet4_range": "198.18.0.0/15",
        "inet6_range": "fc00::/18"
      },
      {
        "type": "udp",
        "tag": "dns-direct",
        "server": "1.1.1.1"
      }
    ],
    "rules": [
      {
        "outbound": "any",
        "server": "dns-direct"
      },
      {
        "query_type": ["A", "AAAA"],
        "server": "fakeip-server"
      }
    ],
    "strategy": "ipv4_only",
    "independent_cache": true
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "address": ["172.18.0.1/30"],
      "auto_route": true,
      "stack": "mixed"
    }
  ],
  "outbounds": [
    { "type": "vless", "tag": "vless-out", "...": "..." },
    { "type": "direct", "tag": "direct-out" }
  ],
  "route": {
    "rules": [
      { "rule_set": ["geosite-category-ru"], "outbound": "direct-out" }
    ],
    "final": "vless-out",
    "auto_detect_interface": true
  }
}
```

**Зачем fakeip:**
- При TUN-mode каждое соединение требует реального IP назначения.
  Без fakeip пришлось бы делать настоящий DNS-lookup до маршрутизации,
  что (а) замедляет, (б) утекает DNS на провайдера.
- С fakeip — клиенту возвращается «фейковый» IP из диапазона
  `198.18.0.0/15`, sing-box хранит маппинг fakeIP → domain, при
  установке соединения берёт оригинальный domain и применяет правила
  по нему. Реальный DNS-резолв делается уже на стороне выбранного
  outbound (т.е. на VPN-сервере, что и нужно).

**Важное по миграциям:**
- В 1.14 `independent_cache` стал **не нужен** — DNS-кэш автоматически
  разделяется по транспорту [17]. Удалите это поле, если ставите 1.14+.

### B.8 Subscription/profile для импорта в Hiddify

**Источник:** `https://hiddify.com/app/URL-Scheme/` [14].

Hiddify-app принимает следующие форматы:

| Формат | Принимается |
|---|---|
| `vless://` / `vmess://` / `trojan://` / `ss://` / `tuic://` / `hysteria2://` | ✅ напрямую |
| Clash YAML | ✅ |
| **sing-box JSON** | ✅ **напрямую — то, что нужно агенту** |
| V2Ray (plain text или base64) | ✅ |

**Импорт через URL:** `hiddify://import/<sublink>#name` — где `<sublink>`
любой из форматов выше [14].

**HTTP-заголовки для subscription endpoint:**
- `Profile-Title: My VPN` — название профиля, отображается в UI Hiddify.
  Поддерживается base64-кодирование: `Profile-Title: base64:SSDinaTvuI8gSGlkZGlmeQ==`
  → отображается как «I ❤️ Hiddify».
- Если заголовок не задан — Hiddify пробует `Content-Disposition` filename,
  URL fragment (`#name`), последний компонент пути.
- `Subscription-Userinfo: upload=...; download=...; total=...; expire=...` —
  опционально, для отображения квоты и срока [`[непроверено]` — не нашёл
  в основной странице URL-Scheme, но это стандарт clash subscribers].

**Generation на сервере (паттерн):**

```bash
# Простейший nginx vhost, отдающий sing-box JSON как subscription:
# /etc/nginx/sites-available/subs.example.com
server {
    listen 443 ssl http2;
    server_name subs.example.com;
    # ... TLS ...

    location ~ ^/u/([a-z0-9-]+)\.json$ {
        # путь: subs.example.com/u/<user-uuid>.json
        # Profile-Title опционально:
        add_header Profile-Title "Family VPN";
        add_header Cache-Control "no-cache";
        alias /opt/subs/$1.json;
    }
}
```

Файлы `/opt/subs/<uuid>.json` — это полные sing-box-конфиги, сгенерированные
для каждого пользователя (с уникальным UUID в VLESS outbound).

### B.9 Конфиг с разделением трафика по приложениям (process-based)

**Источник:** `/configuration/route/rule/` [16]. Поле `process_name`
работает на **Linux, Windows, macOS** (НЕ на Android — там
`package_name`).

```json
{
  "outbounds": [
    { "type": "vless", "tag": "vless-out", "...": "..." },
    { "type": "direct", "tag": "direct-out" }
  ],
  "route": {
    "rules": [
      {
        "process_name": ["telegram-desktop", "telegram", "Telegram"],
        "outbound": "vless-out"
      },
      {
        "process_name": ["firefox", "chrome", "Google Chrome"],
        "outbound": "vless-out"
      },
      {
        "package_name": ["org.thunderbird.android", "com.fsck.k9"],
        "outbound": "direct-out"
      }
    ],
    "final": "direct-out",
    "auto_detect_interface": true
  }
}
```

**Что делает:**
- На Linux/Windows/macOS — Telegram и браузеры идут через VPN,
  остальное (системные процессы, обновления macOS, и т.п.) — напрямую.
- На Android (если этот же конфиг через Hiddify-app) — Thunderbird и K-9 Mail
  идут напрямую.

**Подводные камни:**
- `process_name` требует, чтобы sing-box имел доступ к `/proc` (Linux)
  или эквиваленту. В Docker — нужен `--pid=host` или sing-box на хосте.
- `package_name` работает только при TUN-режиме на Android (как VPN).
- На iOS process-based маршрутизация **недоступна** (system API не даёт).

### B.10 Серверный конфиг sing-box (VLESS+Reality inbound)

**Источник:** `/configuration/inbound/vless/` + `/configuration/shared/tls/`
[22]. Полный TLS Reality пример из документации.

```json
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "0.0.0.0",
      "listen_port": 443,
      "users": [
        {
          "name": "alice",
          "uuid": "00000000-0000-0000-0000-000000000000",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "www.cloudflare.com",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "www.cloudflare.com",
            "server_port": 443
          },
          "private_key": "REALITY_PRIVATE_KEY_FROM_KEYGEN",
          "short_id": ["0123456789abcdef"],
          "max_time_difference": "1m"
        }
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct-out" }
  ]
}
```

**Генерация ключей:**
```bash
sing-box generate reality-keypair
# вывод:
# PrivateKey: UuMBgl7MXTPx9inmQp2UC7Jcnwc6XYbwDNebonM-FCc
# PublicKey:  9wjeUbiP8w8I4iVi3p9J3LbphTpW3ws5WjAGz6BiL14
```

**Когда использовать sing-box на сервере вместо Xray:**
1. Нужен **Hysteria 2 inbound** одновременно с VLESS+Reality —
   sing-box делает это одним инстансом.
2. Нужны **TUIC / ShadowTLS / AnyTLS / Naive inbound** — Xray
   не умеет (см. A.2).
3. Хочется **один config-формат на клиенте и сервере** — упрощает
   обучение и автоматизацию.

**Когда НЕ ставить sing-box на сервер:**
- Если нужна панель с user management (3X-UI/Marzban) — они
  заточены под Xray, не под sing-box.
- Для CLI-управления пользователями (добавить, удалить, посмотреть
  трафик) sing-box проигрывает: всё через прямую правку JSON или
  внешние обвязки.

---

## Блок C. Известные подводные камни sing-box (которых нет в Xray)

### C.1 Breaking changes между минорными версиями

В отличие от Xray (где конфиг почти не меняется между релизами), sing-box
делает breaking changes практически в каждой минорной версии. Список
из официальной страницы Migration [17]:

**1.8.0:**
- `geoip` и `geosite` **deprecated**, заменены на `rule_set`.
- Cache file переехал из Clash API options в independent experimental config.

**1.9.0:**
- Поведение `domain_suffix` поменялось: теперь матчит `(domain|.+\.domain)`
  вместо literal prefix. **Старые конфиги ломаются.**
- Windows: формат `process_path` поменялся с system paths на Win32 format
  (`C:\folder\program.exe`).

**1.10.0:**
- TUN: `inet4_address` и `inet6_address` объединены в `address`.

**1.11.0:**
- Outbound'ы `block` и `dns` **deprecated**, заменены на rule actions
  (`reject`, `hijack-dns`).
- WireGuard outbound **deprecated**, заменён на WireGuard endpoint
  (в новой top-level секции `endpoints`).
- Inbound-level `sniff`, `domain_strategy`, `override_address`,
  `override_port` — переехали в route rule actions.

**1.12.0:**
- DNS-сервер: формат `"address": "1.1.1.1"` **deprecated**, теперь
  `"type": "udp", "server": "1.1.1.1"`.
- `geoip` и `geosite` **полностью удалены** (deprecation с 1.8).
- Outbound DNS rules deprecated.
- `domain_strategy` на outbound deprecated (теперь — domain resolver's
  `strategy`).

**1.14.0:**
- Inline ACME deprecated, теперь через certificate provider.
- `independent_cache` в DNS больше не нужен (автоматически).
- `store_rdrc` → `store_dns`.
- Адресные фильтры (`ip_cidr`, `ip_is_private`) без response matching —
  deprecated. Теперь через `evaluate` action с явным `match_response`.

**Практический вывод:** скилл агента должен либо генерировать конфиг под
конкретную версию sing-box (запрашивать `sing-box version` у пользователя),
либо генерировать «consensus»-конфиг (актуальный синтаксис без deprecated
полей), который работает на 1.12+ и до самой свежей версии.

### C.2 Несовместимость старого geoip/geosite со rule_set

Старый формат с `geoip` и `geosite` полями в правилах **удалён** в 1.12.0.
Если у пользователя конфиг старее (на 1.7-1.11 он работал, теперь не
запускается с 1.12+) — нужно переписать:

```json
// Старый формат (до 1.12) — НЕ РАБОТАЕТ в 1.12+:
{ "geosite": "category-ru", "outbound": "direct" }

// Новый формат (1.8+):
{
  "rule_sets": [
    {
      "type": "remote",
      "tag": "geosite-category-ru",
      "format": "binary",
      "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ru.srs"
    }
  ],
  "rules": [
    { "rule_set": "geosite-category-ru", "outbound": "direct" }
  ]
}
```

### C.3 DNS-нюансы (fakeip vs обычный)

- **fakeip только с 1.12.0** — на старых версиях этого типа DNS-сервера нет.
- При использовании fakeip **обязательно** правило, чтобы запросы на
  outbound `any` шли через **не-fakeip** сервер (`outbound: "any"` matches
  все исходящие, и им нужен реальный resolv для DNS-over-UDP к
  собственно DNS-серверам).
- На Android при TUN+fakeip — нужно явно отключить системный
  Private DNS, иначе он перехватывает DoH-запросы до sing-box.

### C.4 iOS-специфические ограничения

- На iOS sing-box работает **только** как NetworkExtension (через
  SagerNet/sing-box-for-apple или Hiddify-app, обёртки над тем же
  ядром). CLI-режим невозможен.
- **process_name** не работает на iOS (нет такого API).
- **TUN inbound** обязателен — других inbound на iOS быть не может
  (mixed/socks/http не сработают как system VPN).
- Memory limits — Apple даёт NetworkExtension ~50 МБ. На больших
  rule-set'ах sing-box может крашиться. Hiddify-Next в issue tracker
  периодически фиксит memory leaks под iOS.

### C.5 Hiddify-задержка по версии

Hiddify-app встраивает sing-box не в реальном времени — после релиза
sing-box 1.13.x может пройти несколько недель до релиза Hiddify-app
с этой версией ядра. Это значит:
- Если пользователь сидит на Hiddify-app, его рабочая версия sing-box
  может отставать от latest на 1-2 минор.
- Конфиги, рассчитанные на 1.14 features (например, `package_name_regex`),
  могут не работать в Hiddify-app, ещё сидящем на 1.13.
- **Решение в скилле:** при генерации конфига учесть, что **минимум
  должна поддерживаться версия, которая в Hiddify-app сейчас в Store**.
  Это можно проверить на странице релизов hiddify/hiddify-app.

### C.6 Reality public_key изменяется при regenerate

Если пользователь делает на сервере `sing-box generate reality-keypair`
заново или `xray x25519` — получает новую пару. **Все клиентские
конфиги нужно обновлять одновременно с сервером**. Это типичная боль:
после ротации ключей семья не понимает, почему интернет пропал.
Скилл-агент должен предупреждать про это в Yellow Zone брифинге.

### C.7 Reality + Vision: совместимость flow

`flow: "xtls-rprx-vision"` требует совпадения версии XTLS на сервере
и клиенте. На старых Xray (до 1.8) или старом sing-box (до 1.6) этого
flow не было. Если сервер 3X-UI с современным Xray, а клиент — старый
v2rayNG — клиент будет коннектиться, но без flow, и Reality в этом
случае работает деградированно (без обхода активных проб RKN).
**Скилл должен генерировать клиенту flow ровно тот, что задан на сервере.**

---

## Источники

[1] **sing-box GitHub repo.** `https://github.com/SagerNet/sing-box`.
    Version 1.13.12 (released 2026-05-15), 33.8k stars, 4k forks, GPL v3.0,
    Go 96.7%. Project description: "The universal proxy platform".

[2] **Xray-core GitHub repo.** `https://github.com/XTLS/Xray-core`.
    Version v26.3.27 (released 2026-03-27), 38.6k stars, 5.4k forks,
    114 releases, MPL 2.0. Fork of v2fly-core (v1.0.0).

[3] **sing-box official documentation.** `https://sing-box.sagernet.org/`.
    «The universal proxy platform», created by nekohasekai under GPLv3 (2022).

[4] **Medium: «The evolution from V2Ray to Xray to Sing-box».**
    `https://medium.com/@utso097.csekuet/the-evolution-from-v2ray-to-xray-to-sing-box-0f4ffdeb3fe7`.
    Сторонний обзор истории трёх проектов. `[уровень доверия: средний]`.

[5] **sing-box config overview.** `https://sing-box.sagernet.org/configuration/`.
    Top-level sections: log, dns, ntp, certificate, certificate_providers,
    http_clients, endpoints, inbounds, outbounds, route, services, experimental.
    Inbound: Direct, Mixed, SOCKS, HTTP, Shadowsocks, VMess, Trojan, Naive,
    Hysteria, ShadowTLS, VLESS, TUIC, Hysteria2, AnyTLS, Tun, Redirect,
    TProxy, Cloudflared. Outbound: Direct, Block, SOCKS, HTTP, Shadowsocks,
    VMess, Trojan, Naive, WireGuard, Hysteria, ShadowTLS, VLESS, TUIC,
    Hysteria2, AnyTLS, Tor, SSH, DNS, Selector, URLTest.

[6] **Xray config: inbound & outbound protocols.**
    `https://xtls.github.io/en/config/inbound.html`,
    `https://xtls.github.io/en/config/outbound.html`.
    Inbound: dokodemo-door, http, shadowsocks, socks, vless, vmess, trojan,
    wireguard, hysteria, tun. Outbound: blackhole, dns, freedom, http,
    loopback, shadowsocks, socks, trojan, vless, vmess, hysteria, wireguard.

[7] **Xray dokodemo-door:** этот «tunnel» inbound в Xray близок по семантике
    к `direct` inbound в sing-box, но не идентичен.

[8] **Xray issue: hysteria2 inbound broken.**
    `https://github.com/XTLS/Xray-core/issues/5605` (request for hysteria2
    inbound),
    `https://github.com/XTLS/Xray-core/issues/5921` (timeout on hysteria2
    inbound, Xray 26.3.27),
    `https://github.com/XTLS/Xray-core/issues/6039` (Discord WebRTC lag in
    Xray Hysteria2 TUN mode, while sing-box works normally).

[9] **VLESS + xtls-rprx-vision flow.** Документация выноса в VLESS inbound
    sing-box (`/configuration/inbound/vless/`) + Xray
    (`/config/inbounds/vless.html`).

[10] **Xray issue: wireguard inbound design.**
     `https://github.com/XTLS/Xray-core/issues/4760`.

[11] **sing-box dial fields (detour).**
     `https://sing-box.sagernet.org/configuration/shared/dial/`.
     «The tag of the upstream outbound. If enabled, all other fields will
     be ignored».

[12] **sing-box selector outbound.**
     `https://sing-box.sagernet.org/configuration/outbound/selector/`.
     Параметры: outbounds (required), default, interrupt_exist_connections.
     «The selector can currently only be managed through the Clash API
     integration feature».

[13] **sing-box urltest outbound.**
     `https://sing-box.sagernet.org/configuration/outbound/urltest/`.
     Параметры: outbounds, url (default `https://www.gstatic.com/generate_204`),
     interval (default `3m`), tolerance (default 50ms), idle_timeout
     (default `30m`), interrupt_exist_connections.

[14] **Hiddify URL Scheme.** `https://hiddify.com/app/URL-Scheme/`.
     Hiddify accepts vmess/vless/ss/trojan/tuic/hysteria/hysteria2/ssh/wg
     direct links, Clash YAML, **sing-box JSON**, V2Ray (plain or base64),
     V2Ray link format. Import via `hiddify://import/<sublink>#name`.
     Profile-Title header (optional base64).

[15] **sing-box rule-set (1.8+).**
     `https://sing-box.sagernet.org/configuration/rule-set/`.
     Types: local, remote, inline. Format: source / binary.

[16] **sing-box route rule fields.**
     `https://sing-box.sagernet.org/configuration/route/rule/`.
     Полный список полей с версионными метками (1.8+, 1.10+, 1.11+, 1.13+, 1.14+).

[17] **sing-box migration guide.**
     `https://sing-box.sagernet.org/migration/`.
     Breaking changes from 1.8.0 to 1.14.0 inclusive.

[18] **DarkCat09/sb-vs-xray benchmark.** `https://git.dc09.ru/DarkCat09/sb-vs-xray`.
     Сторонний синтетический бенчмарк iperf3 через sing-box и Xray на разных
     протоколах. Результат: оба ядра «почти одинаковы», Xray иногда чуть быстрее.
     `[уровень доверия: средний — не peer-reviewed]`.

[19] **NTC discussion: «Sing-box vs Xray vs ...?»**
     `https://ntc.party/t/sing-box-vs-xray-vs/24125`.
     Тематический форум tunneling-software с разбором сравнений.
     `[уровень доверия: средний]`.

[20] **Hiddify Manager: Xray and Sing-box.**
     `https://deepwiki.com/hiddify/Hiddify-Manager/4.1-xray-and-sing-box`.
     Описание архитектуры Hiddify-Manager — он использует оба ядра
     параллельно для разных сценариев.

[21] **sing-box VLESS outbound.**
     `https://sing-box.sagernet.org/configuration/outbound/vless/`.

[22] **sing-box TLS shared config (Reality).**
     `https://sing-box.sagernet.org/configuration/shared/tls/`.
     Поле `reality` для inbound: handshake.server, handshake.server_port,
     private_key, short_id (array), max_time_difference.

[23] **SagerNet/sing-geoip.** `https://github.com/SagerNet/sing-geoip`.
     Repository with geoip-based rule-sets in .srs binary format
     (branch `rule-set/`).

[24] **SagerNet/sing-geosite.** `https://github.com/SagerNet/sing-geosite`.
     Repository with domain category rule-sets in .srs binary format
     (branch `rule-set/`).

[25] **sing-box TUN inbound.**
     `https://sing-box.sagernet.org/configuration/inbound/tun/`.
     Поля: interface_name, address (1.10+, заменяет inet4_address/inet6_address),
     mtu, auto_route, auto_redirect (Linux only, рекомендуется), strict_route
     (Windows: anti-DNS-leak), stack (system/gvisor/mixed).

[26] **sing-box fakeip DNS.**
     `https://sing-box.sagernet.org/configuration/dns/server/fakeip/`.
     Type: fakeip. inet4_range (default `198.18.0.0/15`), inet6_range
     (default `fc00::/18`). Доступно с 1.12.0.

---

## Что осталось непроверенным / требует уточнения

1. **URL'ы официальных rule-set'ов** — паттерн
   `https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/<name>.srs`
   взят из структуры репо. На момент написания не проверена
   стабильность этой схемы (может смениться ветка/папка). Перед
   использованием в скилле — проверить актуальные URL'ы прямо
   в README этих репо.

2. **Multi-hop VLESS → VLESS через `detour`** (B.5) — не нашёл
   verified prod-конфигов, где это явно работает с Reality на обеих
   нодах. Документация sing-box `detour` не предупреждает о
   несовместимости, но Reality чувствителен к chain'ам. Требует
   проверки на реальном инстансе.

3. **Производительность sing-box vs Xray на slow CPU** (ARM на роутере,
   старый VPS на 1 vCPU) — нет публичных бенчмарков. На больших
   throughput оба ядра упираются в Go runtime + криптографию.

4. **Subscription-Userinfo header в Hiddify** — стандарт clash, не
   подтверждён в основной странице URL-Scheme. Может работать,
   может нет. Требует ручной проверки на свежей версии Hiddify-app.

5. **Точная задержка Hiddify-app по версии ядра sing-box** — варьируется,
   нет публичной политики. Утверждение в C.5 — `[непроверено]` как
   систематический паттерн, основано на разовых наблюдениях из
   issue trackers.

6. **process_name на macOS под Apple Silicon** — иногда не работает,
   если sing-box запущен через launchd vs через CLI. Точных условий
   не нашёл, нужна экспериментальная проверка.
