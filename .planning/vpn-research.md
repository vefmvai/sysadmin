# VPN/3X-UI: глубокое исследование для агента-сисадмина

**Дата сбора:** 2026-05-15
**Источники проверены вручную:** да (каждый ключевой факт сверен с первичным источником или ≥2 независимыми вторичными)
**Уровень доверия:**
- **Высокий** — для фактов из официальной документации XTLS/Xray-core, исходного кода `MHSanaei/3x-ui` и issue-трекеров.
- **Средний** — для дат блокировок в РФ (вторичные источники: Habr, Medium, профильные блоги; первичных академических работ по 2025-2026 крайне мало в открытом доступе).
- **Низкий / непроверено** — там, где есть только один источник, явно помечено `[непроверено]`.

> Этот файл — материал для написания скиллов агента-сисадмина. **Команды установки и
> конфиги в скиллы должны браться ТОЛЬКО из первичных источников (ссылки ниже),
> а не из этого исследования.** Здесь — карта местности, а не дорожные знаки.

---

## Блок 1. VPN-протоколы — техническая правда

### 1.1 OpenVPN

| Параметр | Значение |
|---|---|
| Год создания | 2001 |
| Статус разработки | Активно поддерживается (OpenVPN Inc.) |
| Статус в РФ-2026 | Заблокирован TSPU (Высокий уровень детекции) |

**Как детектируется DPI:**
- Уникальный fingerprint TLS handshake клиента: OpenVPN использует собственную реализацию TLS, чьи параметры (cipher suites, расширения, порядок) не совпадают с браузерными. Это даёт уникальные JA3/JA3S отпечатки [1].
- OpenVPN имеет уникальные **P-ACK пакеты** одинакового размера на этапе handshake — это сильный fingerprint-признак [1] [2].
- Академическая работа USENIX Security 2022 «OpenVPN is Open to VPN Fingerprinting» (Xue et al.) подтверждает: даже OpenVPN over TLS на порту 443 детектируется по внешнему handshake [2].

**Порты:** UDP 1194 (по умолчанию), часто переносят на TCP 443 — это не помогает против DPI.

**Хронология блокировок в РФ:**
- 2023 — Роскомнадзор начал блокировать OpenVPN на TSPU [3] [4].
- 2024 — массовая блокировка («100% within 30 seconds of connecting») [5].

**Кто использует:** корпоративный сегмент (с обфускацией tls-crypt, stunnel) — там, где гибкость и совместимость важнее DPI-стойкости.

---

### 1.2 WireGuard

| Параметр | Значение |
|---|---|
| Год создания | 2016 |
| Статус разработки | Активно поддерживается (Jason A. Donenfeld) |
| Статус в РФ-2026 | Полностью заблокирован TSPU |

**Как детектируется DPI:**
- WireGuard имеет жёстко фиксированный **148-байтный handshake initial packet** — это очень сильный сигнатурный признак [4] [6].
- Это UDP-протокол без обфускации; TSPU блокирует «неопознанный UDP» начиная с 2025 [6].

**Хронология блокировок в РФ:**
- Середина 2024 — массовая деградация WG-туннелей по ISP [4] [7].
- Лето 2025 — почти полная блокировка неопознанного UDP-трафика [6].
- 2024 (за год) — Роскомнадзор закрыл доступ к 197 VPN-сервисам [3].
- Январь-апрель 2025 — ограничено 12,600 материалов о VPN (в 2 раза больше, чем за весь 2024) [3].

**Альтернатива в виде AmneziaWG (AWG):** форк WG-Go от команды Amnezia. AWG 1.x заменял фиксированные заголовки случайными статическими значениями; AWG 2.0 (2025) использует «mimicry» — постоянно меняющиеся заголовки и размеры пакетов. По данным [6], AWG 2.0 держится там, где stock WireGuard «мёртв с середины 2025».

---

### 1.3 Shadowsocks

| Параметр | Значение |
|---|---|
| Год создания | 2012 (clowwindy) |
| Варианты | Original (RC4/AEAD), Shadowsocks-2022 (новый протокол) |
| Статус в РФ-2026 | Заблокирован (включая обфускацию) |

