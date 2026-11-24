---
name: configure-vpn-routing
description: |
  Настройка VPN-маршрутизации на установленной панели 3X-UI: inbound для клиентов
  (VLESS + TLS для ru-server, VLESS+Reality для foreign-server), outbound через
  подписку провайдера (сервера — из уже извлечённого `/extract-subscription-servers`
  JSON; извлечением сам НЕ занимается; оператор выбирает страну выхода и пресет) ИЛИ
  через свой загр.VPS; balancer leastPing + observatory (probeInterval=5m, стабильный
  IP) для нескольких outbound; routing по модели «золотая середина» (7 правил);
  массовое добавление клиентов с UUID. REST API панели — основной путь.
  Триггеры: «настрой маршрутизацию VPN», «добавь клиента», «настрой VLESS
  на панели», «семье нужен VPN», «outbound через подписку», «вот моя подписка
  настрой выход», «хочу выходить из США/Германии», «мульти-хоп через свой
  загр.VPS», «настрой балансировщик», «чтобы IP не скакал», «configure-routing»,
  «добавь второй сервер в balancer».
  НЕ для установки панели — `/setup-vpn-panel`. НЕ для серверного прокси —
  `/setup-server-proxy`. НЕ для клиентских конфигов — `/generate-client-config`.
  НЕ для извлечения серверов из закрытой/зашифрованной подписки — это
  `/extract-subscription-servers` (запускается ДО этого скилла).
allowed-tools: Bash, Read, Edit, Write
---

<role>
Я настраиваю VPN-маршрутизацию на уже установленной панели 3X-UI: создаю
inbound для клиентов, outbound (через подписку провайдера или свой загр.VPS),
балансировщики, правила маршрутизации, массово добавляю клиентов с UUID.
Работаю через REST API панели — никаких кликов по UI, никаких скриншотов.
</role>

<context>
Предполагается:
- 3X-UI установлен (через `/setup-vpn-panel`), панель отвечает по HTTPS.
- В `infra-config.json` секция `vpn` с `panel_url`, `panel_web_base_path`.
- Креды панели в менеджере паролей оператора под именем `3xui-panel-${SERVER_ALIAS}`.
- Для `OUTBOUND_KIND=subscription` — оператор передал подписной URL или
  прямой vless://-link от провайдера.
- Для `OUTBOUND_KIND=self-foreign` — оператор уже поднял загр.VPS отдельным
  запуском `/setup-vpn-panel --location=foreign-server` и имеет от него
  vless://-link.

НЕ предполагается:
- Знание оператором конкретной структуры inbound/outbound. Скилл сам формирует.
- Готовые reality keypair — генерирует через `xray x25519` на сервере.
- Что у оператора 1 outbound — поддерживает несколько с balancer.
</context>

<goals>
После выполнения должно стать TRUE:
- Создан inbound для клиентов (или используется существующий).
- Для `OUTBOUND_KIND=subscription`: сервера подписки сохранены в
  `$INFRA/inventory/shared/vpn-subscriptions/<provider>.json` и размечены по
  странам; с оператором выбрана страна выхода (`EXIT_COUNTRY`) и пресет
  (`OUTBOUND_PRESET`); как outbound заведены ТОЛЬКО сервера выбранной страны
  (не все скопом).
- Создан 1+ outbound: либо из выбранной страны подписки, либо
  `OUTBOUND_KIND=self-foreign` (один с параметрами от своего загр.VPS).
- Если outbound > 1 (пресет `country-failover`) — создан balancer со стратегией
  `leastPing` + observatory с `probeInterval=5m` (стабильный IP + авто-failover
  внутри страны). Пресет `single` → один outbound, без балансира (неизменный IP).
- Routing rules по модели «золотая середина» (7 правил, порядок сверху вниз):
  1. `inboundTag=api` → api;
  2. `geoip:private` → direct (локальная сеть; НЕ blocked);
  3. `bittorrent` → blocked;
  4. `geosite:category-ads-all` → blocked (реклама);
  5. `geoip:ru` → direct;
  6. `geosite:category-ru` + regex `.ru/.su/.рф` → direct;
  7. default (vless/mixed inbounds) → upstream (balancer или один outbound).
  Явный список РФ-доменов НЕ добавляется (РФ-сервисы ловятся `geoip:ru`).
