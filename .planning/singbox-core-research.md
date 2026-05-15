# Sing-box: ядро и JSON-конфиг

**Дата:** 2026-05-15
**Версии на момент сбора:**
- Последний стабильный: **v1.13.12** (15 мая 2026), полный список — [github.com/SagerNet/sing-box/releases](https://github.com/SagerNet/sing-box/releases)
- Альфа-серия: 1.14.0-alpha (готовится; уже видны изменения вроде `tls_spoof`, `mdns`, `evaluate` action — но они **непроверены** для прод)
- Ключевые мажорные релизы 2024-2026: 1.10.0, 1.11.0, 1.12.0, 1.13.0

**Уровень доверия:** проставлен в каждом блоке. По умолчанию — высокий (официальная документация sing-box.sagernet.org или релизы на GitHub). «Средний» = вывод из одного источника без верификации. «Непроверено» = не нашёл подтверждения.

**Парные рисёрчи (не дублирую):**
- `.planning/vpn-research.md` — Xray, 3X-UI, серверные сборки
- `.planning/singbox-clients-research.md` — клиенты (SFI/SFM/SFA, Hiddify, NekoBox и др.)

---

## 1. Введение

**Уровень доверия:** высокий.

- **Автор и поддержка:** проект ведёт **nekohasekai** через org [SagerNet](https://github.com/SagerNet) (он же — автор Surfboard, V2RayNG, NekoBox/NekoRay). Источник: [github.com/SagerNet/sing-box](https://github.com/SagerNet/sing-box).
- **Лицензия:** **GPL v3.0** с дополнением: производные работы не имеют права использовать имя «sing-box» или подразумевать аффилиацию без согласия. Источник: страница репо на GitHub.
- **Дата появления:** первый коммит — **июль 2022**, первый релиз v1.0.0 — апрель 2023 (по [тегам](https://github.com/SagerNet/sing-box/tags), точные даты не валидировал — **средний уровень доверия**).
- **Активность (на 2026-05-15):** ~33.8k звёзд, ~4k форков, 539 релизов, 188 watchers, 213 open issues, ~2.4k коммитов. Источник: [github.com/SagerNet/sing-box](https://github.com/SagerNet/sing-box).
- **Описание:** «The universal proxy platform» — одна бинарка, объединяющая роль клиента и сервера для широкого набора протоколов (Shadowsocks, VLESS/VMess, Trojan, Hysteria/Hysteria2, TUIC, ShadowTLS, AnyTLS, NaiveProxy, WireGuard, SSH, Tor).
- **Язык:** Go ~96.7%.
- **Официальная документация:** [sing-box.sagernet.org/configuration/](https://sing-box.sagernet.org/configuration/) (привязана к ветке `dev-next`, может опережать стабильный релиз; для версии нужно смотреть подверсии на каждой странице — у каждого поля помечено «Changes in 1.X.0»).
- **CLI-команды для работы с конфигом** ([из обзора root-страницы](https://sing-box.sagernet.org/configuration/)):
  - `sing-box check` — валидация JSON-конфига
  - `sing-box format` — переформатирование
  - `sing-box merge` — объединение нескольких файлов конфига
  - `sing-box rule-set compile/decompile/merge/match` — работа с rule-set
  - `sing-box generate reality-keypair` — генерация ключей для Reality

---

## 2. Структура JSON-конфига — верхнеуровневые блоки

**Уровень доверия:** высокий. Источник: [sing-box.sagernet.org/configuration/](https://sing-box.sagernet.org/configuration/).

В современном sing-box (1.12+) верхнеуровневые секции таковы:

| Блок | Назначение | Документация |
|---|---|---|
| `log` | Уровень логирования, файл/stdout, timestamp | [log/](https://sing-box.sagernet.org/configuration/log/) |
| `dns` | DNS-серверы, DNS-правила, fakeip, стратегия | [dns/](https://sing-box.sagernet.org/configuration/dns/) |
| `ntp` | Встроенный NTP-клиент (для случаев, когда часы системы не синхронизировать) | [ntp/](https://sing-box.sagernet.org/configuration/ntp/) |
| `certificate` | Доверенные CA (1.12+) | [certificate/](https://sing-box.sagernet.org/configuration/certificate/) |
| `certificate_providers` | ACME / Tailscale / Cloudflare как провайдеры серт-в (1.14+, **непроверено для 1.13**) | [shared/certificate-provider/](https://sing-box.sagernet.org/configuration/shared/certificate-provider/) |
| `http_clients` | Кастомный HTTP-клиент для load remote rule-set, ACME и пр. (1.14+, **непроверено для 1.13**) | [shared/http-client/](https://sing-box.sagernet.org/configuration/shared/http-client/) |
| `endpoints` | Двунаправленные протоколы (WireGuard, Tailscale) — введён в 1.11 | [endpoint/](https://sing-box.sagernet.org/configuration/endpoint/) |
| `inbounds` | Входящие подключения (TUN, mixed, vless-server и т.д.) | [inbound/](https://sing-box.sagernet.org/configuration/inbound/) |
| `outbounds` | Исходящие подключения (proxy-протоколы + direct/selector/urltest) | [outbound/](https://sing-box.sagernet.org/configuration/outbound/) |
| `route` | Правила маршрутизации, rule actions, sniff, rule_set | [route/](https://sing-box.sagernet.org/configuration/route/) |
| `services` | Фоновые сервисы (DERP, resolver, кастомные API) | [service/](https://sing-box.sagernet.org/configuration/service/) |
| `experimental` | Clash API, cache_file, V2Ray API (статистика) | [experimental/](https://sing-box.sagernet.org/configuration/experimental/) |

### Эволюция формата по версиям — кратко

- До **1.10** не было ни `endpoints`, ни rule actions, ни inline rule-set. Был `geoip`/`geosite` как первоклассные поля правил.
- **1.10.0** добавил inline rule-set, auto-redirect, объединил `inet4_address`/`inet6_address` в TUN в один `address`.
- **1.11.0** ввёл **rule actions** (см. §4), `endpoints`, network_strategy, депрекейтил `block`/`dns`-аутбаунды и WireGuard outbound (он будет удалён в 1.13).
- **1.12.0** — большой DNS-рефактор: серверы переписаны на формат `{"type": "...", "server": "..."}`, fakeip-серверы помечены deprecated (удалятся в 1.14), добавлены AnyTLS, TLS-фрагментация в route-options, certificate-блок, Tailscale-endpoint.
- **1.13.0** — введены `reject` с methods (`drop`/`reply`), `bypass` action для Linux auto_redirect, окончательно удалён WireGuard outbound.
- **1.14.0 alpha** — переход inline ACME → `certificate_providers`, `evaluate` action, `tls_spoof` в route-options. **Непроверено для прод** на 2026-05-15.

Источник эволюции: [sing-box.sagernet.org/migration/](https://sing-box.sagernet.org/migration/), changelog в release notes [v1.10.0](https://github.com/SagerNet/sing-box/releases/tag/v1.10.0), [v1.11.0](https://github.com/SagerNet/sing-box/releases/tag/v1.11.0), [v1.12.0](https://github.com/SagerNet/sing-box/releases/tag/v1.12.0).

---

## 3. Inbounds и outbounds — каталог протоколов

**Уровень доверия:** высокий по составу таблицы, отдельные нюансы — по сноскам.

Источники: [inbound/](https://sing-box.sagernet.org/configuration/inbound/), [outbound/](https://sing-box.sagernet.org/configuration/outbound/).

| Протокол | Inbound | Outbound | Заметки |
|---|---|---|---|
| `mixed` | да | — | SOCKS+HTTP на одном порту |
| `socks` | да | да | классический SOCKS5 |
| `http` | да | да | HTTP/HTTPS-прокси |
| `vless` | да | да | поддержка flow `xtls-rprx-vision` (см. §3.1), Reality в TLS-блоке |
| `vmess` | да | да | устаревший, но поддерживается |
| `trojan` | да | да | HTTPS-маскировка |
| `shadowsocks` | да | да | AEAD-шифры, plugins |
| `hysteria` | да | да | QUIC-based, считается legacy относительно Hysteria2 |
| `hysteria2` | да | да | TLS-required, salamander-обфускация, masquerade |
| `tuic` | да | да | QUIC, конгешн: cubic/new_reno/bbr |
| `shadowtls` | да | да | маскировка под произвольный TLS-сайт |
| `anytls` | да | да | новый протокол в **1.12+** ([релиз 1.12.0](https://github.com/SagerNet/sing-box/releases/tag/v1.12.0)) |
| `naive` | да | да (через `with_naive_outbound` build-tag, см. §8.1) | HTTP/2 от Klzgrad |
| `wireguard` | — | **удалён в 1.13** | мигрировать на `endpoints` ([wireguard outbound docs](https://sing-box.sagernet.org/configuration/outbound/wireguard/)) |
| `ssh` | — | да | SSH-туннель |
| `tun` | да | — | системный туннель (Linux/Windows/macOS, mobile через клиенты) |
| `redirect` | да | — | NAT-redirect (Linux iptables REDIRECT) |
| `tproxy` | да | — | прозрачный прокси через iptables TPROXY |
| `direct` | — | да | прямое соединение |
| `block` | — | **удалён в 1.11** | мигрировать на `"action": "reject"` ([migration](https://sing-box.sagernet.org/migration/)) |
| `dns` | — | **удалён в 1.11** | мигрировать на `"action": "hijack-dns"` |
| `selector` | — | да (логический) | переключаемый набор аутбаундов; рулится **через Clash API** |
| `urltest` | — | да (логический) | автовыбор по latency (`https://www.gstatic.com/generate_204` по умолчанию, интервал 3m, tolerance 50ms, idle_timeout 30m) |
| `tor` | — | да | embedded Tor (CGO, opt-in build tag `with_embedded_tor`) |

### 3.1. VLESS — Reality и flow

**Уровень доверия:** высокий (Reality), средний (другие flow).

- VLESS-inbound поддерживает Reality через подблок `tls.reality.enabled` с полями `handshake.server`/`handshake.server_port`, `private_key`, `short_id`. Ключи генерируются через `sing-box generate reality-keypair`. Источник: [shared/tls/](https://sing-box.sagernet.org/configuration/shared/tls/).
- В документации VLESS явно перечислен **только flow `xtls-rprx-vision`**. Другие flow (`xtls-rprx-origin` и т.п. из ранних Xray) **не подтверждены** для sing-box. Источник: [inbound/vless/](https://sing-box.sagernet.org/configuration/inbound/vless/).

### 3.2. AnyTLS

- Введён в **1.12.0** как новый протокол маскировки. Цель — снизить характеристики TLS-прокси-трафика (детектируемые DPI). Источник: [релиз 1.12.0](https://github.com/SagerNet/sing-box/releases/tag/v1.12.0), [inbound/anytls/](https://sing-box.sagernet.org/configuration/inbound/anytls/).
- Обязательные поля inbound: `users` (`name` + `password`), TLS. Опционально — `padding_scheme` (массив строк; есть встроенная схема с восемью пресетами).
- Поддерживается мультиплексирование.

### 3.3. WireGuard — особый случай

- В **1.11.0** WireGuard выделили в новый тип верхнего уровня — `endpoints`. WireGuard outbound помечен deprecated и **окончательно удалён в 1.13.0**. Источник: [outbound/wireguard/](https://sing-box.sagernet.org/configuration/outbound/wireguard/), миграция — [migration page](https://sing-box.sagernet.org/migration/).
- Пример миграции (до/после) — см. §8.

### 3.4. selector vs urltest — что выбрать

- `selector` — статика: пользователь руками меняет активный outbound (через Clash API дашборд yacd/metacubexd). Поле `interrupt_exist_connections: true` рвёт активные сессии при смене.
- `urltest` — авто: пингует все аутбаунды и выбирает с минимальной задержкой; tolerance ограничивает «дёргание» между близкими по latency узлами.

Источники: [outbound/selector/](https://sing-box.sagernet.org/configuration/outbound/selector/), [outbound/urltest/](https://sing-box.sagernet.org/configuration/outbound/urltest/).

---

## 4. Route rules — сердце ядра

**Уровень доверия:** высокий. Источник: [configuration/route/rule/](https://sing-box.sagernet.org/configuration/route/rule/), [rule_action/](https://sing-box.sagernet.org/configuration/route/rule_action/).

### 4.1. Top-level поля блока `route`

Источник: [configuration/route/](https://sing-box.sagernet.org/configuration/route/).

| Поле | Назначение |
|---|---|
| `rules` | массив правил (см. §4.2-§4.3) |
| `rule_set` | массив определений rule-set (см. §4.5) |
| `final` | тег outbound по умолчанию, если ни одно правило не сматчилось; если пусто — первый из `outbounds` |
| `auto_detect_interface` | привязка исходящих к интерфейсу по умолчанию для защиты от петель (Linux/Windows/macOS) |
| `default_interface` | ручное указание интерфейса (если auto-detect недостаточно) |
| `default_mark` | routing mark для Linux |
| `default_domain_resolver` | какой DNS-сервер использовать для резолва доменов в правилах (1.12+, заменяет старый `domain_strategy`) |
| `default_http_client` | HTTP-клиент для remote rule-set (1.14+) |
| `find_process` | enable детекта процесса (process_name/path) |
| `find_neighbor` | резолв соседей по DHCP-leases для `source_mac_address`/`source_hostname` |
| `dhcp_lease_files` | кастомные пути lease-файлов |

### 4.2. Поля правил (matchers)

**Уровень доверия:** высокий. Источник: [route/rule/](https://sing-box.sagernet.org/configuration/route/rule/).

**Домен:**
- `domain` — точный матч
- `domain_suffix` — суффикс (например, `.cn`)
- `domain_keyword` — подстрока
- `domain_regex` — регулярка

**IP и сеть:**
- `ip_cidr` — назначение
- `source_ip_cidr` — источник
- `ip_is_private` / `source_ip_is_private` — приватные диапазоны (RFC1918, link-local)
- `geoip` / `source_geoip` — **deprecated**, мигрировать на rule_set
- `geosite` — **deprecated**, мигрировать на rule_set
- `ip_version` — 4 или 6

**Порты / протоколы:**
- `port` — список (например `[443, 8443]`)
- `port_range` — `"1000:2000"`
- `source_port`, `source_port_range`
- `network` — `tcp`/`udp`/`icmp`
- `protocol` — снифферный матч: `tls`, `http`, `quic`, `stun`, `dns`, `bittorrent`, `dtls`, `ssh`, `rdp`, `ntp` (см. §4.6)

**Процесс и пользователь:**
- `process_name` — имя бинарника (Linux/Windows/macOS, **не работает на мобильных**)
- `process_path` — полный путь
- `process_path_regex` — регулярка по пути (добавлено в 1.10)
- `package_name` / `package_name_regex` — **только Android**
- `user` — имя UNIX-пользователя (Linux)
- `user_id` — UID

**Сетевой контекст (мобильные клиенты):**
- `network_type` — `wifi`/`cellular`/`ethernet`/`other` (добавлено в 1.11)
- `network_is_expensive` — метеред-сети (мобильный интернет в роуминге)
- `network_is_constrained` — Low Data Mode на Apple
- `wifi_ssid`, `wifi_bssid`
- `interface_address` / `network_interface_address` / `default_interface_address`
- `source_mac_address`, `source_hostname` (требуют `find_neighbor: true`)

**Sniffed/Auth:**
- `inbound` — фильтр по tag входящего
- `auth_user` — имя авторизованного юзера (для inbound с auth)
- `client` — тип клиента из QUIC-сниффинга (`chromium`, `safari`, `firefox`, `quic-go`)
- `clash_mode` — режим Clash (`Global`/`Direct`/`Rule`), задаваемый через Clash API
- `rule_set` — ссылка на готовый rule-set
- `rule_set_ip_cidr_match_source` — заставить ip_cidr из rule-set матчиться с источником

**Спецполя:**
- `preferred_by` — маршрутизация по предпочтению Tailscale/WireGuard (1.12+)
- `invert: true` — инвертирует весь матч правила

### 4.3. Logical rules

```json
{
  "type": "logical",
  "mode": "and",   // или "or"
  "rules": [ {...}, {...} ],
  "action": "route",
  "outbound": "proxy"
}
```

NOT эмулируется через `invert: true` на вложенном правиле. Источник: [route/rule/](https://sing-box.sagernet.org/configuration/route/rule/).

### 4.4. Rule actions (введены в 1.11)

**Уровень доверия:** высокий. Источник: [rule_action/](https://sing-box.sagernet.org/configuration/route/rule_action/).

Действия делятся на **финальные** (завершают обработку правил) и **нефинальные** (модифицируют контекст, обработка продолжается).

**Финальные:**

| Action | Поля | Назначение |
|---|---|---|
| `route` | `outbound` (обяз.), плюс все поля из `route-options` | направить трафик в указанный outbound |
| `reject` | `method` (`default`/`drop`/`reply`, дефолт `default`), `no_drop` (boolean) | разрыв. `method=reply` — отвечает TCP RST или ICMP unreachable. Введён детально в **1.13.0** |
| `bypass` | `outbound`, плюс route-options | для Linux `auto_redirect` — обход sing-box на уровне ядра. **1.13.0+** |
| `hijack-dns` | — | перенаправить DNS-запрос во внутренний DNS-модуль |

**Нефинальные:**

| Action | Поля | Назначение |
|---|---|---|
| `sniff` | `sniffer` (массив имён снифферов), `timeout` (default `300ms`) | включить определение протокола/SNI/Host |
| `resolve` | `server`, `strategy`, `disable_cache` (1.12+), `rewrite_ttl`, `client_subnet` (1.12+), `timeout` (1.14+) | разрезолвить домен → IP перед матчем последующих правил |
| `route-options` (как отдельный action) | `override_address`, `override_port`, `network_strategy`, `network_type`, `fallback_network_type`, `fallback_delay`, `udp_disable_domain_unmapping`, `udp_connect`, `udp_timeout`, `tls_fragment` (1.12+), `tls_fragment_fallback_delay` (1.12+), `tls_record_fragment` (1.12+), `tls_spoof` (1.14+), `tls_spoof_method` (1.14+) | модификация параметров диалога без выбора outbound |

**Пример простой замены deprecated:**

```json
// До 1.11 (deprecated)
"outbounds": [{"type": "block", "tag": "block"}],
"route": {"rules": [{"domain": "ads.com", "outbound": "block"}]}

// 1.11+
"route": {"rules": [{"domain": "ads.com", "action": "reject"}]}
```

Источник: [migration page](https://sing-box.sagernet.org/migration/), [issue #3472](https://github.com/SagerNet/sing-box/issues/3472).

### 4.5. Rule-set: формат и источники

**Уровень доверия:** высокий. Источник: [configuration/rule-set/](https://sing-box.sagernet.org/configuration/rule-set/).

Три варианта подключения:

1. **Inline** (с 1.10) — определение прямо в конфиге.
2. **Local** — путь к файлу на диске, авто-перезагрузка при изменении файла.
3. **Remote** — URL, периодическое скачивание; кэшируется при `experimental.cache_file.enabled`.

**Форматы:**
- **source** — JSON, человекочитаемый (`*.json`)
- **binary** — компилированный `*.srs`, быстрее и компактнее. Получается через `sing-box rule-set compile <input.json>`.

**Поля remote-источника:**
- `type: "remote"`, `format`, `tag`
- `url` — URL `.srs` файла
- `update_interval` — дефолт `1d`
- `download_detour` — **deprecated в 1.14**, заменено на `http_client`
- `http_client` — кастомный HTTP-клиент (1.14+)

**Готовые наборы (от SagerNet):**
- [github.com/SagerNet/sing-geoip](https://github.com/SagerNet/sing-geoip) — GeoIP, ~298★, GPLv3
- [github.com/SagerNet/sing-geosite](https://github.com/SagerNet/sing-geosite) — Geosite, ~885★, GPLv3
- URL-паттерн для прямой загрузки (**средний уровень доверия — не валидировал точные ветки**): обычно `https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs` и `https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs`. Конкретные имена файлов смотреть в ветке `rule-set` репозитория.

### 4.6. Sniffing

**Уровень доверия:** высокий. Источник: [route/sniff/](https://sing-box.sagernet.org/configuration/route/sniff/), [migration](https://sing-box.sagernet.org/migration/).

Что распознаётся:
- **HTTP** — домен из Host-хедера
- **TLS** — SNI
- **QUIC** — Server Name + клиент (chromium/safari/firefox/quic-go)
- **STUN, DNS, BitTorrent, DTLS, SSH, RDP, NTP**

В **1.10** ещё были `sniff`, `sniff_timeout`, `sniff_override_destination` как поля inbound. В **1.11** их перенесли в action `sniff` (см. §4.4) с полем `timeout`. Override адреса теперь делается через action `route-options.override_address` / `override_port`.

---

## 5. DNS-конфигурация

**Уровень доверия:** высокий, кроме отдельной отметки про fakeip.

Источники: [configuration/dns/](https://sing-box.sagernet.org/configuration/dns/), [dns/rule/](https://sing-box.sagernet.org/configuration/dns/rule/), [dns/server/](https://sing-box.sagernet.org/configuration/dns/server/).

### 5.1. Top-level поля блока `dns`

| Поле | Назначение |
|---|---|
| `servers` | список DNS-серверов (см. §5.2) |
| `rules` | DNS-правила (см. §5.3) |
| `strategy` | `prefer_ipv4` / `prefer_ipv6` / `ipv4_only` / `ipv6_only` (дефолт стратегии резолва) |
| `disable_cache` | отключить кэш (несовместимо с optimistic) |
| `disable_expire` | кэш без TTL-экспирации |
| `cache_capacity` | LRU-кэш, минимум 1024 |
| `independent_cache` | **deprecated, удалён в 1.14** (раньше — изолировал кэш по серверам) |
| `reverse_mapping` | хранить reverse-маппинг IP→домен для подстановки доменов в логи маршрутизации |
| `client_subnet` | подставлять EDNS Client Subnet OPT в запросы |
| `final` | дефолтный тег DNS-сервера |

### 5.2. Типы DNS-серверов

**Старый формат (до 1.12, deprecated, удалится в 1.14):**
```json
{"address": "tls://1.1.1.1"}
```

**Новый формат (1.12+):**
```json
{"type": "tls", "tag": "cf", "server": "1.1.1.1"}
```

Поддерживаемые типы:

| Тип | Транспорт | Заметки |
|---|---|---|
| `udp` | UDP/53 | дефолт |
| `tcp` | TCP/53 | |
| `tls` | DoT (TLS поверх 853) | |
| `https` | DoH | стандартный путь `/dns-query` |
| `quic` | DoQ | |
| `h3` | DoH3 (HTTP/3) | поддерживается |
| `local` | системный резолвер | использует ОС |
| `hosts` | inline hosts-файл | домен → IP |
| `fakeip` | синтетика | **deprecated в 1.12.0, будет удалён в 1.14** (см. ниже) |
| `mdns` | multicast DNS | **1.14+, непроверено для прод** |

### 5.3. DNS rules

Поля матчинга — большинство из тех же, что в route-rule, плюс DNS-специфичные:

- `query_type` — `A`, `AAAA`, `HTTPS`, или числа
- `network` — `tcp`/`udp` (по какому транспорту пришёл запрос)
- `match_response: true` — матчить ответ (введено для случаев, когда нужно проверить полученный IP)
- `response_rcode`, `response_answer`, `response_ns`, `response_extra` — поля ответа

DNS rules применяются ко всем DNS-запросам внутри sing-box и выбирают **какой DNS-сервер** будет использован (или сразу `reject`/predefined-ответ через действия). Route-rules применяются к **сетевому трафику** уже после резолва. На стыке: action `resolve` в route-правиле триггерит DNS-резолв и затем применяет последующие правила к IP.

### 5.4. fakeip — нюансы

**Уровень доверия:** высокий (про депрекейт), средний (про текущее поведение).

- **Default ranges:** `inet4_range: 198.18.0.0/15`, `inet6_range: fc00::/18` (источник: [dns/fakeip/](https://sing-box.sagernet.org/configuration/dns/fakeip/)).
- **Депрекейт:** fakeip как DNS-сервер помечен deprecated в 1.12.0 и удаляется в 1.14. Замена — новый паттерн через `domain_resolver` и cache_file (детали в migration guide; **полная схема замены непроверена**).
- **Связь с cache_file:** `experimental.cache_file.store_fakeip: true` сохраняет маппинг domain↔fakeip между перезапусками.
- **Подводный камень (1.12+):** «All internal DNS queries now skip DNS rules with server type fakeip, and the default DNS server can no longer be fakeip» (источник: [changelog](https://sing-box.sagernet.org/changelog/) и issue tracker). Это **специально** ломает «неправильные» конфиги, где fakeip стоял как дефолтный сервер для всего трафика.

---

## 6. Experimental features

**Уровень доверия:** высокий.

Источник: [experimental/](https://sing-box.sagernet.org/configuration/experimental/), подразделы.

### 6.1. clash_api ([clash-api/](https://sing-box.sagernet.org/configuration/experimental/clash-api/))

| Поле | Дефолт | Заметки |
|---|---|---|
| `external_controller` | пусто (отключено) | формат `127.0.0.1:9090`. Документация настаивает: **если выставляешь 0.0.0.0, обязательно ставь `secret`** |
| `external_ui` | пусто | путь к директории со статикой дашборда, отдаётся по `/ui` |
| `external_ui_download_url` | `https://github.com/MetaCubeX/Yacd-meta/archive/gh-pages.zip` | автоскачивание дашборда |
| `secret` | пусто | токен для Bearer-авторизации |
| `default_mode` | `Rule` | начальный clash-режим (используется через `clash_mode` в правилах) |
| `cache_file`/`cache_id` | **deprecated с 1.8** | заменено на `experimental.cache_file` |

Совместимые дашборды: **Yacd-meta** (по умолчанию), плюс по сообществу — **metacubexd**, **zashboard**, оригинальный yacd (**средний уровень доверия** — в официальной доке упомянут только Yacd-meta).

**Что НЕ работает из Clash:** sing-box реализует Clash API частично. Точного списка поддержанных эндпоинтов в документации нет — **непроверено**. Известно, что управление selector работает, переключение mode работает, чтение статистики connections работает.

### 6.2. cache_file ([cache-file/](https://sing-box.sagernet.org/configuration/experimental/cache-file/))

| Поле | Дефолт | Заметки |
|---|---|---|
| `enabled` | false | |
| `path` | `cache.db` | в working dir |
| `cache_id` | пусто | разделяет данные внутри одного файла по конфигам |
| `store_fakeip` | false | сохранять маппинг fakeip между рестартами |
| `store_rdrc` | — | **deprecated, удалится в 1.16** |
| `rdrc_timeout` | `7d` | срок жизни rejected-DNS-cache |
| `store_dns` | false | **1.14+**, кэшировать DNS-ответы между рестартами |

Назначение: персистентность DNS, fakeip-маппингов, remote rule-set между перезапусками.

### 6.3. v2ray_api

Совместимый с V2Ray gRPC API для **статистики трафика** (per-outbound bytes in/out) и базового управления. Включается через build tag `with_v2ray_api` (opt-in, см. §8.1). Полей конфига в официальной доке немного — детально не валидировал, **средний уровень доверия по составу полей**.

---

## 7. Серверный sing-box

**Уровень доверия:** средний — это вывод, а не цитата из доки.

### 7.1. Когда sing-box лучше Xray на сервере

- **Hysteria2** — sing-box и есть основная реализация (раньше был отдельный проект apernet/hysteria, но sing-box — наиболее активная Go-реализация в составе универсальной платформы).
- **TUIC** — аналогично, sing-box — одна из главных серверных реализаций.
- **AnyTLS** — реализован только в sing-box (на 2026-05-15 других серверных реализаций **не подтверждено**).
- **WireGuard** — sing-box предоставляет user-space реализацию (через `endpoints`), удобно когда нет прав на ядерный WireGuard или хочется одну бинарку.
- **Когда Xray лучше:** XTLS с любыми flow кроме vision, REALITY с расширениями, поддержка legacy-клиентов V2RayNG (см. parallel research `vpn-research.md`).

### 7.2. Серверный VLESS+Reality

sing-box умеет так же, как Xray. Поля: `tls.enabled`, `tls.server_name` (домен-донор для маскировки), `tls.reality.enabled`, `tls.reality.handshake.server`/`server_port` (адрес донора SNI), `tls.reality.private_key` (из `sing-box generate reality-keypair`), `tls.reality.short_id` (массив hex-строк длиной 0-8). Источник: [shared/tls/](https://sing-box.sagernet.org/configuration/shared/tls/).

Конкретные шаблоны конфига — в `vpn-research.md`, здесь только структура.

---

## 8. Версионная карта 1.10–1.13 (и про 1.14)

### 8.1. 1.10.0 (источник: [release notes](https://github.com/SagerNet/sing-box/releases/tag/v1.10.0))

**Новое:**
- Auto-redirect (Linux) — авто-настройка iptables redirect для TUN
- AdGuard DNS Filter rule lists без AdGuard Home
- **Inline rule-set** — headless rules внутри конфига
- Новые sniffers: BitTorrent, DTLS, RDP, SSH; улучшен QUIC-sniffer (client detection)
- Clash API access control — ограничения по сайтам
- `rule_set_ip_cidr_accept_empty` в DNS address filter
- Auto-reload локальных rule-set
- JSON trailing comma в конфигах
- `rule-set decompile`, IP-поиск в `rule-set match`
- `process_path_regex`

**Breaking:**
- Минимум Go 1.20 для сборки
- TUN: `inet4_address`+`inet6_address` → один `address`
- Rule-set: новый формат версии (старые `.srs` нужно перекомпилировать)

### 8.2. 1.11.0 (источник: [release notes](https://github.com/SagerNet/sing-box/releases/tag/v1.11.0))

**Новое:**
- **Rule actions** — главная фича релиза (см. §4.4)
- **`endpoints` блок** — WireGuard и Tailscale переехали сюда
- Network strategy — multi-interface dialing с fallback
- DNS `cache_capacity`
- `override_address`/`override_port` в route-options
- Hysteria2 port hopping, расширенные masquerade-опции
- `rule-set merge` команда
- `network_type`/`network_is_expensive`/`network_is_constrained` matchers
- TUN gvisor stack улучшен

**Breaking / deprecated:**
- Special outbounds `block` и `dns` → rule actions `reject` и `hijack-dns`
- Inbound поля `sniff`/`sniff_timeout` → action `sniff`
- Inbound `domain_strategy` → action `resolve`
- WireGuard outbound deprecated (удалится в 1.13)
- GSO опция убрана из TUN (перешла в WireGuard)

### 8.3. 1.12.0 (источник: [release notes](https://github.com/SagerNet/sing-box/releases/tag/v1.12.0))

**Новое:**
- **DNS-серверы переписаны** на формат `{type, server}` (см. §5.2). Старый формат пока работает.
- **AnyTLS** протокол (inbound+outbound)
- **TLS fragment** в route-options (`tls_fragment`, `tls_record_fragment`)
- **Domain resolver** — заменяет `domain_strategy` в outbound dial fields
- **Certificate** блок — управление trusted CA (system list, Mozilla CCADB)
- **Tailscale** endpoint и DNS server
- TUN performance improvements на Apple (M4 MBP: 39.8G vs 27.6G в 1.11)

**Breaking:**
- Минимум Go 1.23
- `with_ech` build tag удалён (ECH в stdlib)
- fakeip DNS server type deprecated (удалится в 1.14)
- DNS legacy `outbound` rule item deprecated → `domain_resolver`

### 8.4. 1.13.0

**Источник:** [release notes 1.13.0](https://github.com/SagerNet/sing-box/releases/tag/v1.13.0) (**средний уровень доверия — детали ниже взяты из rule_action docs**)

**Новое:**
- `reject` action с `method` (`drop`/`reply`) и `no_drop` (см. §4.4)
- `bypass` action для Linux auto_redirect

**Breaking:**
- WireGuard outbound **окончательно удалён** (мигрировать обязательно)

### 8.5. 1.14.0 (в разработке, alpha)

**Уровень доверия:** средний/непроверено. Все ниже — из документации, привязанной к dev-next.

- `evaluate` action, `match_response` в DNS rules → новый паттерн адресной фильтрации
- `tls_spoof`/`tls_spoof_method` в route-options
- ACME inline опции → новый `certificate_providers` блок
- fakeip DNS server type **удалён**
- `independent_cache` DNS опция **удалена**
- Legacy DNS server format (с одним `address`) **удалён**
- `download_detour` в rule-set → `http_client`
- `store_rdrc` будет удалён в 1.16
- `mdns` DNS server type добавлен

### 8.6. На какой версии останавливаться для совместимости с клиентами в РФ

**Уровень доверия:** средний (на стыке с parallel research).

По данным `.planning/singbox-clients-research.md`, в России активно используются клиенты:
- **Hiddify** (часто отстаёт от ядра — например, был запрос на обновление до 1.10.7 и 1.11.15)
- **SFI/SFM/SFA** (родной клиент SagerNet) — обычно догоняет быстро
- **NekoBox/NekoRay** — использует sing-box ядром, версии современные
- **v2rayN** — может иметь sing-box ядром

**Рекомендация для агента-сисадмина** (вывод, не из доки): для серверной стороны держаться на стабильной **1.12.x или 1.13.x** — это покрывает все современные клиенты sing-box. AnyTLS требует **минимум 1.12** и на сервере, и на клиенте. Конкретные пары «версия клиента ↔ версия ядра sing-box» — в client-research.

---

## 9. Известные подводные камни

**Уровень доверия:** средний — это выжимка из issues + community-discussions.

1. **Миграция 1.10 → 1.11 болезненная.** `sing-box check` не указывает строку с deprecated-полем; пользователи жалуются ([issue #3432](https://github.com/SagerNet/sing-box/issues/3432)). Решение: запускать `sing-box` и смотреть warning в логах; искать deprecated-ключи руками.

2. **Block-action иногда «не блокирует так, как block-outbound».** Пользователь [issue #3472](https://github.com/SagerNet/sing-box/issues/3472) жаловался, что `reject` action не даёт прежней гибкости (например, временно разрешить домен). Maintainer закрыл как duplicate — решается через `clash_mode` или динамические rule-set.

3. **Hiddify отстаёт по версии sing-box.** Отдельный форк ядра [hiddify/hiddify-sing-box](https://github.com/hiddify/hiddify-sing-box) обновляется не сразу за upstream — есть открытые requests на 1.10.7 и 1.11.15 ([hiddify-core#96](https://github.com/hiddify/hiddify-core/issues/96), [hiddify-core#113](https://github.com/hiddify/hiddify-core/issues/113)). Практический вывод: если оператор использует Hiddify, на сервере не делать конфигурации с фичами новее версии ядра в клиенте.

4. **fakeip — частый источник граблей.** В 1.12 специально сломали ситуацию «fakeip как дефолтный DNS-сервер для всего трафика», т.к. это считается некорректным паттерном. После 1.14 fakeip как тип сервера исчезнет совсем — рисёрч-вывод: на новых конфигах **не закладываться на fakeip**, выбирать альтернативы.

5. **DNS reject на Windows ведёт себя странно** ([issue #4122](https://github.com/SagerNet/sing-box/issues)) — рассинхрон с системным DNS-кэшем.

6. **TLS-обрывы при padding-extension ClientHello** ([issue #4141](https://github.com/SagerNet/sing-box/issues)) — конкретный сценарий: некоторые OpenSSL-клиенты с padding-extension могут попадать в обрывы.

7. **Rule-set кэш не инвалидируется при смене формата** ([issue #4136](https://github.com/SagerNet/sing-box/issues)) — после перехода source↔binary нужно вручную чистить `cache.db`.

8. **SFI (iOS) ≠ SFM (macOS).** Тот же конфиг может работать на SFM и падать на SFI ([issue #3695](https://github.com/SagerNet/sing-box/issues/3695)). Особенно с NaiveProxy outbound. Также — общая проблема с App Store account, доступность IPA нестабильна ([issue #2063](https://github.com/SagerNet/sing-box/issues/2063), [issue #849](https://github.com/SagerNet/sing-box/issues/849)).

9. **Build tags по умолчанию.** Если собирать sing-box руками — без `with_naive_outbound` не будет NaiveProxy outbound. Bin-сборки с GitHub releases собираются с дефолтным набором (см. §8.1 ниже). Источник: [installation/build-from-source/](https://sing-box.sagernet.org/installation/build-from-source/).

### 9.1. Build tags

- **Включены по умолчанию:** `with_quic`, `with_dhcp`, `with_wireguard`, `with_utls`, `with_acme`, `with_clash_api`, `with_gvisor`, `with_tailscale`, `with_cloudflared`, `badlinkname`, `tfogo_checklinkname0`.
- **Opt-in:** `with_grpc`, `with_v2ray_api`, `with_embedded_tor` (CGO), `with_ccm`, `with_ocm`, `with_naive_outbound`.

Документация предупреждает: «It is not recommended to change the default build tag list unless you really know what you are adding».

---

## Сводный список источников

### Документация sing-box
- [Главная: sing-box.sagernet.org](https://sing-box.sagernet.org/)
- [Configuration root](https://sing-box.sagernet.org/configuration/)
- [Migration guide](https://sing-box.sagernet.org/migration/)
- [Changelog](https://sing-box.sagernet.org/changelog/)
- [Log](https://sing-box.sagernet.org/configuration/log/)
- [DNS root](https://sing-box.sagernet.org/configuration/dns/), [DNS server](https://sing-box.sagernet.org/configuration/dns/server/), [DNS rule](https://sing-box.sagernet.org/configuration/dns/rule/), [FakeIP](https://sing-box.sagernet.org/configuration/dns/fakeip/)
- [NTP](https://sing-box.sagernet.org/configuration/ntp/)
- [Inbound root](https://sing-box.sagernet.org/configuration/inbound/) — VLESS, AnyTLS, Hysteria2, TUIC, TUN
- [Outbound root](https://sing-box.sagernet.org/configuration/outbound/) — WireGuard, Selector, URLTest
- [Endpoint](https://sing-box.sagernet.org/configuration/endpoint/)
- [Route](https://sing-box.sagernet.org/configuration/route/), [Route rule](https://sing-box.sagernet.org/configuration/route/rule/), [Rule action](https://sing-box.sagernet.org/configuration/route/rule_action/), [Sniff](https://sing-box.sagernet.org/configuration/route/sniff/)
- [Rule-set](https://sing-box.sagernet.org/configuration/rule-set/)
- [Experimental](https://sing-box.sagernet.org/configuration/experimental/), [Cache file](https://sing-box.sagernet.org/configuration/experimental/cache-file/), [Clash API](https://sing-box.sagernet.org/configuration/experimental/clash-api/)
- [Shared TLS](https://sing-box.sagernet.org/configuration/shared/tls/)
- [Installation: package manager](https://sing-box.sagernet.org/installation/package-manager/), [build from source](https://sing-box.sagernet.org/installation/build-from-source/)

### GitHub
- [SagerNet/sing-box](https://github.com/SagerNet/sing-box)
- [Releases](https://github.com/SagerNet/sing-box/releases) — [v1.10.0](https://github.com/SagerNet/sing-box/releases/tag/v1.10.0), [v1.11.0](https://github.com/SagerNet/sing-box/releases/tag/v1.11.0), [v1.12.0](https://github.com/SagerNet/sing-box/releases/tag/v1.12.0), [v1.13.12](https://github.com/SagerNet/sing-box/releases/tag/v1.13.12)
- [Issues](https://github.com/SagerNet/sing-box/issues): [#3472 block migration](https://github.com/SagerNet/sing-box/issues/3472), [#3432 deprecated warnings UX](https://github.com/SagerNet/sing-box/issues/3432), [#2256 routing migration](https://github.com/SagerNet/sing-box/issues/2256), [#849 SFI connection](https://github.com/SagerNet/sing-box/issues/849), [#3695 NaiveProxy SFI vs SFM](https://github.com/SagerNet/sing-box/issues/3695), [#2063 IPA для SFI](https://github.com/SagerNet/sing-box/issues/2063)
- [SagerNet/sing-geoip](https://github.com/SagerNet/sing-geoip), [SagerNet/sing-geosite](https://github.com/SagerNet/sing-geosite)
- [hiddify/hiddify-sing-box](https://github.com/hiddify/hiddify-sing-box), [hiddify-core#96](https://github.com/hiddify/hiddify-core/issues/96), [hiddify-core#113](https://github.com/hiddify/hiddify-core/issues/113)

### Прочее
- [Feature Evolution and Changelog (DeepWiki)](https://deepwiki.com/SagerNet/sing-box/3.4-configuration-evolution) — third-party обзор

---

## Что осталось непроверенным

1. **Точные URL для готовых `.srs`** в репах sing-geoip/sing-geosite — упомянул паттерн, но не открыл ветку `rule-set` и не зафиксировал конкретные имена файлов. Перед использованием в конфиге — проверить на месте.
2. **Полный список Clash API эндпоинтов**, которые sing-box реализует. Известно, что selector и mode работают; точная матрица «фича Clash → поддержка sing-box» в официальной доке отсутствует.
3. **V2Ray API: полный набор полей конфига** в `experimental.v2ray_api`. Уверен только в назначении (stats per-outbound).
4. **TUIC: какая именно версия протокола** поддерживается (v5?). В документации [tuic/](https://sing-box.sagernet.org/configuration/inbound/tuic/) явная версия не указана.
5. **Конкретный паттерн замены fakeip после 1.14** — миграция упоминает `domain_resolver` и cache_file, но цельный пример «как было — как стало» я не зафиксировал.
6. **Версия первого релиза v1.0.0 — точная дата.** Сказал «апрель 2023» как «средний уровень доверия», не верифицировал по конкретному тегу.
7. **AnyTLS-протокол: технические детали маскировки.** Что именно «mitigates TLS proxy traffic characteristics» — в публичной доке без объяснений.
8. **1.13.0 changelog целиком** — открыл только rule-action-страницу, полный release notes не парсил.
9. **`bypass` action: точные сценарии и ограничения** (помимо «только Linux + auto_redirect»).
10. **Дашборды Clash API сверх Yacd-meta** — список совместимых (metacubexd, zashboard) — community-знание, в официальной доке не закреплено.
