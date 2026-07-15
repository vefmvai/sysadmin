---
name: configure-vpn-routing
description: |
  Настройка VPN-маршрутизации на установленной панели 3X-UI: inbound для клиентов
  (VLESS-TCP для ru-server, VLESS+Reality для foreign-server), outbound через
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
| `INBOUND_PROTOCOL` | нет | авто из `vpn.server_role` | `vless-tcp` (ru-server) / `vless-reality` (foreign-server). Если роль не зафиксирована — уточняется у оператора (Шаг 4) |
| `SERVER_ROLE` | нет | из `vpn.server_role` | `ru-server` / `foreign-server`. Источник правды для протокола и guard'а. Если null — спрашиваю |
| `INBOUND_FLOW` | нет | `xtls-rprx-vision` для reality / пусто для tcp | Flow для VLESS |
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
#   ru-server      → vless-tcp   (вход внутри РФ, TSPU не пересекается, Reality НЕ нужен)
#   foreign-server → vless-reality (трансграничный вход, маскировка обязательна)
if [ -z "${INBOUND_PROTOCOL:-}" ]; then
    case "$SERVER_ROLE" in
        ru-server)      INBOUND_PROTOCOL="vless-tcp" ;;
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
- `ru-server` → **VLESS-TCP** (вход внутри РФ, TSPU не пересекается — маскировка штатно не нужна).
- `foreign-server` → **VLESS+Reality** (трансграничный вход; генерирует keypair, выбирает shortId).

**Если `SERVER_ROLE` пуст** (роль не зафиксирована — старый конфиг или установка
панели вне скилла) — `INBOUND_PROTOCOL` пуст, и я **НЕ угадываю**. Применяю
сеньор-обёртку и спрашиваю оператора прямым вопросом: «Сервер с панелью — в РФ или
за границей?» По ответу выставляю `SERVER_ROLE` и протокол, **и дописываю
`vpn.server_role` в конфиг** (чтобы впредь не спрашивать). Дефолт при сомнении —
`ru-server` + `vless-tcp`.

Запуск скрипта **всегда** с `SERVER_ROLE`:

```bash
SERVER_ROLE="$SERVER_ROLE" \
INBOUND_PROTOCOL="$INBOUND_PROTOCOL" \
INBOUND_LISTEN_PORT="$INBOUND_PORT" \
... ./scripts/create-vless-inbound.sh
```

> 🧑‍🏫 **Reality на РФ-сервере — менторская развилка, не запрет.** Дефолт для
> `ru-server` — `vless-tcp` (внутри РФ TSPU не пересекается, маскировать нечего).
> Если оператор осознанно хочет Reality на РФ-inbound (эксперимент/учёба) — не
> обрываю, объясняю почему обычно не нужно, уточняю «точно хочешь?», и при
> подтверждении повторяю запуск с `CONFIRM_REALITY_ON_RU=yes`. Guard в
> `create-vless-inbound.sh` (exit 3) ловит только СЛУЧАЙНУЮ подстановку. Полный
> менторский сценарий — `references/pitfalls.md`; рефлекс персоны 3.8.5.

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

**5A.3 — Выбор пресета (стабильность vs живучесть).**
Спросить (лишний вопрос не повредит, если объяснён):
- **Пресет «одна страна + авто-failover» (рекомендуемый дефолт):** завести все
  сервера выбранной страны как outbound, собрать в `leastPing`-балансир с
  `probeInterval=5m`. Объяснить: «Работать будешь в основном с одного, самого
  быстрого. Если он упадёт — незаметно переедешь на соседний, но страна та же,
  аккаунт не пострадает. IP скакать не будет — переоценка редкая.»
- **Пресет «один фиксированный сервер»:** если оператору критичен абсолютно
  неизменный IP — завести ОДИН сервер выбранной страны, без балансира.
  Объяснить минус: «Упадёт — переключим вручную.»
- **Пресет «разные страны / самый быстрый пинг любой ценой» (только осознанно):**
  балансир из серверов РАЗНЫХ стран. **Дефолтом НЕ предлагать, по своей инициативе
  НЕ собирать** (рефлекс 3.8.6): скачущий IP = бан антифродом нейросетей (смена
  страны в сессии = паттерн угона аккаунта). Если оператор просит сам — войти в роль
  ментора и проговорить риск дословно (полный текст — `references/pitfalls.md`),
  уточнить «это для нейронок или другого трафика?», при осознанном согласии —
  `CONFIRM_MULTI_COUNTRY=yes` на Шаге 6. **Запрет:** не повторять ложь «балансир
  между странами не влияет на блокировки» (приоритет №1 CLAUDE.md — фактически неверна).

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

> 🧭 **Стратегия балансира — что выбирать.** Дефолт `leastPing` + `probeInterval=5m`
> + сервера одной страны = стабильный IP в норме, авто-failover при падении, страна
> не меняется. НЕ использовать `random`/`roundRobin` (размазывают трафик = скачущий
> IP). Sticky-порог «N мс разницы» в панели 3X-UI ОТСУТСТВУЕТ — это клиентская
> настройка sing-box (`urltest.tolerance`), не серверная (см. `3x-ui-panel.md` §1.3).
> Если выбран пресет «один сервер» (Шаг 5A.3) — `USE_BALANCER=no`, балансир не
> создаётся, default-правило шлёт на единственный outbound.