- Клиенты добавлены (минимум 1 — создаётся вместе с inbound).
- Xray перезапущен, изменения активны.
- Inventory обновлён: блок про routing/clients в `networks.md`.
- `infra-config.json` обновлён: `vpn.upstream_kind` соответствует выбору.
</goals>

# Параметры

| Параметр | Required | Default | Описание |
|---|---|---|---|
| `SERVER_ALIAS` | да | — | Имя сервера для менеджера паролей и inventory |
| `PANEL_DOMAIN`, `PANEL_PORT`, `WEB_BASE_PATH` | да | из `vpn.*` в config | Параметры панели |
| `ADMIN_LOGIN`, `PASSWORD_REF` | да | автодетект из менеджера | Креды панели |
| `OUTBOUND_KIND` | нет | `ask` | `subscription` / `self-foreign` / `mixed` / `ask` |
| `SUBSCRIPTION_URL` | условно | — | Для `OUTBOUND_KIND=subscription`. Если сервера ещё не извлечены — сначала `/extract-subscription-servers` |
| `PROVIDER_SLUG` | нет | `subscription` | Короткое имя провайдера для файла в infra (`blanc`, `nurvpn`, `panterra`). Совпадает с тем, под которым сохранил `/extract-subscription-servers` |
| `EXIT_COUNTRY` | нет | `ask` | ISO-код страны выхода (`US`/`NL`/...). Если `ask` — диалог на Шаге 5A.2 |
| `OUTBOUND_PRESET` | нет | `ask` | `country-failover` (несколько серверов одной страны + балансир) / `single` (один сервер). Default-диалог на Шаге 5A.3 |
| `PROBE_INTERVAL` | нет | `5m` | Как часто observatory переоценивает серверы. 5m (не 1m) = стабильнее IP |
| `UPSTREAM_VPN_URL` | условно | — | Прямой vless://-link (вместо subscription URL или для `self-foreign`) |
| `INBOUND_PORT` | нет | `443` | Порт inbound на сервере |
| `INBOUND_PROTOCOL` | нет | авто из `vpn.server_role` | `vless-tls` (ru-server) / `vless-reality` (foreign-server) / `vless-tcp` (без TLS — только частный адрес, `CONFIRM_PLAIN_VLESS=yes`, ADR-0045). Если роль не зафиксирована — уточняется у оператора (Шаг 4) |
| `SERVER_ROLE` | нет | из `vpn.server_role` | `ru-server` / `foreign-server`. Источник правды для протокола и guard'а. Если null — спрашиваю |
| `INBOUND_FLOW` | нет | `xtls-rprx-vision` для reality / пусто для tls и tcp | Flow для VLESS |
| `INBOUND_ONLY` | нет | `false` | Если `true` — создать только inbound, без outbound/routing (для подготовки загр.VPS) |
| `CLIENT_NAMES` | нет | `["main"]` | JSON-массив имён клиентов |
| `BALANCER_STRATEGY` | нет | `leastPing` | `random` / `roundRobin` / `leastPing` / `leastLoad` |
| `REALITY_DEST` | нет | из config `vpn.default_reality_dest` | Только для `vless-reality` inbound |
| `SSH_TARGET` | условно | — | Для генерации Reality keypair при `vless-reality` |

# Процедура

## Шаг 0a: Чтение конфига (STRICT)

Скилл — STRICT-режим: без `infra-config.json` с секцией `vpn.*` (`panel_url`,
`panel_web_base_path`) не запускается — иначе непонятно, к какой панели обращаться и
откуда брать креды. Проверка — **до** Шага 0 (Pre-check). Общий helper
`_lib/find-config.sh` (алгоритм = Cold Start персоны); `$SYSADMIN_ROOT` запомнен
на Шаге 1 Cold Start.

