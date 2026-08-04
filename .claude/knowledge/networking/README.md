# Networking knowledge — карта домена

Доменная база знаний агента-сисадмина по VPN, обходу блокировок, 3X-UI, клиентам.
Разделена на три слоя с разными TTL — потому что реальность VPN-фронта живёт в разных
скоростях: фронт блокировок меняется неделями, устройство протоколов — кварталами,
источники и термины — годами.

Формальное обоснование структуры — ADR-0006 «Слоистая архитектура VPN-knowledge».
Базовая архитектура knowledge — ADR-0003.

---

## 0. Маршрутизатор: вопрос → 1-2 файла

**Читать эту таблицу, а не весь каталог.** Нашёл строку — открывай указанный файл и
только его. Не нашёл — иди в §2 (каталог) и в `_meta/glossary.md`.

Таблица индексирована **по вопросу и симптому**, а не по имени файла: имя помогает,
только если вопрос сформулирован теми же словами («клиент для iPhone» → `client-apps`),
и не помогает совсем, когда вопрос — это симптом («403 при входе в панель»).

| Вопрос / симптом | Открыть |
|---|---|
| Какой протокол брать для входа из РФ; почему WireGuard и OpenVPN не годятся; что такое Reality | `_reference/vpn-protocols.md` |
| Что прямо сейчас блокируют и что живёт — РФ / Китай / Иран / Беларусь | `_live/frontline-ru.md` (или `-cn` / `-ir` / `-by`) |
| Когда и чем ударили, чем ответили — хронология | `_live/timeline.md` |
| Транспорт: XHTTP, HTTPUpgrade, WS, gRPC, mKCP; что с каким протоколом и ядром сочетается | `_reference/transports.md` |
| Cloudflare-fronting, альтернативные CDN, WARP, uTLS, Reality fallback | `_reference/fronting-strategies.md` |
| Что ставить на iPhone / Android / Mac / Windows / Linux; чего нет в RU App Store; какое ядро у клиента | `_reference/client-apps.md` |
| Устройство панели 3X-UI: где лежат файлы, CLI `x-ui`, TLS-сертификат, как перезапустить ядро | `_reference/3x-ui-panel.md` |
| **HTTP 403 при программном входе в панель**, CSRF-токен, Bearer, `webBasePath` | `_reference/3x-ui-api.md` |
| Управление панелью из скрипта: инбаунды, клиенты (добавить, удалить, UUID), **статистика и сброс трафика**, кто онлайн, IP-история, бэкап базы | `_reference/3x-ui-api.md` |
| Маршрутизация **на сервере** (дефолт): split РФ / внешнее / block, синтаксис правил Xray | `_reference/routing-server-3xui.md` |
| Маршрутизация **на устройстве** через sing-box; раскол ядра 1.11 ↔ 1.12 | `_reference/routing-on-device-singbox.md` |
| Маршрутизация **на устройстве** через Xray в терминале (десктоп) | `_reference/routing-on-device-xray.md` |
| **Сайту нужен 443, а там VPN** — кто слушает порт, как развязать без обрыва клиентов | `_reference/web-and-vpn-coexistence.md` |
| Своя мульти-кнопочная подписка Happ: формат кнопок, балансир и observatory, лимит гео-баз ~50 МБ на iOS, РФ→direct | `_reference/happ-subscription-format.md` |
| Зеркалирование **чужой** платной подписки на свой сервер (обход лимита устройств) | `_reference/subscription-mirroring.md` |
| Цепочка Xray на Mac (VLESS→VLESS) для Claude Code, proxy-only без TUN | `_reference/xray-mac-chain.md` |
| Сети Docker для нового сервиса: 4-сеть-сегментация, expose vs publish, UFW и Docker | `_reference/server-networks-defaults.md` |
| **Симптом у пользователя:** Госуслуги и Сбер не открываются под VPN; VSCode идёт мимо VPN; нейросеть банит аккаунт; «грязный» IP; звонки рвутся; клиент ест батарею; я за границей, а РФ-сайты меня блокируют | `_reference/vpn-consultation-flow.md` §11 (FAQ) |
| Где арендовать заграничный VPS, каких хостеров избегать; сколько это стоит; брать подписку провайдера или свой сервер | `_reference/vpn-consultation-flow.md` §9-§10 |
| Как вести VPN-консультацию с новичком: какие вопросы задать, эталонная архитектура | `_reference/vpn-consultation-flow.md` §1-§8 |
| **DNS:** утечки резолвинга, DoH и DoU, российские домены мимо зарубежного резолвера | `_reference/routing-server-3xui.md` (на сервере) + `_reference/fronting-strategies.md` §8 (протоколы DNS) |
| **Включить туннель (TUN) на телефоне или ноутбуке**, «работает только браузер» | скилл `/generate-client-config` → `.claude/skills/generate-client-config/references/platform-quirks.md` |
| **«Не работает» без подробностей** — с чего начать разбор жалобы | скилл `/finalize-vpn-routing` → `.claude/skills/finalize-vpn-routing/references/complaint-triage.md` |
| Непонятен термин (TSPU, DPI, SNI, fingerprint, fronting) | `_meta/glossary.md` |
| Насколько доверять найденному источнику | `_meta/sources-registry.md` |
| Два источника противоречат друг другу | `_meta/conflicts.md` |
| Нужна картинка, как это устроено целиком | `_diagrams/vpn-architecture-reference.md` |