**Как детектируется:**
- «Полностью зашифрованный» трафик без TLS-обёртки сам по себе подозрителен — это уже сигнатура [8] (net4people/bbs issue #363, академически документированная блокировка fully encrypted protocols).
- Характерный паттерн: короткие control-пакеты + большие data-пакеты, ML-модели определяют с точностью 80-95% [5].

**Хронология:**
- Pre-2024 — оригинальный SS блокировался, обфускация (simple-obfs, v2ray-plugin) обходила.
- Сентябрь 2024 — обновлённые сигнатуры TSPU начали детектить обфусцированный SS в течение часов [9] [5].
- 2025 — заблокирован [9].

**Shadowsocks-2022:** новый AEAD-2022 с лучшей криптографией, но Russia/GFW не различает варианты — блокирует весь fingerprint целиком.

---

### 1.4 VMess

| Параметр | Значение |
|---|---|
| Год создания | 2015 (V2Ray) |
| Статус | Legacy — официально вытеснен VLESS |

**Технические недостатки против VLESS:**
- Использует двойное шифрование (VMess + TLS) → лишняя нагрузка на CPU [10].
- Зависит от системного времени (часы клиента и сервера должны быть синхронизированы) [10].
- В Xray-core 2024+ есть discussion #5568: «VLESS without flow deprecated» [не путать с VMess, но показывает тенденцию миграции к VLESS+flow] [11].

**Статус в РФ:**
- Заблокирован, по данным [5] — сентябрь 2025 (детекция ~80%).

**Вывод первоисточников:** «if you are setting up a new proxy connection in 2026, always choose VLESS over VMess. There is no scenario where VMess is the better option.» [10] [только медиа — `[непроверено]` как абсолютное утверждение, но согласуется с тенденцией кода Xray].

---

### 1.5 Trojan

| Параметр | Значение |
|---|---|
| Год создания | 2019 |
| Принцип | Маскировка под HTTPS: если приходит верный пароль — проксирование; иначе — fallback на реальный веб-сервер |

**Как детектируется:**
- **Active probing**: цензор подключается к подозрительному серверу с заведомо некорректным TLS-handshake и анализирует реакцию. Trojan-сервер отвечает характерным образом, что даёт детекцию ~90% [5].
- Академическая работа: «TrojanProbe: Fingerprinting Trojan tunnel implementations by actively probing crafted HTTP requests» (ScienceDirect, 2024) [12].

**Статус в РФ:**
- Август 2025 — массовое active probing [5].
- Сейчас ненадёжен.

---

### 1.6 VLESS + Reality

**VLESS** — облегчённый протокол V2Ray/Xray:
- Без собственного шифрования (всё на TLS) [10] [13].
- UUID-based аутентификация без metadata-overhead.
- Поддерживает `flow` — например, `xtls-rprx-vision` для XTLS Vision splice-режима [13].

**Reality** — отдельный TLS-replacement от XTLS:
- Это **форк пакета `crypto/tls` из Go 1.19.5** [14] (официальный README XTLS/REALITY).
- При TLS handshake клиент запрашивает Server Hello от **реального стороннего сайта** (через сам сервер Reality в качестве «зеркала»). Реальный TLS-сертификат настоящего сайта попадает клиенту, но клиент не использует его для шифрования — а использует pre-shared ключ (X25519) [14].
- Цензор, выполняющий active probing, получит реальный сертификат настоящего сайта → не сможет идентифицировать прокси-сервер.
- Использует TLS 1.3.

**Требования к dest/serverNames (из официальной документации REALITY [14] [15]):**
- Целевой сайт должен поддерживать TLS 1.3 и HTTP/2.
- Не должен быть редирект-only (главный домен может редиректить на `www` — это нормально).
- Бонусы: encrypted handshake messages после Server Hello (пример: `dl.google.com`), OCSP Stapling, географическая близость IP к серверу прокси, целевой IP — не используется массово другими Reality-серверами.
- Не должен находиться внутри подсанкционного периметра РФ (для российского сегмента — внешний домен).

**Конфигурация-бонусы:**
- Блокировать proxy-трафик обратно в РФ.
- Форвардить TCP/80 и UDP/443 на target — Reality выглядит как простой port-forward для наблюдателя [14].

**Статус в РФ-2026:**
- Работает (на момент данных [5], [16] — пока массовых блокировок Reality в РФ не задокументировано).
- В Иране были попытки блокировки Reality (active probing с подозрительными SNI) [Discussion #3318 на XTLS/Xray-core] [17] — это эталон того, как блокировка может прийти и в РФ.

**Уязвимости при неправильной настройке (см. Блок 6).**

---

### 1.7 Hysteria 2 / TUIC

**Hysteria 2** (на QUIC over UDP):
- Шифрует через TLS с настоящими сертификатами.
- Имеет режим обфускации **Salamander** — оборачивает QUIC-пакеты в случайные UDP-байты, чтобы убрать QUIC-fingerprint [18] [19].
- Использует BBR/Brutal congestion control — выше throughput на нестабильных каналах [18].

**TUIC** (TLS-over-UDP via QUIC) — близкая концепция, активный проект.

**Статус в РФ-2026:**
- РФ блокирует UDP/443 неопознанного трафика и HTTP/3 на нескольких ASN [20] (net4people/bbs issue #108, kelmenhorst/quic-censorship issue #4).
- Hysteria без Salamander блокируется. С Salamander — частично работает [18] [19].
- По данным [19]: «mostly available in Russia», но «может быть заблокирован вместе с другим неопознанным трафиком».

**Вывод:** QUIC-протоколы в РФ-2026 — менее надёжны, чем VLESS+Reality. Это `средний уровень доверия` — публикация одна (Habr) + комьюнити-блог.

---

### 1.8 Сводная таблица протоколов (РФ-2026)

| Протокол | Статус в РФ | Защита от DPI | Скорость | Источники |
|---|---|---|---|---|
| OpenVPN | Заблокирован | Слабая (fingerprint TLS+P-ACK) | Средняя | [1][2][3] |
| WireGuard (stock) | Заблокирован | Очень слабая (148b handshake) | Очень высокая | [4][6][7] |
| AmneziaWG 2.0 | Частично работает | Mimicry заголовков | Очень высокая | [6] |
| Shadowsocks | Заблокирован | Слабая (ML на паттерны) | Средняя | [5][8][9] |
| VMess | Заблокирован | Слабая | Средняя (двойное шифрование) | [5][10] |
| Trojan | Ненадёжен (active probing) | Средняя (HTTPS fallback) | Высокая | [5][12] |
| VLESS+Reality | Работает | Сильная (mimicry TLS handshake реального сайта) | Высокая | [5][14][16] |
| Hysteria 2 (Salamander) | Частично работает | Средняя | Высокая (QUIC/BBR) | [18][19][20] |

---

## Блок 2. 3X-UI — техническая правда

### 2.1 Установка

**Официальный одностроковый установщик** ([21], README MHSanaei/3x-ui):
- URL: `https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh`
- Запуск через `bash <(curl -Ls ...)` — актуально по состоянию на 2026-05.
- Можно зафиксировать версию через переменную `VERSION`:
  `VERSION=v2.5.5 && bash <(curl -Ls "https://raw.githubusercontent.com/mhsanaei/3x-ui/$VERSION/install.sh") $VERSION`

**Поддерживаемые ОС** (из `install.sh` [22]):
- Ubuntu, Debian, Armbian
- CentOS 7+ (использует `yum` для 7, `dnf` для 8+)
- Fedora, RHEL, AlmaLinux, Rocky Linux, Oracle Linux
- Arch, Manjaro, Parch
- openSUSE Tumbleweed/Leap
- Alpine Linux (использует OpenRC вместо systemd)

**Архитектуры:** amd64, 386, arm64, armv7, armv6, armv5, s390x [22].

**Требование:** root (`[[ $EUID -ne 0 ]] && exit 1`) [22].

### 2.2 Поведение установщика при первой инсталляции

Из кода `install.sh` [22]:
- Генерация случайных учётных данных:
  ```
  config_username=$(gen_random_string 10)
  config_password=$(gen_random_string 10)
  config_port=$(shuf -i 1024-62000 -n 1)
  ```
- Скрипт **интерактивно** спрашивает: «Would you like to customize the Panel Port settings?» — то есть **неинтерактивного режима через ENV vars для логин/пароля стандартного установщика нет** (по состоянию на код, исследованный в мае 2026).
- Переменные окружения, влияющие на установку:
  - `XUI_MAIN_FOLDER` — директория установки (по умолчанию `/usr/local/x-ui`)
  - `XUI_SERVICE` — путь для systemd (по умолчанию `/etc/systemd/system`)
- Установщик может принимать **аргумент с версией**: `bash install.sh v2.5.5`

**Docker-образ** имеет жёсткие дефолтные креды [23] (wiki Installation): `admin/admin` + порт `2053`.

### 2.3 Расположение файлов

Из `config/config.go` [24]:
- **SQLite база (Linux):** `/etc/x-ui/x-ui.db` (стандартный путь, формируется как `{DBFolder}/{AppName}.db`).
- Переменные окружения для путей:
  - `XUI_DB_FOLDER` (Linux default: `/etc/x-ui`)
  - `XUI_LOG_FOLDER` (Linux default: `/var/log/x-ui`)
  - `XUI_BIN_FOLDER` (default: `bin`)
  - `XUI_DEBUG=true` — режим отладки
  - `XUI_LOG_LEVEL` — debug/info/notice/warning/error
- **systemd-юнит:** `/etc/systemd/system/x-ui.service` [22].
- **Бинарник CLI:** `/usr/local/x-ui/x-ui` [22] (плюс скрипт-обёртка `x-ui.sh`).

> ⚠️ Источники типа [23] упоминают `/usr/local/x-ui/x-ui.db` (как «по умолчанию» при установке) — это противоречит коду `config.go`. **Проверять на свежей установке.** Возможно, исторически путь менялся (миграция с x-ui на 3x-ui), либо различие между разными типами установки (host vs docker).

### 2.4 CLI команды панели

Из `x-ui.sh` [25]:
- `x-ui start` / `stop` / `restart` / `status`
- `x-ui enable` / `disable` — автозагрузка
- `x-ui setting` — управление настройками (см. ниже)
- `x-ui log` — просмотр логов
- `x-ui update` — обновление панели
- `x-ui install` / `uninstall`

**Параметры `x-ui setting`** (из [25]):
- `-username "..."` — изменить логин
- `-password "..."` — изменить пароль
- `-port N` — изменить порт панели
- `-webBasePath "..."` — путь панели (например `/abc123/`)
- `-reset` — сброс настроек
- `-show true` — показать текущие значения
- `-getCert true` — получить путь до сертификата
- `-resetTwoFactor true/false` — сброс 2FA

**Команда `migrate` в коде `x-ui.sh` не обнаружена** [25] — миграции БД, по-видимому, выполняются автоматически при запуске бинарника.

### 2.5 REST API

API живёт под `/panel/api/inbounds/...`, защищён middleware `checkAPIAuth` (из исходного кода `InboundController` [26]).

**Аутентификация** ([26], [27] — community SDK):
- Логин через POST на `/login` с form-data (username/password).
- Возвращает cookie сессии. Cookie передаётся в последующих запросах.
- При истечении сессии — повторный login.

**Основные операции** (из community-документации Postman [26] и SDK [27]):
- `getInbounds()` — получить все inbound
- `getInbound(id)` — конкретный
- `addInbound(config)`
- `updateInbound(id, config)`
- `deleteInbound(id)`
- `addClient()`, `updateClient()`, `deleteClient()`
- `getClientTrafficsByEmail()`, `getClientTrafficsById()`
- `getClientIps()`, `clearClientIps()`
- `resetClientTraffic()`, `resetAllTraffics()`, `resetAllClientTraffics()`
- `deleteDepletedClients()`
- `getOnlineClients()`, `createBackup()`, `backupToTgBot()`, `getServerStatus()`

**Особенности**:
- В версии **3.0.1** в панель добавлена встроенная страница документации API [28].
- Полный список URL-путей публично доступен через Postman Public Workspace [26]: https://www.postman.com/hsanaei/3x-ui

### 2.6 TLS-выпуск

Из wiki Configuration [29] и DeepWiki [30]:
- Встроенная интеграция с **acme.sh**.
- Три типа сертификатов через панель:
  1. **Domain Cert** — 90 дней, Let's Encrypt.
  2. **IP Cert** — 6 дней, Let's Encrypt shortlived profile (для cертификатов на IP).
  3. **Custom Cert** — пользовательский путь.
- Для domain-cert через acme: используется **standalone HTTP-01** (требует освобождения порта 80; скрипт временно останавливает панель).
- Альтернативно: **Cloudflare DNS-01** (через email + Global API Key) — встроенная опция в `x-ui.sh`.
- Сертификаты по умолчанию: `/root/cert/{domain}/`.

> На вопрос «есть ли DNS-01 standalone (без Cloudflare)?» — в найденных источниках упоминается **только Cloudflare** как встроенный DNS-провайдер. Прочие DNS-провайдеры (Yandex DNS, AWS Route53) — `[непроверено]`, нужно смотреть код `x-ui.sh` под текущей версией.

### 2.7 Известные подводные камни (issue tracker MHSanaei/3x-ui)

Из обзора issues и wiki [31] [32]:

1. **#4390 `ssl_cert_issue_main infinite-loops on closed stdin`** — bug в `x-ui.sh`, попадание в бесконечный цикл при автоматизированном запуске cert-issue с закрытым stdin → `systemctl restart storm`. Опасность: при автоматизации через cron/Ansible.

2. **#4406 `3x-ui fails to parse and import VLESS + XHTTP outbound configs correctly`** — баг парсера XHTTP конфигов.

3. **#4409 `Cannot login after manual install on Ubuntu`** — issue про логин после ручной установки.

4. **Database locking errors** (документ Common Questions) — sqlite database lock при нагрузке.

5. **#3669, #3651** — проблемы с reverse-proxy и nginx proxy manager в Docker.

6. **CPU/Disk overload** (общие issues) — высокое потребление ресурсов при росте числа клиентов.

**Самонаезд на `http_proxy`:** в issue tracker **не нашлось специфической документированной проблемы** «панель ловит свои же `http_proxy` из `/etc/environment`». Найдено [33]: SDK 3X-UI поддерживает `HTTP_PROXY/HTTPS_PROXY` для подключения К панели (как клиент), что не то же самое. **Это требует уточнения у Василия** — либо это его эмпирическое наблюдение, либо отдельный bug, который пока не описан публично.

### 2.8 Telegram-бот (опционально)

Из wiki Advanced [34] [35]:
- Создаётся через BotFather, токен и chat ID вводятся в панель.
- Уведомления: daily traffic, panel login, database backup, system status, client info.
- Резервная копия БД отправляется в Telegram по API эндпоинту `/panel/api/backuptotgbot`.
- Расписание уведомлений через cron syntax внутри панели.

---

## Блок 3. Реальность блокировок в РФ 2025-2026

### 3.1 ТСПУ (Технические средства противодействия угрозам)

- ТСПУ — **DPI-боксы, физически установленные на оборудовании каждого крупного провайдера РФ**. Управляются Роскомнадзором [3] [4] [6].
- Бюджет 2025-2027 (Минфин): **60 млрд рублей (~600 млн USD) на «суверенность сети»** — целевое финансирование ТСПУ [4].
- Возможности (документированные публично):
  - Fingerprint-based detection протоколов (OpenVPN, WireGuard, IKEv2, Shadowsocks) [3] [4].
  - ML-классификация по паттернам packet timing / packet size distribution [5].
  - Active probing (подключение к подозрительным IP) [5].
  - TLS-level disruption (срыв соединения на TLS handshake) [3].
  - С июня 2025 — throttling foreign CDN: после ~15-20 KB полученных данных TCP-пакеты с сервера прекращаются [36] (Hetzner, DigitalOcean, OVH, Cloudflare).

### 3.2 «Белый список» Минцифры (с 5 сентября 2025)

- **Реальная дата старта:** 5 сентября 2025 (Минфин, не Минцифры) — первая версия списка [37] [38].
- **Расширенная версия:** 14 ноября 2025 [37].
- **Изначальный состав:** 57 сайтов «социально значимых сервисов» [38]:
  - РИА Новости
  - Госуслуги
  - VK, OK, Mail.ru
  - Mессенджер Max (государственный)
  - Yandex-сервисы
  - Ozon, Wildberries, Avito
  - Крупные банки и телеком-операторы
- **Когда применяется:** при отключении мобильного интернета («дни тишины»). В среднем 2,000 отключений в месяц с мая 2025 — больше, чем во всём остальном мире за 2024 [37] [38].

**О слухе про 75,000 IP:** в найденных источниках 2025-2026 ([37], [38], [39]) **подтверждения числа в ~75,000 IP не найдено**. Это `[непроверено]` — возможно, путаница с другим списком (например, список Минцифры по доступности при отключении мобильного интернета — это другая инициатива).

### 3.3 Что точно блокируется (РФ-2026)

| Что | Статус | Источник |
|---|---|---|
| Anthropic, OpenAI, Gemini | Блокируются с **их стороны** для IP из РФ (ToS, не DPI) | [40] [41] |
| Anthropic ToS update | Сентябрь 2025 — официальный бан China/Russia/Iran | [40] |
| Hetzner ASN (AS24940, 178.63.0.0/16) | Throttled с июня 2025 (16-KB curtain) | [36] [42] |
| DigitalOcean (46.101.128.0/17) | Throttled | [36] |
| OVH | Throttled | [36] |
| Cloudflare | Throttled (16-KB curtain) | [36] [43] |
| OpenVPN, WireGuard | DPI block через TSPU | [3] [4] |
| Shadowsocks, Trojan | DPI block + active probing | [5] [9] |
| Tor (включая bridges meek/obfs4) | Заблокирован | [3] |

### 3.4 Что работает

- **VLESS + Reality** — работает на момент мая 2026 [5] [16].
- **AmneziaWG 2.0** — работает [6].
- **Hysteria 2 с Salamander** — частично работает [19].
- **Российские VPS-провайдеры в РФ-сегменте** — конечно работают, но: VPS в РФ полезен только как «вторая нога» в multi-hop (см. Блок 4), потому что Anthropic/OpenAI блокируют сами по IP-геолокации [40] [41].

---

## Блок 4. Архитектура multi-hop

### 4.1 Идея и зачем

Сценарий: оператор сидит в РФ → нужен Claude API. Anthropic блокирует РФ-IP. Hetzner-IP блокирован через throttling из РФ. Решение — multi-hop:

```
Клиент (РФ) → VLESS+Reality → VPS₁ (РФ-friendly страна с белым ASN, e.g. Германия мелкий провайдер)
                                ↓ outbound VLESS
                              VPS₂ (страна без блокировок Anthropic, e.g. Финляндия)
                                ↓ outbound freedom
                              Anthropic API
```

Из community discussions Xray-core [44] [45] (#4645, #5607):
- Типовая схема: `User → Local VPS → Foreign VPS`
- Транспорт между двумя VPS: чаще всего VLESS (без Reality между ними, если они напрямую доверяют друг другу — например, по mTLS или просто по UUID и стандартному TLS на доверенном домене).

### 4.2 Конфигурация Xray для multi-hop outbound

**Минимальный VLESS outbound** (из официальной документации XTLS [13]):

Обязательные поля:
- `address` — IP или домен второго VPS
- `port` — порт второго VPS
- `id` — UUID или строка <30 байт
- `encryption: "none"` (обязательное явное поле для VLESS)
- `flow` — опционально (`xtls-rprx-vision` если transport TLS)

Структура multi-hop:
```json
{
  "outbounds": [
    { "tag": "to_vps2", "protocol": "vless", "settings": {...} },
    { "tag": "direct",  "protocol": "freedom" }
  ],
  "routing": {
    "rules": [
      { "inboundTag": ["client_in"], "outboundTag": "to_vps2" }
    ]
  }
}
```

Конкретный валидный JSON-конфиг — брать из официальных примеров [13], не из этого документа.

**Как 3X-UI настраивает outbound через UI** (по [26] и community):
- В UI есть раздел Outbound (отдельно от Inbound).
- Те же поля, что в JSON: address, port, id, flow, encryption, security.
- При сохранении 3X-UI генерирует JSON в `/etc/x-ui/x-ui.db` и обновляет конфиг Xray (запись в SQLite + рестарт xray-процесса).

### 4.3 Routing: geoip и geosite

Из официальной документации Xray Routing [46]:

- **`geoip:ru`** — встроенный список IP-диапазонов РФ из файла `geoip.dat` (поставляется с Xray-core).
- **`geosite:category-ru`** — встроенный список российских доменов из `geosite.dat`.
- Оба файла лежат рядом с бинарником Xray и обновляются (вручную) при обновлении пакета Xray или через автоматизированные скрипты.
- Источники-генераторы: проекты `v2fly/domain-list-community`, `Loyalsoldier/v2ray-rules-dat`, `chocolate4u/Iran-v2ray-rules` и аналогичные.

**Типовое правило «РФ-трафик — direct»:**
```json
{
  "type": "field",
  "outboundTag": "direct",
  "domain": ["geosite:category-ru", "regexp:.*\\.ru$"],
  "ip": ["geoip:ru"]
}
```

### 4.4 Balancers

Из официальной документации Xray Routing [46]:

- `balancers[]` в `routing` — массив балансировщиков.
- Поля:
  - `tag` — имя для ссылки из rules.
  - `selector` — массив prefix-match для тегов outbound (например, `["proxy"]` отбирает `proxy1`, `proxy2`).
  - `fallbackTag` — резервный outbound при недоступности всех.
  - `strategy.type` — `"random"`, `"roundRobin"`, `"leastPing"`, `"leastLoad"`.

**`leastLoad` стратегия:** требует обязательно работающего `observatory` (модуль мониторинга outbound health) [46].

**`pingConfig`** — `[непроверено]`: в найденной официальной документации Xray поле `pingConfig` напрямую не упоминается. Возможно, имелся в виду `observatory.probeInterval` или `observatory.probeURL` (см. [46]).

---

## Блок 5. Серверный прокси (mixed inbound)

### 5.1 «Mixed» — это реально?

**Главная техническая правда:**
- В **официальной документации Xray-core** [47] [48] **нет отдельного протокола `mixed`**. Список inbound: `dokodemo-door`, `http`, `shadowsocks`, `socks`, `vless`, `vmess`, `trojan`, `wireguard`, `hysteria`.
- **Однако:** SOCKS inbound в Xray поддерживает **одновременно SOCKS 4/4a/5 и HTTP** на одном порту (см. PR #3682 Fangliding, PR #4297 rPDmYQ [49] [50]). Если задана аутентификация по паролю, HTTP-запросы требуют те же креды.
- В **3X-UI UI** есть пункт «Mixed» как тип inbound [51] [52] — это **обёртка вокруг `socks` inbound в Xray** с включённой HTTP-совместимостью. То есть «Mixed» — это терминология панели 3X-UI, а не отдельный протокол Xray.

**Поля SOCKS inbound** (из [47]):
- `auth`: `"noauth"` (по умолчанию) или `"password"`.
- `accounts`: массив `{user, pass}` при `password`.
- `udp`: `true/false` — включение UDP relay.
- `ip`: локальный IP сервера (нужен при UDP, если за NAT).

> Важное предупреждение из документации [47]: «The Socks protocol does not encrypt transmission and is not suitable for transmission over the public internet.» Поэтому SOCKS/Mixed inbound должен слушать на **127.0.0.1** или внутри VPN-туннеля, а наружу торчать только VLESS+Reality.

### 5.2 socks5h vs socks5

Из документации urllib3/requests/httpx [53] [54] [55]:

- **`socks5://`** — DNS-резолвинг **на клиенте**, к проксе уходит уже IP. → возможен DNS-leak в локальный resolver.
- **`socks5h://`** — DNS-резолвинг **на прокси-сервере** (буква `h` = «hostname»). → никакого DNS-leak.

**Поддержка по библиотекам:**

| Библиотека | Читает `HTTPS_PROXY` автоматически? | Поддерживает `socks5h://`? | Источник |
|---|---|---|---|
| `requests` | Да (по умолчанию) — `http_proxy`, `https_proxy`, `no_proxy`, `all_proxy` (lowercase и uppercase) | Да | [53] [54] |
| `urllib3` | Да | Да (через PySocks) | [53] |
| `httpx` | Да, контролируется параметром `trust_env` (по умолчанию `True`); читает `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, `NO_PROXY` | Да | [55] |
| `aiohttp` | **Нет по умолчанию** — нужно явно `aiohttp.ClientSession(trust_env=True)`. Если включить — читает `HTTP_PROXY` и `HTTPS_PROXY` | Да (через aiohttp-socks или встроенно с TLS-in-TLS в 3.8+) | [56] [57] |
| `openai` Python SDK | Через httpx-клиент, по умолчанию переменные читаются. Но в свежих версиях SDK конфигурируется через `DefaultHttpxClient` или `proxies=` параметр; есть зарегистрированные баги с `openai.proxies` после v1 | Через нижний httpx — да | [58] [59] |
| `anthropic` Python SDK | **Известный баг (issue #923 на anthropic-sdk-python):** на версиях `anthropic==0.49.0` + `httpx==0.27.0` SDK создаёт кастомный transport, который **не читает** переменные `http_proxy`/`https_proxy`. Обход — явный `proxies=` параметр клиента | Через нижний httpx — да | [60] |
| Claude Code (CLI) | Документировано: уважает `HTTPS_PROXY` [61] | — | [61] |

> **Свежий issue на claude-code #11660 [62]:** «`HTTPS_PROXY` is not applied to the Anthropic API POST requests when set in `~/.claude/settings.json`» — то есть **проблема прокси-конфига продолжает существовать**, обходить через переменные окружения шелла (а не через JSON-настройку Claude Code) или явный параметр клиента.

### 5.3 Подводный камень с `/etc/environment`

В найденных публичных issue tracker MHSanaei/3x-ui **не нашлось явного подтверждения** проблемы «панель 3X-UI ловит свои `http_proxy` из `/etc/environment`». Эта гипотеза — **из эмпирического опыта Василия и требует подтверждения**.

**Что точно известно:**
- 3X-UI написан на Go. Go стандартная библиотека `net/http` уважает `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` (через функцию `httpproxy.FromEnvironment`).
- Если в `/etc/environment` или systemd-юните стоит `HTTPS_PROXY=http://127.0.0.1:1080`, **любой Go-процесс** (включая x-ui и xray) при HTTPS-запросах будет пытаться идти через эту проксю.
- Это может приводить к loop'у (xray → http_proxy → xray → ...) или сбоям при обновлении / acme.sh.

**Стандартный обход** (Linux best practice, не специфично для 3X-UI):
- Использовать **systemd drop-in override** для x-ui.service и xray.service:
  ```
  systemctl edit x-ui
  ```
  и добавить:
  ```
  [Service]
  Environment="HTTP_PROXY="
  Environment="HTTPS_PROXY="
  Environment="NO_PROXY=*"
  ```
- Это очищает переменные только для конкретного юнита, не трогая `/etc/environment`.

> Это решение — по best-practice systemd, но **специфической ссылки в issues 3X-UI** на этот паттерн я не нашёл. Если Василий нашёл/решал — стоит зафиксировать в скилле со ссылкой на свой инцидент.

---

## Блок 6. Антипаттерны (что НЕ делать)

### 6.1 Голый WireGuard на зарубежный VPS из РФ

**Факт:** заблокирован TSPU с середины 2024, к 2025 — массово недоступен [4] [6] [7].

**Что бывает после старта:**
- Первые 1-3 минуты соединение работает → ISP-устройство (TSPU) фиксирует 148-байтный handshake → silently drops все последующие UDP-пакеты к этому IP:port.
- Перезапуск туннеля даёт те же 1-3 минуты «жизни», а затем тот же дроп.

**Альтернативы:** AmneziaWG 2.0 [6], VLESS+Reality.

### 6.2 Бесплатные VPN-сервисы

Подтверждённые независимые исследования:
- **CSIRO / ICSI / UC Berkeley / UNSW** (Ikram et al., академическая работа) — 67% бесплатных Android-VPN содержат сторонние tracking-библиотеки, 38% содержат malware/malvertising, 16% инжектят JavaScript [63].
- 88% бесплатных Android-VPN утекают user data (2024) [63].
- 71% бесплатных Android-VPN передают personal user data третьим сторонам [63].

**Вывод:** бесплатный VPN — это не «бесплатно», а «вы платите трафиком и метаданными». Никогда не подключать к OpenAI/Anthropic API через бесплатный VPN (compromise токенов).

### 6.3 Reality с serverName того же домена что у панели

**Уязвимость:**
- Если SNI Reality указывает на тот же домен, что и сама панель 3X-UI (например, оба смотрят на `proxy.example.com`), цензор может:
  1. Заметить, что TLS-handshake идёт к `proxy.example.com`.
  2. Сам подключиться к `proxy.example.com:443` с тем же SNI.
  3. Получить сертификат панели вместо «настоящего» внешнего сайта.
  4. Сличить — несовпадение → пометка как circumvention traffic.

**Источники:** discussion #3318 на XTLS/Xray-core (Iran probing) [17] и общая концепция Reality detection [64].

**Правильно:** `serverNames` в Reality указывают на **независимый внешний домен** (например, `www.microsoft.com`, `dl.google.com`, `www.lovelive-anime.jp` — частые примеры в комьюнити), не имеющий отношения к серверу проксирования.

### 6.4 Хардкод порта 443 без обоснования

**Проблема:**
- Все массовые VPN-конфиги используют 443. Цензор смотрит на 443 пристально.
- TSPU делает targeted DPI на UDP/443 (блокировка QUIC) [20] и пристальный DPI на TCP/443.

**Альтернативы:**
- Reality можно поставить на любой TCP-порт (например, 8443, 10443) — главное, чтобы он был открыт у клиента (мобильные ISP часто разрешают только 80/443).
- Для семейного multi-user 443 проще для клиентов (Reality на 443 + nginx fallback на тот же 443 даёт «универсальную ширму»).
- Чем менее массовый порт — тем меньше внимания от DPI, но и меньше клиентов смогут подключиться (корпоративные firewalls режут всё кроме 80/443).

**Решение мастера:** баланс между «защита от DPI» (нестандартный порт) и «универсальная доступность с любых сетей» (443). Это **архитектурное решение**, а не догма.

---

## Сводный список источников

| № | URL | Что взято |
|---|---|---|
| [1] | https://arxiv.org/html/2403.03998v1 | Академическая работа «OpenVPN is Open to VPN Fingerprinting» — fingerprint TLS, P-ACK |
| [2] | https://www.usenix.org/system/files/sec22-xue-diwen.pdf | USENIX Security 2022 (Xue et al.) — fingerprint OpenVPN |
| [3] | https://rks.global/en/research/vpn-and-human-rights/ | Отчёт РосКомСвободы — даты блокировок, TSPU, бюджет 60 млрд руб |
| [4] | https://torrentfreak.com/russia-blocks-167-vpns-steps-up-openvpn-wireguard-disruption-231031/ | Хронология блокировок OpenVPN/WireGuard |
| [5] | https://habr.com/en/articles/990144/ | Хабр — даты блокировок Trojan, VMess, проценты детекции |
| [6] | https://hub.xeovo.com/posts/27-bypassing-russias-wireguard-block-meet-amneziawg | AmneziaWG, эволюция блокировок WireGuard в РФ |
| [7] | https://news.ycombinator.com/item?id=39067213 | HN-обсуждение блокировок OpenVPN/WireGuard |
| [8] | https://github.com/net4people/bbs/issues/363 | Блокировка fully encrypted protocols (Shadowsocks, VMess) |
| [9] | https://www.hrw.org/report/2025/07/30/disrupted-throttled-and-blocked/state-censorship-control-and-increasing-isolation | HRW отчёт — состояние блокировок 2025 |
| [10] | https://octohide.com/support/blog/What-s-the-Difference-Between-VLESS-Xray-Reality-and-VMess | Сравнение VMess vs VLESS |
| [11] | https://github.com/XTLS/Xray-core/discussions/5568 | Discussion: VLESS without flow deprecated |
| [12] | https://www.sciencedirect.com/science/article/abs/pii/S0167404824004528 | TrojanProbe: academic paper |
| [13] | https://xtls.github.io/en/config/outbounds/vless.html | Официальная документация VLESS outbound |
| [14] | https://github.com/XTLS/REALITY | Официальный README REALITY |
| [15] | https://github.com/XTLS/Xray-examples/blob/main/VLESS-TCP-XTLS-Vision-REALITY/REALITY.ENG.md | Официальный пример VLESS+Reality |
| [16] | https://github.com/XTLS/Xray-core/discussions/3269 | Investigation Reality blocking Iran (relevant как прецедент) |
| [17] | https://github.com/XTLS/Xray-core/discussions/3318 | Weird SNIs Iran Reality (active probing) |
| [18] | https://v2.hysteria.network/docs/developers/Protocol/ | Официальная документация Hysteria 2 |
| [19] | https://ambientnode.uk/bypassing-censorship-in-the-age-of-dpi-a-stealth-tunnel-with-hysteria-2/ | Hysteria 2 в РФ, Salamander |
| [20] | https://github.com/net4people/bbs/issues/108 | HTTP/3 (QUIC) blocking in Russia |
| [21] | https://github.com/MHSanaei/3x-ui | Официальный README 3X-UI |
| [22] | https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh | Исходник install.sh — пути, ENV vars, генерация кредов |
| [23] | https://github.com/MHSanaei/3x-ui/wiki/Installation | Wiki Installation (Docker `admin/admin:2053`) |
| [24] | https://github.com/MHSanaei/3x-ui/blob/main/config/config.go | Исходник config.go — пути `/etc/x-ui`, `/var/log/x-ui` и т.д. |
| [25] | https://github.com/MHSanaei/3x-ui/blob/main/x-ui.sh | Исходник x-ui.sh — все CLI команды |
| [26] | https://www.postman.com/hsanaei/3x-ui/documentation/q1l5l0u/3x-ui | Официальная Postman-документация REST API |
| [27] | https://github.com/iamhelitha/3xui-api-client | Community Node.js SDK — карта API |
| [28] | https://github.com/MHSanaei/3x-ui/releases/tag/v3.0.1 | Release notes v3.0.1 (in-panel API doc) |
| [29] | https://github.com/MHSanaei/3x-ui/wiki/Configuration | Wiki Configuration |
| [30] | https://deepwiki.com/MHSanaei/3x-ui/2.3-ssl-certificate-management | DeepWiki SSL management |
| [31] | https://github.com/MHSanaei/3x-ui/issues | Issues tracker — последние баги |
| [32] | https://github.com/MHSanaei/3x-ui/wiki/Common-questions-and-problems | Wiki Common Questions |
| [33] | https://github.com/MHSanaei/3x-ui/issues/3669 | Issue #3669 — reverse-proxy панели через прокси |
| [34] | https://github.com/MHSanaei/3x-ui/wiki/Advanced | Wiki Advanced (Telegram bot) |
| [35] | https://deepwiki.com/MHSanaei/3x-ui/5.2-telegram-bot-integration | DeepWiki Telegram bot integration |
| [36] | https://blog.cloudflare.com/russian-internet-users-are-unable-to-access-the-open-internet/ | Cloudflare о throttling РФ ISP |
| [37] | https://re-russia.net/en/analytics/0364/ | «Whitelists For Dark Times» — анализ белого списка Минфина |
| [38] | https://globalvoices.org/2025/10/07/inside-net-russia-is-dismantling-free-internet-connections/ | Global Voices — состав белого списка |
| [39] | https://en.zona.media/article/2026/04/07/russian_internet_censorship_2026 | Zona Media отчёт о цензуре 2026 |
| [40] | https://www.medianama.com/2025/09/223-anthropic-service-policy-update-bans-ai-access-chinese-firms/ | Anthropic ToS update сентябрь 2025 |
| [41] | https://help.openai.com/en/articles/5347006-openai-api-supported-countries-and-territories | OpenAI supported countries |
| [42] | https://en.zona.media/article/2025/06/19/cloudflare | «16-KB curtain» throttling в РФ |
| [43] | https://github.com/net4people/bbs/issues/490 | Censor new blocking method (TCP freeze 16KB) |
| [44] | https://github.com/XTLS/Xray-core/discussions/4645 | Multi-hop chains xrays |
| [45] | https://github.com/XTLS/Xray-core/discussions/5607 | Multi-hop transport choice |
| [46] | https://xtls.github.io/en/config/routing.html | Официальная Routing-документация (geoip, geosite, balancers) |
| [47] | https://xtls.github.io/en/config/inbounds/socks.html | Официальная SOCKS inbound (SOCKS4/5+HTTP combined) |
| [48] | https://xtls.github.io/en/config/inbound.html | Список всех inbound протоколов (нет отдельного `mixed`) |
| [49] | https://github.com/XTLS/Xray-core/pull/3682 | PR Fangliding — Socks inbound supports HTTP by default |
| [50] | https://github.com/XTLS/Xray-core/pull/4297 | PR rPDmYQ — Mixed inbound handle closing connection |
| [51] | https://github.com/MHSanaei/3x-ui/blob/main/database/model/model.go | model.go — список типов inbound в 3X-UI (включая Mixed) |
| [52] | https://pkg.go.dev/github.com/mhsanaei/3x-ui/v2/database/model | godoc типы Protocol в 3X-UI |
| [53] | https://urllib3.readthedocs.io/en/stable/reference/contrib/socks.html | urllib3 docs про socks5h |
| [54] | https://docs.python-requests.org/en/latest/user/advanced/ | requests proxy env vars + socks5h |
| [55] | https://www.python-httpx.org/environment_variables/ | httpx ENV vars (`trust_env`) |
| [56] | https://docs.aiohttp.org/en/stable/client_advanced.html | aiohttp `trust_env` поведение |
| [57] | https://github.com/aio-libs/aiohttp/issues/10682 | aiohttp issue: предлагают сделать `trust_env=True` по умолчанию |
| [58] | https://github.com/openai/openai-python/issues/825 | openai-python issue: `openai.proxies` не работает |
| [59] | https://community.openai.com/t/bypassing-proxy-settings-with-openais-python-sdk/1026752 | OpenAI community — как обходить прокси-настройки SDK |
| [60] | https://github.com/anthropics/anthropic-sdk-python/issues/923 | anthropic SDK issue #923 — proxy env vars не применяются |
| [61] | https://docs.anthropic.com/en/docs/claude-code/corporate-proxy | Официальная документация Claude Code про прокси |
| [62] | https://github.com/anthropics/claude-code/issues/11660 | Claude Code issue: HTTPS_PROXY не работает из settings.json |
| [63] | https://thebestvpn.com/how-free-vpns-sell-your-data/ | Свод исследований free VPN (CSIRO, ICSI etc) |
| [64] | https://deepwiki.com/roosterkid/openproxylist/7.1-reality-protocol-and-tls-fingerprinting | Reality TLS fingerprinting detection vectors |
| [65] | https://files.rks.global/vpn-block-report_01.25.pdf | PDF отчёта РосКомСвободы (январь 2025) |

---

## Что осталось непроверенным / требует уточнения от Василия

1. **Слух про ~75,000 IP в белом списке Минцифры** — в найденных источниках 2025-2026 не подтверждён. Возможно, это число из устных пересказов или путаница с другим списком (список «доступного при отключении мобильного интернета»). Если у Василия есть первичная ссылка — добавить в источники.

2. **Самонаезд 3X-UI на свои собственные `http_proxy` через `/etc/environment`** — в публичном issue tracker MHSanaei/3x-ui документация отсутствует. Это эмпирическое наблюдение Василия? Если да — стоит описать в скилле с пометкой «эмпирически, источник — личный опыт».

3. **Точный путь к sqlite в Docker-варианте 3X-UI** — `config.go` указывает `/etc/x-ui/x-ui.db`, но Docker-документация показывает `/etc/x-ui/` как **внутренний путь контейнера, монтируемый из** host-папки. Стандартное host-mount — на усмотрение оператора. **Уточнить, как настроено на сервере Василия.**

4. **`pingConfig` в балансировщике Xray** — в найденной официальной документации [46] этого поля нет. Возможно, имеется в виду `observatory.probeInterval` или это поле было удалено / переименовано в свежих версиях. Если Василий использует `pingConfig` — нужна ссылка на актуальную версию.

5. **DNS-01 без Cloudflare в 3X-UI** — в публичной документации [29] [30] упоминается только Cloudflare-интеграция. Поддерживаются ли другие DNS-провайдеры (например, для российских доменов через российский DNS) — не подтверждено. Возможно, доступно через прямое использование `acme.sh` вне панели.

6. **Конкретные значения throttling Cloudflare в РФ** ([36], [43]) — упоминается «16-KB curtain», но точная конфигурация TSPU (какие IP-диапазоны, какой алгоритм) — публично не задокументирована. Это эмпирические наблюдения исследователей.

7. **Точные даты блокировок Trojan (август 2025) и VMess (сентябрь 2025)** — источник [5] Хабр-статья, единственный найденный с конкретными датами. **Низкий уровень доверия** (один источник, медиа, не академическая работа). В скиллах формулировать как «по сообщениям комьюнити блокировки усилились в этот период», а не как факт.