```bash
source "$SYSADMIN_ROOT/.claude/skills/_lib/find-config.sh"

# STRICT: exit 1 если конфига нет
find_sysadmin_config strict       # $CONFIG = infra-config.json (vpn.*)
find_brain_config || true         # $BRAIN_CONFIG = agent-config.json (secrets/язык)

# Агент-поля (ADR-0013): secrets.manager и язык живут в мозге ($BRAIN_CONFIG).
# Legacy-совместимость: если мозга нет — читаем из $CONFIG (старый единый формат).
#   language переехал в .operator.language (мозг); в legacy — top-level .language.
get_agent_field() {  # $1=jq-путь-в-мозге, $2=jq-путь-в-legacy, $3=default
  local v=""
  [ -n "${BRAIN_CONFIG:-}" ] && v=$(jq -r "$1 // empty" "$BRAIN_CONFIG" 2>/dev/null)
  [ -z "$v" ] && [ -n "${CONFIG:-}" ] && [ -f "${CONFIG:-}" ] && v=$(jq -r "$2 // empty" "$CONFIG" 2>/dev/null)
  [ -z "$v" ] && v="$3"
  echo "$v"
}

# vpn.panel_url и vpn.panel_web_base_path обязательны (инфра-поля → $CONFIG)
require_config_field "vpn.panel_url" \
    "Это значит 3X-UI ещё не установлен. Сначала запусти /setup-vpn-panel SSH_TARGET=... DOMAIN=..."
require_config_field "vpn.panel_web_base_path" \
    "Это значит 3X-UI ещё не установлен. Сначала запусти /setup-vpn-panel SSH_TARGET=... DOMAIN=..."

# Параметры (CLI override > конфиг)
PANEL_URL=$(get_config_field vpn.panel_url)
PANEL_WEB_BASE_PATH=$(get_config_field vpn.panel_web_base_path)
PANEL_DOMAIN="${PANEL_DOMAIN:-$(echo "$PANEL_URL" | sed -E 's|https?://||; s|:.*$||')}"
PANEL_PORT="${PANEL_PORT:-$(echo "$PANEL_URL" | sed -E 's|https?://[^:]+:||; s|/.*$||')}"
WEB_BASE_PATH="${WEB_BASE_PATH:-$PANEL_WEB_BASE_PATH}"
SECRETS_MANAGER=$(get_agent_field '.secrets.manager' '.secrets.manager' keychain)
REPORT_LANGUAGE=$(get_agent_field '.operator.language' '.language' ru)

# Роль сервера — источник правды для протокола inbound и для guard'а.
# Записывается /setup-vpn-panel в vpn.server_role. Может быть null (старый
# конфиг / установка вне скилла) — тогда уточняем у оператора (см. Шаг 4).
SERVER_ROLE=$(get_config_field vpn.server_role "")

# Авто-вывод протокола inbound из роли сервера (CLI override имеет приоритет):
#   ru-server      → vless-tls   (вход внутри РФ: Reality НЕ нужен, TLS нужен — ADR-0045)
#   foreign-server → vless-reality (трансграничный вход, маскировка обязательна)
if [ -z "${INBOUND_PROTOCOL:-}" ]; then
    case "$SERVER_ROLE" in
        ru-server)      INBOUND_PROTOCOL="vless-tls" ;;
        foreign-server) INBOUND_PROTOCOL="vless-reality" ;;
        *)              INBOUND_PROTOCOL="" ;;   # роль неизвестна — уточнить на Шаге 4
    esac
fi
```

После успешного чтения переходим к Шагу 0 (Pre-check панели и upstream).

## Шаг 0: Pre-check (Green Zone)

- Панель отвечает: `curl -sI https://$PANEL_DOMAIN:$PANEL_PORT/$WEB_BASE_PATH/` → 200.
- Login через `_lib-api.sh` проходит (правильный логин/пароль).
- Если `OUTBOUND_KIND=subscription` — `SUBSCRIPTION_URL` или `UPSTREAM_VPN_URL` задан.
- Если `OUTBOUND_KIND=self-foreign` — `UPSTREAM_VPN_URL` задан и парсится.

Если что-то не так — STOP с конкретной причиной.

## Шаг 1: Архитектурный диалог (если `OUTBOUND_KIND=ask`)

Сеньор-обёртка (раздел 4.3 персоны), два пути — `references/multi-hop-architectures.md`:
**Путь A (подписка)** — минимум усилий, провайдер сам адаптируется к РКН;
**Путь B (свой загр.VPS)** — полный контроль, больше инфраструктуры; **Гибрид** —
свой основной + подписка fallback. Контекст → мини-урок → варианты с плюсами/минусами
→ рекомендация (при сомнениях Путь A) → разрешение довериться → открытая дверь.

## Шаг 2: Брифинг 6 пунктов (Yellow Zone)

1. **ЧТО ДЕЛАЮ**: создаю inbound `vless-$INBOUND_PROTOCOL` на $INBOUND_PORT,
   $UPSTREAM_COUNT outbound из $OUTBOUND_KIND, $CLIENT_COUNT клиентов,
   routing по «золотой середине» (7 правил: private→direct, реклама/bittorrent→block,
   geoip:ru + category-ru + regex→direct, остальное → $UPSTREAM_REF).