**Чего здесь нет и где искать.** Это база **фактов**; пошаговые операции живут в скиллах:

| Задача | Скилл |
|---|---|
| Поставить панель 3X-UI | `/setup-vpn-panel` |
| Настроить inbound / outbound / балансир / клиентов | `/configure-vpn-routing` |
| Дать программам **на сервере** доступ через прокси (`socks5h`, systemd-override) | `/setup-server-proxy` |
| Выпустить конфиг / QR для устройства | `/generate-client-config` |
| Собрать свою мульти-кнопочную подписку Happ | `/setup-happ-subscription` |
| Достать серверы из закрытой (HWID / зашифрованной) подписки | `/extract-subscription-servers` |
| Доделать застрявшую настройку маршрутизации; разобрать жалобу «не работает» | `/finalize-vpn-routing` |
| Обновить саму эту базу, когда она просрочена по TTL | `/refresh-vpn-knowledge` (порядок — §3) |

---

## 1. Три слоя

| Слой | Что хранит | TTL | Когда обновлять |
|---|---|---|---|
| `_live/` | Фронт борьбы по странам, хронология ударов | 14 дней | Каждые ~2 недели или при крупном событии |
| `_reference/` | Протоколы, панель, клиенты, транспорты, fronting-стратегии | 60 дней | Раз в 2 месяца или при breaking release |
| `_meta/` | Реестр источников, глоссарий, конфликты | 365 дней | Почти никогда, только по запросу |

---

## 2. Каталог

### `_live/` — фронт борьбы (TTL 14 дней)

| Файл | Что внутри |
|---|---|
| `frontline-ru.md` | Что работает / не работает / под угрозой в РФ-2026 на дату исследования |
| `frontline-cn.md` | Китай — опережает РФ на 6-12 мес, карта будущего |
| `frontline-ir.md` | Иран — сильные DPI-обходы, арсенал-донор |
| `frontline-by.md` | Беларусь — копирует РКН с лагом 0-3 мес, индикатор |
| `timeline.md` | Append-only хронология ударов и контр-мер 2024-2026 |

### `_reference/` — устройство мира (TTL 60 дней)

| Файл | Что внутри |
|---|---|
| `vpn-protocols.md` | Восемь VPN-протоколов: OpenVPN, WireGuard, AmneziaWG, SS, VMess, Trojan, VLESS+Reality, Hysteria/TUIC |
| `transports.md` | Транспорты: XHTTP, HTTPUpgrade, WS, gRPC, mKCP, и матрица «протокол × транспорт × ядро» |
| `fronting-strategies.md` | Cloudflare-fronting, альтернативные CDN, WARP, Reality fallback, uTLS |
| `3x-ui-panel.md` | Архитектура эталонной панели MHSanaei/3x-ui, файловая раскладка, CLI, TLS, грабли |
| `3x-ui-api.md` | REST API панели 3X-UI: cheatsheet curl-команд для скиллов |
| `client-apps.md` | Карта клиентов sing-box/xray на 6 платформах, iOS-специфика |
| `vpn-consultation-flow.md` | Сценарий VPN-консультации (hub): интервью с оператором, эталонная архитектура, выбор протокола входа, что такое TUN и чем отличается от SOCKS5, подписочная ссылка, расширения (отдельный выход для нейросетей, свой загр.VPS вместо провайдера), **FAQ по симптомам** (§11). Пошаговое включение TUN и чек-лист триажа жалобы **переехали в скиллы** — см. врезки в §5.4-5.6 и §12 |
| `routing-server-3xui.md` | **Маршрутизация на сервере (дефолт)** — split РФ/foreign/block в 3X-UI, Xray-синтаксис |
| `routing-on-device-singbox.md` | Маршрутизация на устройстве через sing-box (энтузиасты): раскол ядра 1.11↔1.12, клиенты |
| `routing-on-device-xray.md` | Маршрутизация на устройстве через Xray в терминале (энтузиасты-десктоп) |
| `xray-mac-chain.md` | Xray chain (VLESS→VLESS) на Mac для Claude Code: proxy-only bypass WL |
| `happ-subscription-format.md` | Формат мульти-кнопочной подписки Happ: JSON-массив кнопок-политик, управляющие HTTP-заголовки, профиль-манифест и iOS-нарезка гео (лимит ядра ~50 МБ), балансир observatory vs burstObservatory, РФ→direct, OpenGate-паттерн «реестр → генератор» |
| `subscription-mirroring.md` | Зеркалирование платной подписки на свой сервер (обход лимита устройств): извлечение → раздача через nginx /c/ → автосинк cron с канон-сравнением |
| `web-and-vpn-coexistence.md` | **Сайты + VPN на одном сервере (кто слушает 443)** — почему Reality и nginx не делят порт, 4 раскладки (A/B/C/D), decision tree, как развязать конфликт без обрыва живых клиентов |
| `server-networks-defaults.md` | **Серверные сети по умолчанию (Docker, сегментация, firewall)** — уровень «весь сервер целиком»: 4-сеть-сегментация (data internal / services / proxy-corridor / monitoring), expose vs publish vs host network, decision tree для нового сервиса, паттерн БД-в-двух-сетях, host network как исключение, UFW+Docker, `/var/run/docker.sock` как root-эквивалент |