Создаёт `routing.rules` по модели **«золотая середина»** — те же 7 правил, что
перечислены в `<goals>` (порядок сверху вниз, первое совпавшее применяется; эталон
`16-ЭТАЛОН-гибкой-маршрутизации-3xui.md` §2.5). Ключевое: `geoip:private`→direct
отдельным приоритетным правилом (не в куче с РФ); реклама (`category-ads-all`) и
bittorrent → blocked; РФ ловится `geoip:ru` + `category-ru` + regex `.ru/.su/.рф`
(`.рф` в punycode `xn--p1ai`). **Явный список РФ-доменов на не-РФ TLD НЕ добавляется**
(топ-сервисы на РФ-IP, ловятся `geoip:ru`; домены вроде `tinkoff.com` выдуманы —
§2.6). Скрипт гарантирует наличие outbound `direct` (freedom) и `blocked` (blackhole).

При `leastPing`/`leastLoad` — добавляется observatory с
`probeUrl=http://www.google.com/gen_204` и `probeInterval=$PROBE_INTERVAL`
(по умолчанию `5m` — реже переоценка, стабильнее IP; НЕ устаревший `pingConfig`).

`routing.domainStrategy = "IPIfNonMatch"` (включает sniffing-логику).

> Идемпотентность: скрипт перезаписывает `.routing` целиком и доустанавливает
> недостающие outbound `direct`/`blocked`, поэтому повторный запуск приводит
> конфиг к той же эталонной модели.

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

Inventory — в `inventory/hosts/$SERVER_ALIAS/networks.md` добавляется раздел
`## VPN routing` с подразделами:

- **Inbound** — `inbound-$INBOUND_PORT` (vless-`$INBOUND_PROTOCOL`); клиенты + ссылка
  на UUID в `vpn-clients/*.md`.
- **Outbound** — страна выхода `$EXIT_COUNTRY`, пресет `$OUTBOUND_PRESET`; теги
  `upstream-*` (от провайдера ИЛИ свой загр.VPS); файл серверов подписки в
  `shared/vpn-subscriptions/<provider>.json`.
- **Balancer** — `upstream-balancer` (leastPing, observatory probeInterval=5m);
  при пресете `single` балансира нет, один фиксированный outbound.
- **Routing** — модель «золотая середина», 7 правил (перечень — в `<goals>` / Шаг 6).

`infra-config.json` — `vpn.upstream_kind` обновляется (`subscription` /
`self-foreign` / `mixed`).

## Шаг 10: Финальный отчёт

```
✓ Inbound создан/использован: id=$INBOUND_ID, port=$INBOUND_PORT, protocol=$INBOUND_PROTOCOL
✓ Сервера подписки сохранены: $INFRA/inventory/shared/vpn-subscriptions/$PROVIDER_SLUG.json
✓ Страна выхода: $EXIT_COUNTRY, пресет: $OUTBOUND_PRESET
✓ Outbounds: $UPSTREAM_COUNT штук (только страны $EXIT_COUNTRY), kind=$OUTBOUND_KIND
✓ Balancer: $BALANCER_STRATEGY, probeInterval=$PROBE_INTERVAL (если пресет country-failover)
✓ Routing: 7 правил (private→direct, реклама/bittorrent→block, geoip:ru + category-ru + regex→direct, остальное→upstream)
✓ Клиентов: $CLIENT_COUNT
✓ Inventory обновлён: $INFRA/inventory/hosts/$SERVER_ALIAS/networks.md
✓ Config обновлён: vpn.upstream_kind=$OUTBOUND_KIND

🔍 Smoke check: открой панель $PANEL_URL (видны новые inbound/outbound/clients) →
  выпусти ссылку клиента через /generate-client-config → импортируй в Happ/Hiddify →
  проверь на 2ip.ru (РФ-сайты → твой РФ-IP, зарубежные → IP upstream; реклама режется).

➡️  Следующий шаг (опционально): `/generate-client-config` для генерации
    QR-кодов и sing-box JSON для клиентских устройств.
```

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
  пересекается, маскировать нечего; дефолт `vless-tcp`. Reality на РФ — только по
  осознанному `CONFIRM_REALITY_ON_RU=yes` после менторского объяснения. Guard в
  `create-vless-inbound.sh` (exit 3) ловит случайную подстановку. Рефлекс 3.8.5.
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

# Связанные документы

- `/extract-subscription-servers` — извлечение серверов из подписки (в т.ч.
  закрытых HWID-locked). Запускается ДО этого скилла, сохраняет сервера в infra.
- `references/multi-hop-architectures.md` — два пути outbound + гибрид.
- `decisions/0010-hwid-locked-subscriptions.md` — решение по HWID-замку и слотам.
- `../../knowledge/networking/_reference/vpn-protocols.md` §4 — теория multi-hop.
- `../../knowledge/networking/_reference/3x-ui-api.md` §6 — outbounds + routing через API.
- `../../knowledge/networking/_reference/3x-ui-panel.md` §1.3-1.4 — balancers + observatory.
- `decisions/0005-vpn-architecture.md` §3 — архитектурное решение.
- `references/pitfalls.md` — полный список грабель и граничных случаев.