2. **ЗАЧЕМ**: чтобы клиенты могли подключаться через панель и ходить
   в свободный интернет, при этом РФ-трафик идёт напрямую (быстрее, и РФ-сайт
   видит российский IP — не банит как VPN-юзера), а реклама режется.
3. **ЧТО ПРОИЗОЙДЁТ**: ~30-60 секунд изменений через API + restart Xray
   (1-2 секунды простоя, не рвёт активные TCP-сессии).
4. **ЧТО ПРОВЕРИЛ**: пре-чек прошёл, ссылки распарсились корректно.
5. **РИСК + ОТКАТ**: если что-то пойдёт не так — восстановление xray-конфига
   из бэкапа (`api_get_xray_config` сохраняется до изменений).
6. **СТРАХОВКА**: после изменений — `list_inbounds` для проверки + ручной
   smoke check (подключение клиента и `curl -I https://2ip.ru`).

## Шаг 3: Получение пароля из менеджера

Скилл вычисляет `PASSWORD_REF` исходя из `agent-config.json` (`secrets.manager`)
и `SERVER_ALIAS`:

```
keychain  → "keychain:3xui-panel-${SERVER_ALIAS}"
pass      → "pass:3xui-panel-${SERVER_ALIAS}"
bw        → "bw:3xui-panel-${SERVER_ALIAS}"
op        → "op:Private/3xui-panel-${SERVER_ALIAS}/password"
keepassxc → "keepassxc:3xui-panel-${SERVER_ALIAS}"
```

Login через `api_login` — пароль читается из менеджера автоматически.

> **KeePassXC:** ссылка `keepassxc:<заголовок записи>` требует ENV `KEEPASSXC_DB`
> (путь к `.kdbx`) и `KEEPASSXC_PASSWORD` (мастер-пароль, подаётся `keepassxc-cli` по
> stdin); опционально `KEEPASSXC_KEYFILE`. Мастер-пароль в git/inventory не пишется —
> оператор подаёт его в сессии (как прямую передачу секрета, C.10). Значения web-base-path
> и логин панели тоже лежат записью `3xui-panel-${SERVER_ALIAS}` в KeePassXC.

## Шаг 4: Inbound (если требуется)

Если `INBOUND_ONLY=true` или у панели ещё нет vless-inbound — `scripts/create-vless-inbound.sh`
создаёт inbound. Протокол по умолчанию выводится **автоматически из `vpn.server_role`** (Шаг 0a):
- `ru-server` → **VLESS + TLS** (вход внутри РФ, TSPU не пересекается — маскировка не нужна, но TLS нужен:
  клиенты на Xray-core 26.7.11+ VLESS без TLS к публичному адресу не собирают, а без TLS UUID идёт
  открытым текстом; сертификат — домена панели, пути из настроек панели или `TLS_CERT_FILE`/`TLS_KEY_FILE`;
  ADR-0045). VLESS без TLS (`vless-tcp`) — только к частному адресу и по `CONFIRM_PLAIN_VLESS=yes`.
- `foreign-server` → **VLESS+Reality** (трансграничный вход; генерирует keypair, выбирает shortId).

**Если `SERVER_ROLE` пуст** (роль не зафиксирована — старый конфиг или установка
панели вне скилла) — `INBOUND_PROTOCOL` пуст, и я **НЕ угадываю**. Применяю
сеньор-обёртку и спрашиваю оператора прямым вопросом: «Сервер с панелью — в РФ или
за границей?» По ответу выставляю `SERVER_ROLE` и протокол, **и дописываю
`vpn.server_role` в конфиг** (чтобы впредь не спрашивать). Дефолт при сомнении —
`ru-server` + `vless-tls`.

Запуск скрипта **всегда** с `SERVER_ROLE`:

```bash
SERVER_ROLE="$SERVER_ROLE" \
INBOUND_PROTOCOL="$INBOUND_PROTOCOL" \
INBOUND_LISTEN_PORT="$INBOUND_PORT" \
... ./scripts/create-vless-inbound.sh
```