### `_meta/` — мета-слой (TTL 365 дней)

| Файл | Что внутри |
|---|---|
| `sources-registry.md` | Реестр источников с весами доверия (HIGH/MEDIUM/LOW) |
| `glossary.md` | Единый словарь: TSPU, DPI, SNI, ASN, fingerprint, fronting, и т.д. |
| `conflicts.md` | Расхождения источников по конкретным фактам — для разрешения, не для забвения |

### Вне трёх слоёв

| Что | Пояснение |
|---|---|
| `_diagrams/vpn-architecture-reference.md` | Mermaid-схема эталонной домашней раскладки (клиент → сервер → split). **Без frontmatter, TTL не отслеживается**, в модель трёх слоёв ADR-0006 не входит. Ссылаются на неё `routing-server-3xui.md` и `vpn-consultation-flow.md`. Отмена диаграмм в ADR-0019 касалась `inventory/`, не этой папки |
| `_live/frontline.example.md`, `_live/timeline.example.md` | Шаблоны для новой страны / нового года хронологии. Не знание, а заготовка — валидатор их сиротами не считает |

---

## 3. Как обновлять

Селективная актуализация — через скилл:

```bash
/refresh-vpn-knowledge LAYER=live       # чаще всего (≤25 Tavily запросов)
/refresh-vpn-knowledge LAYER=reference  # реже (≤30 запросов)
/refresh-vpn-knowledge LAYER=meta       # почти никогда, по запросу
/refresh-vpn-knowledge LAYER=all        # все слои
```

Default — `LAYER=live`, потому что фронт борьбы устаревает быстрее всего.

Проверить свежесть — без сети:

```bash
bash .claude/skills/_lib/check-knowledge-freshness.sh vpn
```

Helper рекурсивен — пробежит по всем трём подпапкам.

---

## 4. Дисциплина источников

Не все источники одинаково надёжны. Реестр весов — в `_meta/sources-registry.md`.

Правило:

- **HIGH** (Cloudflare blog, GFW Report, OONI, XTLS-official) — можно цитировать
  как факт.
- **MEDIUM** (ntc.party, Habr с замерами, Hub.xeovo) — можно цитировать, но
  предпочтительно с подтверждением из HIGH.
- **LOW** (Telegram-каналы, Reddit, форумы) — только как подтверждение, не
  первичный источник.

Утверждение в `_live/` или `_reference/` требует **≥1 HIGH** ИЛИ **≥2 независимых MEDIUM**.
Иначе — пометка `? уточнить (не подтверждено: <дата>)`.

Конфликт двух HIGH или двух MEDIUM — фиксируется в `_meta/conflicts.md` с обеими
цитатами и датами, без выбора стороны.

---

## 5. Связи

- **ADR-0003** — базовая архитектура `.claude/knowledge/` (общая для всех доменов).
- **ADR-0005** — архитектура VPN-блока (4 скилла, потребители этой базы).
- **ADR-0006** — формальное обоснование расслоения именно VPN-домена.
- **Презумпция устаревания VPN-knowledge** — `.claude/agents/references/presumptions.md`.
- **Скилл `/refresh-vpn-knowledge`** — `.claude/skills/refresh-vpn-knowledge/SKILL.md`.

---

## 6. Что НЕ хранится здесь

- Реальные данные оператора (IP, домены, имена хостов, ssh-алиасы, ключи) — это папка
  инфры активного проекта. Репозиторий публичный: в knowledge только обезличенные
  плейсхолдеры (`<ваш-сервер>`, `<ваш-домен>`). Принуждается
  `scripts/check-private-data.sh` в pre-commit (ADR-0036).
- Процедуры скиллов (команды, шаблоны конфигов) — это `.claude/skills/<имя>/`,
  список — в §0.
- Конституция и персона агента — это `CLAUDE.md` в корне репозитория и
  `.claude/agents/references/` (ADR-0015; `.claude/agents/sysadmin.md` — заглушка-указатель,
  не источник).
- Архитектурные решения — это `decisions/` (ADR).