> 🧑‍🏫 **Reality на РФ-сервере — менторская развилка, не запрет.** Дефолт для
> `ru-server` — `vless-tls` (внутри РФ TSPU не пересекается, маскировать нечего; TLS — шифрование).
> Если оператор осознанно хочет Reality на РФ-inbound (эксперимент/учёба) — не
> обрываю, объясняю почему обычно не нужно, уточняю «точно хочешь?», и при
> подтверждении повторяю запуск с `CONFIRM_REALITY_ON_RU=yes`. Guard в
> `create-vless-inbound.sh` (exit 3) ловит только СЛУЧАЙНУЮ подстановку. Полный
> менторский сценарий — `references/pitfalls.md`; рефлекс персоны 3.8.5.

**Сервер уже с входом без TLS (переезд, ADR-0045).** Старый вход не трогаю — на нём
живые устройства. Создаю `vless-tls` на **отдельном** порту (за nginx stream — на
loopback), в карте `stream` веду имя домена на новый upstream, старый вход остаётся на
`default`, пока устройства не перейдут на новые ссылки (`/generate-client-config`).
Схема и грабли `default` — `knowledge/networking/_reference/web-and-vpn-coexistence.md`
(SNI-развилка). Правка nginx — отдельный пункт брифинга.

При создании — сразу один client_uuid для первичного клиента (имя из
`CLIENT_NAMES[0]` или `admin`).

## Шаг 5: Outbound — два пути

### Путь A: subscription

**5A.1 — Получить сервера подписки (извлечение делегируется отдельному скиллу).**
Извлечение из подписки — особенно из ЗАКРЫТЫХ (HWID-locked: Panterra, NurVPN) —
это отдельный жанр (разные форматы тела, HWID-замок, слоты устройств). Им
занимается скилл **`/extract-subscription-servers`** — он один отвечает за добычу
и сохранение серверов в infra, размеченных по странам. Этот скилл (configure-vpn-routing)
здесь логику извлечения **НЕ дублирует** — он работает с уже готовым JSON.

```bash
# Папка инфры активного проекта (ADR-0013): её знает реестр projects[] в мозге —
# resolve_active_project (внутри find_sysadmin_config) уже выставил $ACTIVE_INFRA_ROOT.
# Legacy-совместимость: если мозга нет — старый путь infrastructure.root_path из $CONFIG.
INFRA_DIR="${ACTIVE_INFRA_ROOT:-}"
[ -z "$INFRA_DIR" ] && INFRA_DIR="$(get_config_field infrastructure.root_path)"
SUBS_FILE="$INFRA_DIR/inventory/shared/vpn-subscriptions/${PROVIDER_SLUG:-subscription}.json"
```

Два случая:

- **Сервера уже извлечены** (файл `$SUBS_FILE` существует — оператор раньше
  запускал `/extract-subscription-servers`): читаю его напрямую.
  ```bash
  jq '.servers' "$SUBS_FILE" > /tmp/subs-enriched.json
  # массив серверов с полем "country" (US/NL/DE/.../?)
  ```
- **Сервера ещё не извлечены** (файла нет): НЕ извлекаю сам. Останавливаюсь и
  направляю оператора на `/extract-subscription-servers` — он достанет сервера из
  подписки «под ключ» (форматы, HWID-замок, слоты; особенно важно для закрытых
  Panterra/NurVPN), а потом вернёмся сюда. См. ADR-0010 и `references/pitfalls.md`.

После получения `/tmp/subs-enriched.json` — переход к 5A.2 (выбор страны выхода).

**5A.2 — Диалог выбора страны выхода (сеньор-обёртка, раздел 4.3 персоны).**
НЕ заводить все 50 серверов скопом — это даёт «скачущий IP по странам» (бан
аккаунтов, см. `_live/frontline-ru.md`). Вместо этого:

1. Сгруппировать сохранённые сервера по странам и показать сводку
   человеческим языком:
   ```bash
   jq -r 'group_by(.country) | .[] | "  \(.[0].country): \(length) серв."' /tmp/subs-enriched.json
   ```
   → «🇺🇸 США — 5, 🇳🇱 Нидерланды — 3, 🇩🇪 Германия — 2».
2. **Мини-урок + вопрос:** «С какого адреса хочешь выходить в интернет (для
   нейросетей, заблокированных сервисов)? Это твой постоянный "адрес прописки"
   в сети — лучше держать одну страну, чтобы сайты не блокировали аккаунт за
   прыжки между странами.» Оператор отвечает, например, «США».
3. Отфильтровать сервера выбранной страны:
   ```bash
   COUNTRY=US  # из ответа оператора
   jq --arg c "$COUNTRY" '[.[] | select(.country == $c)]' /tmp/subs-enriched.json > /tmp/subs-chosen.json
   ```
   Если для страны несколько серверов с `country: "?"` (тег без флага) — НЕ
   выдумывать страну: либо определить по гео-IP хоста (`curl ipinfo.io/<host>`),
   либо честно спросить оператора «сервер X — какая страна?».

**5A.3 — Выбор пресета (стабильность vs живучесть).** Спрашиваю явно — лишний вопрос
не повредит, если объяснён:

| Пресет | Что делаю | Как объясняю оператору |
|---|---|---|
| **одна страна + авто-failover** (дефолт) | все сервера выбранной страны как outbound, `leastPing`-балансир, `probeInterval=5m` | «Работаешь в основном с одного, самого быстрого. Упадёт — незаметно переедешь на соседний, страна та же, аккаунт не пострадает. IP скакать не будет: переоценка редкая» |
| **один фиксированный сервер** | один outbound, без балансира | «Абсолютно неизменный IP. Минус: упадёт — переключим вручную» |
| **разные страны** (только осознанно) | балансир из серверов РАЗНЫХ стран | **дефолтом не предлагаю и по своей инициативе не собираю** (рефлекс §3.8.6) |

Третий пресет — менторский разговор, а не переключатель. Скачущий IP = бан антифродом
нейросетей: смена страны внутри сессии читается как угон аккаунта. Оператор просит сам —
проговариваю риск дословно (полный текст — `references/pitfalls.md`), уточняю «это для
нейросетей или для другого трафика?», и только при осознанном согласии ставлю
`CONFIRM_MULTI_COUNTRY=yes` на Шаге 6. **Запрет:** не повторять ложь «балансир между
странами не влияет на блокировки» — она фактически неверна (C.2).

```bash
# Завести выбранные сервера как outbound
for vless in $(jq -c '.[]' /tmp/subs-chosen.json); do
    VLESS_JSON="$vless" ./scripts/add-outbound-from-vless.sh
done
```

Сколько серверов завелось → столько `upstream-<slug>` outbound. Это число
определяет `USE_BALANCER` на Шаге 6 (>1 → балансир, =1 → один outbound).

### Путь B: self-foreign

```bash
UPSTREAM_VPN_URL=... ./scripts/parse-vless-link.sh > /tmp/vless.json
VLESS_JSON=$(cat /tmp/vless.json) \
OUTBOUND_TAG_PREFIX=upstream \
./scripts/add-outbound-from-vless.sh
```

Один outbound, tag = `upstream-<slug-from-vless-tag>`.

## Шаг 6: Routing + balancer (если outbound > 1)

```bash
# Все upstream-теги выбранной страны (из Шага 5A.3).
# PROBE_INTERVAL=5m — реже переоценка, клиент держится за один сервер (стабильнее IP).
# UPSTREAM_COUNTRIES_JSON — коды стран ПАРАЛЛЕЛЬНО тегам (из enriched-JSON Шага 5A,
#   поле .country). Нужен, чтобы guard убедился: страна одна. НЕ парсить страну из
#   имени тега — тег бывает upstream-blanc-usa/upstream-server (правило №1 CLAUDE.md).
UPSTREAM_TAGS_JSON='["upstream-us-1","upstream-us-2","upstream-us-3"]' \
UPSTREAM_COUNTRIES_JSON='["us","us","us"]' \
BALANCER_STRATEGY=leastPing \
PROBE_INTERVAL=5m \
./scripts/setup-routing.sh
```

> ⛔ **Guard «разные страны в балансире».** Если `UPSTREAM_COUNTRIES_JSON` содержит
> >1 страны (или не передан вовсе) — `setup-routing.sh` делает **exit 3** и НЕ
> собирает балансир (защита от скачущего IP = бана нейросетей). Обойти ТОЛЬКО
> осознанно: пресет «разные страны» из 5A.3 + `CONFIRM_MULTI_COUNTRY=yes` (рабочий
> пример вызова — `references/pitfalls.md`). Симметрично `CONFIRM_REALITY_ON_RU` в
> `create-vless-inbound.sh`. Рефлекс персоны 3.8.6 и ADR-0011.

> 🧭 **Стратегия балансира.** Дефолт — `leastPing` + `probeInterval=5m` + сервера одной
> страны: стабильный IP в норме, авто-failover при падении, страна не меняется.
> `random` и `roundRobin` НЕ использовать — размазывают трафик, IP скачет. Sticky-порога
> «N мс разницы» в серверном балансире 3X-UI **нет** — это клиентская настройка sing-box
> (`urltest.tolerance`), см. `3x-ui-panel.md` §1.3. Пресет «один сервер» (Шаг 5A.3) →
> `USE_BALANCER=no`, default-правило шлёт на единственный outbound.

Скрипт создаёт `routing.rules` по модели **«золотая середина»** — те же 7 правил, что
перечислены в `<goals>` (порядок сверху вниз, применяется первое совпавшее). Он же
гарантирует наличие outbound `direct` (freedom) и `blocked` (blackhole), ставит
`routing.domainStrategy = "IPIfNonMatch"`, а при `leastPing`/`leastLoad` добавляет
observatory с `probeInterval=$PROBE_INTERVAL` (не устаревший `pingConfig`).

Три решения внутри модели, которые легко нарушить по невнимательности: `geoip:private` →
direct **отдельным приоритетным правилом**, не в куче с РФ; `.рф` в правилах пишется
в punycode (`xn--p1ai`); **явный список РФ-доменов на не-РФ TLD НЕ добавляется** — топовые
сервисы и так на РФ-адресах и ловятся `geoip:ru`, а придуманные домены нарушают C.2.

> Идемпотентность: скрипт перезаписывает `.routing` целиком и доустанавливает недостающие
> outbound `direct`/`blocked` — повторный запуск приводит конфиг к той же эталонной модели.

## Шаг 7: Массовое добавление клиентов

Если `CLIENT_NAMES > 1`:

```bash
INBOUND_ID=$INBOUND_ID \
CLIENT_NAMES_JSON='["alice","bob","mum"]' \
./scripts/add-clients.sh > /tmp/clients.json
```

Скрипт делает паузу 150мс между запросами (защита от database lock).

## Шаг 8: Финальный restart Xray + verify

`api_restart_xray` (уже делается каждым sub-скриптом, но на всякий случай —
повторно после всех изменений).

Verify:
```bash
# 1. inbound создан
api_list_inbounds | jq ".obj[] | select(.id == $INBOUND_ID)"
# 2. outbounds присутствуют
api_get_xray_config | jq ".obj.outbounds[] | .tag"
# 3. routing rules
api_get_xray_config | jq ".obj.routing.rules"
```

## Шаг 9: Обновление inventory и конфига

В `inventory/hosts/$SERVER_ALIAS/networks.md` — раздел `## VPN routing` с четырьмя
подразделами: **Inbound** (порт, протокол, клиенты со ссылкой на UUID), **Outbound**
(страна выхода, пресет, теги, файл серверов подписки), **Balancer** (стратегия и
`probeInterval`; при пресете «один сервер» балансира нет), **Routing** (модель «золотая
середина», 7 правил — перечень в `<goals>` и Шаге 6).

В `infra-config.json` — `vpn.upstream_kind` (`subscription` / `self-foreign` / `mixed`).

Готовые образцы обоих блоков — `references/output-templates.md`.

## Шаг 10: Финальный отчёт

Отчёт перечисляет: созданный inbound, где лежат сервера подписки, страну выхода и пресет,
число outbound, стратегию балансира, число правил маршрутизации, число клиентов, какие
файлы inventory и конфига обновлены. Дальше — smoke-check оператору: открыть панель,
выпустить клиентскую ссылку через `/generate-client-config`, импортировать в клиент и
проверить на сайте определения IP, что РФ-сайты идут напрямую, а зарубежные — через
upstream. Готовый текст — `references/output-templates.md`.

# Откат

Бэкап xray-конфига сохраняется до изменений. При сбое — восстановить:

```bash
# из db-бэкапа на сервере:
ssh $SSH_TARGET "cp /etc/x-ui/x-ui.db.backup.<ts> /etc/x-ui/x-ui.db && systemctl restart x-ui"
# или через API из сохранённого JSON-конфига до изменений:
api_update_xray_config "$BACKUP_CONFIG_JSON" && api_restart_xray
```

# Подводные камни и граничные случаи

Полный список грабель и граничных ситуаций — `references/pitfalls.md`. Самое
критичное по безопасности (его нельзя забыть) — здесь:

- **НЕ заводить сервера разных стран в один балансир.** Скачущий IP = бан
  антифродом нейросетей (OpenAI/Anthropic/Google: смена страны в сессии = угон).
  Enforced: `setup-routing.sh` делает exit 3 при >1 страны без
  `CONFIRM_MULTI_COUNTRY=yes`. Рефлекс 3.8.6, ADR-0011.
- **НЕ ставить Reality на РФ-inbound по своей инициативе** — внутри РФ TSPU не
  пересекается, маскировать нечего; дефолт `vless-tls`. Reality на РФ — только по
  осознанному `CONFIRM_REALITY_ON_RU=yes` после менторского объяснения. Guard в
  `create-vless-inbound.sh` (exit 3) ловит случайную подстановку. Рефлекс 3.8.5.
- **НЕ создавать VLESS без TLS к публичному адресу — ни входом, ни исходящим.** Клиенты
  на Xray-core 26.7.11+ такой вход не собирают; исходящее без TLS на сервере после
  обновления xray не даёт ядру стартовать целиком. Enforced: `create-vless-inbound.sh`
  (`vless-tcp`) и `add-outbound-from-vless.sh` (ссылка без `tls`/`reality`) — exit 3 без
  `CONFIRM_PLAIN_VLESS=yes`, осмысленного только для частного адреса. Проверять ядром
  **клиента**: серверное обычно старше и дефекта не видит. ADR-0045. Регресс (оба замка,
  сборка `vless-tls`, пути сертификата под Git Bash/MSYS) — офлайновый
  `tests/test-vless-inbound-guards.sh`; прогон:
  `bash .claude/skills/configure-vpn-routing/tests/test-vless-inbound-guards.sh`.
- **Sticky-порога «N мс» в серверном балансире 3X-UI НЕТ** — это клиентская
  настройка sing-box (`urltest.tolerance`). НЕ вписывать несуществующее поле
  (правило №1). Стабильность IP = одна страна + `probeInterval=5m`.
- **Outbound правится ТОЛЬКО через get/updateXrayConfig** (нет CRUD-API); после
  изменений — явный `api_restart_xray`; `leastPing` требует observatory (не
  `pingConfig`); `domainStrategy=IPIfNonMatch` + sniffing иначе routing не работает;
  Reality privateKey клиенту НИКОГДА (только pbk).
- **Сервера ещё не извлечены из подписки** → НЕ извлекать здесь, направить на
  `/extract-subscription-servers`. Страна `?` → определить по гео-IP или спросить,
  не выдумывать (правило №1).

# Bundled resources

| Файл | Что это и когда открывать |
|---|---|
| `references/multi-hop-architectures.md` | **Какой путь outbound выбрать**: подписка провайдера, свой заграничный VPS, гибрид «свой + подписка как fallback», архитектурные правила. Открывать на Шаге 1 (архитектурный диалог) |
| `references/pitfalls.md` | **Грабли и граничные случаи** + два менторских разговора дословно: «разные страны в балансире» и «Reality на РФ-сервере». Открывать, когда оператор просит то, от чего guard защищает |
| `references/output-templates.md` | **Образцы записей и отчёта**: раздел `## VPN routing` для `networks.md` и полный текст финального отчёта со smoke-check. Открывать на Шагах 9 и 10 |
| `scripts/parse-vless-link.sh`, `add-outbound-from-vless.sh` | разбор ссылки и заведение outbound (Шаг 5) |
| `scripts/create-vless-inbound.sh` | inbound с guard'ом `CONFIRM_REALITY_ON_RU` (Шаг 4) |
| `scripts/setup-routing.sh` | маршрутизация и балансир с guard'ом `CONFIRM_MULTI_COUNTRY` (Шаг 6) |
| `scripts/add-clients.sh` | массовое добавление клиентов с паузой против database lock (Шаг 7) |

Соседние скиллы: `/extract-subscription-servers` — извлечение серверов из подписки
(запускается ДО этого скилла), `/generate-client-config` — QR и конфиги для устройств
(после). Внешние источники: `knowledge/networking/_reference/vpn-protocols.md` §4 (теория
multi-hop), `3x-ui-api.md` §6 (outbounds и routing через API), `3x-ui-panel.md` §1.3–1.4
(балансиры и observatory), `decisions/0005-vpn-architecture.md` §3 и
`decisions/0010-hwid-locked-subscriptions.md`.
