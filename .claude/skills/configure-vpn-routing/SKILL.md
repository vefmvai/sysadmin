---
name: configure-vpn-routing
description: |
  Настройка VPN-маршрутизации на установленной панели 3X-UI: создание inbound
  для клиентов (VLESS-TCP для ru-server, VLESS+Reality для foreign-server),
  outbound через подписку платного провайдера (сервера берутся из уже извлечённого
  `/extract-subscription-servers` JSON в infra — этот скилл извлечением НЕ занимается;
  оператор выбирает страну выхода и пресет «одна страна + авто-failover» или «один
  фиксированный сервер») ИЛИ через свой
  загр.VPS — оба пути равноправны; balancer leastPing + observatory
  (probeInterval=5m для стабильного IP) для нескольких outbound, routing rules по
  модели «золотая середина» (7 правил: private→direct, реклама→block,
  bittorrent→block, geoip:ru→direct, category-ru+regex→direct, остальное→upstream),
  массовое добавление клиентов с UUID. Использует REST API панели как основной путь.
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
- В `sysadmin-config.json` секция `vpn` с `panel_url`, `panel_web_base_path`.
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
- `sysadmin-config.json` обновлён: `vpn.upstream_kind` соответствует выбору.
</goals>

# Параметры

| Параметр | Required | Default | Описание |
|---|---|---|---|
| `SERVER_ALIAS` | да | — | Имя сервера для menager паролей и inventory |
| `PANEL_DOMAIN`, `PANEL_PORT`, `WEB_BASE_PATH` | да | из `vpn.*` в config | Параметры панели |
| `ADMIN_LOGIN`, `PASSWORD_REF` | да | автодетект из menager | Креды панели |
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

Скилл — STRICT-режим: без `sysadmin-config.json` он не запускается. Конфиг
обязан содержать секцию `vpn.*` с `panel_url` и `panel_web_base_path` —
без них непонятно, к какой панели обращаться, и кредам в менеджере паролей
неоткуда взяться. Эта проверка выполняется **до** Шага 0 (Pre-check).

Используй общий helper `_lib/find-config.sh` (единая точка изменения для всех
STRICT/OPTIONAL скиллов — алгоритм идентичен Cold Start Protocol персоны).
`$SYSADMIN_ROOT` запоминается на Шаге 1 Cold Start.

```bash
source "$SYSADMIN_ROOT/.claude/skills/_lib/find-config.sh"

# STRICT: exit 1 если конфига нет
find_sysadmin_config strict

# vpn.panel_url и vpn.panel_web_base_path обязательны
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
SECRETS_MANAGER=$(get_config_field secrets.manager keychain)
REPORT_LANGUAGE=$(get_config_field language ru)

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

Сеньор-обёртка (раздел 4.3 персоны). См. `references/multi-hop-architectures.md`
для двух путей.

1. **Контекст**: «У тебя есть подписка платного VPN-провайдера, свой
   заграничный VPS, или ты хочешь оба?»
2. **Мини-урок**: «Путь A (подписка): минимум усилий, провайдер сам
   адаптируется к РКН. Путь B (свой загр.VPS): полный контроль, но больше
   инфраструктуры. Гибрид: свой как основной + подписка как fallback.»
3. **Варианты с плюсами и минусами**.
4. **Рекомендация**: при сомнениях — Путь A.
5. **Разрешение довериться**.
6. **Открытая дверь**: «Подробнее в `multi-hop-architectures.md`».

## Шаг 2: Брифинг 6 пунктов (Yellow Zone)

1. **ЧТО ДЕЛАЮ**: создаю inbound `vless-$INBOUND_PROTOCOL` на $INBOUND_PORT,
   $UPSTREAM_COUNT outbound из $OUTBOUND_KIND, $CLIENT_COUNT клиентов,
   routing по «золотой середине» (7 правил: private→direct, реклама/bittorrent→block,
   geoip:ru + category-ru + regex→direct, остальное → $UPSTREAM_REF).
2. **ЗАЧЕМ**: чтобы клиенты могли подключаться через панель и ходить
   в свободный интернет, при этом РФ-трафик идёт напрямую (быстрее, и РФ-сайт
   видит российский IP — не банит как VPN-юзера), а реклама режется.
3. **ЧТО ПРОИЗОЙДЁТ**: ~30-60 секунд изменений через API + restart Xray
   (1-2 секунды simulationperia, не рвёт активные TCP-сессии).
4. **ЧТО ПРОВЕРИЛ**: пре-чек прошёл, ссылки распарсились корректно.
5. **РИСК + ОТКАТ**: если что-то пойдёт не так — восстановление xray-конфига
   из бэкапа (`api_get_xray_config` сохраняется до изменений).
6. **СТРАХОВКА**: после изменений — `list_inbounds` для проверки + ручной
   smoke check (подключение клиента и `curl -I https://2ip.ru`).

## Шаг 3: Получение пароля из menager

Скилл вычисляет `PASSWORD_REF` исходя из `sysadmin-config.json` (`secrets.manager`)
и `SERVER_ALIAS`:

```
keychain → "keychain:3xui-panel-${SERVER_ALIAS}"
pass     → "pass:3xui-panel-${SERVER_ALIAS}"
bw       → "bw:3xui-panel-${SERVER_ALIAS}"
op       → "op:Private/3xui-panel-${SERVER_ALIAS}/password"
```

Login через `api_login` — пароль читается из менеджера автоматически.

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

> 🧑‍🏫 **Reality на РФ-сервере — не запрет, а менторская развилка.** Если оператор
> (или его ученик) хочет Reality на РФ-inbound — например, чтобы поэкспериментировать,
> разобраться, как оно устроено, или под нестандартный кейс — я **не обрываю**
> словами «нет, не буду». Вхожу в роль ментора:
> 1. Объясняю, **почему обычно не нужно**: маршрут внутри РФ не пересекает TSPU,
>    маскировать нечего; штатно хватает VLESS-TCP (заработал бы и WireGuard).
> 2. Уточняю: **«ты точно этого хочешь?»** — это эксперимент/учёба или предполагалось,
>    что так надёжнее?
> 3. Если подтверждает осознанно — создаю: повторяю запуск с
>    `CONFIRM_REALITY_ON_RU=yes`. Решение за оператором, моя работа — чтобы выбор
>    был информированным.
>
> Guard в `create-vless-inbound.sh` ловит только **случайную** подстановку Reality
> на РФ-сервер (выход с кодом 3 = «нужно подтверждение», не ошибка). Это защита от
> повторения инцидента, когда агент сам, без запроса, нацепил Reality — а не запрет
> на осознанный эксперимент. См. рефлекс персоны 3.8.5, `vpn-consultation-flow.md` §4.

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
INFRA_DIR="$(get_config_field infrastructure.root_path)"
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
  направляю оператора:
  > «Чтобы завести сервера твоей подписки в панель, их сначала надо достать из
  > подписки — этим занимается отдельная команда, она проведёт тебя по шагам
  > простым языком: `/extract-subscription-servers`. Запусти её, а потом вернёмся
  > сюда — я заведу сервера в панель и настрою маршрутизацию.»
  >
  > Это особенно важно для закрытых подписок (Panterra, NurVPN): там нужен
  > «отпечаток устройства» и иногда — освободить слот; всё это `/extract-subscription-servers`
  > делает «под ключ». См. ADR-0010.

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
   прыжки между странами.» Ученик отвечает, например, «США».
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
- **Пресет «один фиксированный сервер»:** если ученику критичен абсолютно
  неизменный IP — завести ОДИН сервер выбранной страны, без балансира.
  Объяснить минус: «Упадёт — переключим вручную.»
- **Пресет «разные страны / самый быстрый пинг любой ценой» (только осознанно):**
  балансир из серверов РАЗНЫХ стран. **Дефолтом НЕ предлагать, по своей инициативе
  НЕ собирать** (рефлекс персоны 3.8.6). Если оператор просит сам — войти в роль
  ментора и проговорить риск дословно: «IP будет прыгать между странами. Для
  антифрода нейросетей (OpenAI/Anthropic/Google) смена страны внутри сессии =
  паттерн угона аккаунта → капчи, верификация, бан. Скачущий IP не обходит
  блокировку — он сам её триггер. Это годится ТОЛЬКО если ты НЕ работаешь через
  этот VPN с нейронками.» Уточнить: «это для нейронок или для другого трафика?».
  При осознанном согласии — на Шаге 6 добавить `CONFIRM_MULTI_COUNTRY=yes`.
  **Запрет:** не повторять ложь «балансир между странами не влияет на блокировки»
  (приоритет №1 CLAUDE.md — она фактически неверна).

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
> >1 страны (или не передан вовсе) — `setup-routing.sh` делает **exit 3** с
> менторским объяснением и НЕ собирает балансир. Это защита от «скачущего IP по
> странам» = бана нейросетей. Обойти можно ТОЛЬКО осознанно — пресет «разные
> страны» из Шага 5A.3, с проговорённым риском и `CONFIRM_MULTI_COUNTRY=yes`:
> ```bash
> UPSTREAM_TAGS_JSON='["upstream-us","upstream-de"]' \
> UPSTREAM_COUNTRIES_JSON='["us","de"]' \
> CONFIRM_MULTI_COUNTRY=yes \
> BALANCER_STRATEGY=leastPing PROBE_INTERVAL=5m \
> ./scripts/setup-routing.sh
> ```
> Симметрично `CONFIRM_REALITY_ON_RU` в `create-vless-inbound.sh`. См. рефлекс
> персоны 3.8.6 и ADR-0011.

> 🧭 **Стратегия балансира — что выбирать.** Дефолт `leastPing` + `probeInterval=5m`
> + сервера одной страны = стабильный IP в норме, авто-failover при падении, страна
> не меняется. НЕ использовать `random`/`roundRobin` (размазывают трафик = скачущий
> IP). Sticky-порог «N мс разницы» в панели 3X-UI ОТСУТСТВУЕТ — это клиентская
> настройка sing-box (`urltest.tolerance`), не серверная (см. `3x-ui-panel.md` §1.3).
> Если выбран пресет «один сервер» (Шаг 5A.3) — `USE_BALANCER=no`, балансир не
> создаётся, default-правило шлёт на единственный outbound.

Создаёт `routing.rules` по модели **«золотая середина»** (7 правил, порядок
сверху вниз — первое совпавшее применяется; см. эталон
`16-ЭТАЛОН-гибкой-маршрутизации-3xui.md` §2.5):

1. `inboundTag=api` → `api` (служебное).
2. `ip=geoip:private` → `direct` (локальная сеть; **НЕ blocked**).
3. `protocol=bittorrent` → `blocked`.
4. `domain=geosite:category-ads-all` → `blocked` (реклама раньше РФ-правил).
5. `ip=geoip:ru` → `direct` (ловит топ-РФ-сервисы по IP — банки/госуслуги/маркетплейсы
   на российских ASN).
6. `domain=[geosite:category-ru, regexp:.+\.ru$, regexp:.+\.su$, regexp:.+\.xn--p1ai$]`
   → `direct` (свежие РФ-домены по TLD; `.рф` пишется в punycode).
7. default (`inboundTag`=все vless/mixed inbounds) → `balancerTag=upstream-balancer`
   (или `outboundTag`=единственный upstream).

**Явный список РФ-доменов на не-РФ TLD НЕ добавляется** — research показал, что
топ-сервисы все на российских IP и ловятся правилом 5 (`geoip:ru`), а домены
вроде `tinkoff.com` выдуманы (эталон §2.6). Скрипт также гарантирует наличие
outbound `direct` (freedom) и `blocked` (blackhole) — последний нужен для правил
3 и 4.

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

Inventory:

```markdown
# inventory/hosts/$SERVER_ALIAS/networks.md (раздел добавляется)

## VPN routing

### Inbound
- `inbound-443` (vless-${INBOUND_PROTOCOL}, port=$INBOUND_PORT)
- Клиенты: 4 (alice, bob, mum, work-laptop) — UUID в `vpn-clients/*.md`

### Outbound
- Страна выхода: США (выбрана оператором). Пресет: country-failover.
- `upstream-us-1`, `upstream-us-2`, `upstream-us-3` (от провайдера X / 3 сервера США)
  ИЛИ
- `upstream-myhetzner` (свой загр.VPS)
- Сервера подписки сохранены: `$INFRA/inventory/shared/vpn-subscriptions/<provider>.json`

### Balancer
- `upstream-balancer` (strategy=leastPing, fallback=direct, observatory probeInterval=5m)
  — стабильный IP в норме + авто-failover внутри страны.
  (Пресет single → балансира нет, один фиксированный outbound.)

### Routing (модель «золотая середина», 7 правил)
- Приватные сети (geoip:private) → direct
- Реклама (geosite:category-ads-all) → blocked
- bittorrent → blocked
- РФ-трафик по IP (geoip:ru) → direct
- РФ-домены (geosite:category-ru + regex .ru/.su/.рф) → direct
- Остальное → balancer (или единственный upstream)
```

`sysadmin-config.json` — `vpn.upstream_kind` обновляется (`subscription` /
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

🔍 Smoke check шагов:
  1. Зайди в панель: $PANEL_URL — должны быть видны новые inbound/outbound/clients.
  2. Возьми vless://-ссылку для одного из клиентов через `/generate-client-config`.
  3. Импортируй в Hiddify/Karing на телефоне.
  4. Проверь на 2ip.ru: РФ-сайты → твой РФ-IP; зарубежные → IP upstream-сервера.
  5. Реклама на страницах должна резаться (правило category-ads-all → blocked).

➡️  Следующий шаг (опционально): `/generate-client-config` для генерации
    QR-кодов и sing-box JSON для клиентских устройств.
```

# Откат

Бэкап xray-конфига сохраняется до изменений. При сбое:

```bash
# Получаем бэкап (если сохранили перед началом)
ssh $SSH_TARGET "cp /etc/x-ui/x-ui.db.backup.<timestamp> /etc/x-ui/x-ui.db && systemctl restart x-ui"
```

Или восстановление через API:
```bash
# Если есть сохранённый JSON-конфиг до изменений
api_update_xray_config "$BACKUP_CONFIG_JSON"
api_restart_xray
```

# Failed attempts (граблекейс)

- **Поиск sticky-порога «N мс разницы» в панели 3X-UI** — его ТАМ НЕТ. Форма
  балансировщика в 3X-UI имеет только 4 поля (tag/strategy/selector/fallbackTag),
  Observatory-редактор не содержит порога-гистерезиса в миллисекундах (проверено
  в исходнике `BalancersTab.tsx`, 2026-05-24). Настройка «toleration/Latency»
  (держись за сервер, пока он не станет хуже на N мс) существует ТОЛЬКО на клиенте
  (sing-box `urltest.tolerance`). НЕ вписывать несуществующее поле в серверный
  балансир (правило №1 CLAUDE.md). Стабильность IP на сервере = «одна страна в
  selector» + `probeInterval=5m` + при необходимости один сервер. См.
  `3x-ui-panel.md` §1.3.
- **Заведение ВСЕХ серверов подписки в один балансир скопом** — даёт «скачущий IP
  по странам» = бан аккаунта. Опасны ДВА детектора: (1) платформы РФ-2026 детектят
  прыжки; (2) — главное — **антифрод нейросетей (OpenAI/Anthropic/Google)**: смена
  страны внутри сессии = паттерн угона аккаунта → капчи, верификация, бан. Скачущий
  IP не обходит блокировку, а сам её триггерит. Правильно: сохранить все в infra, но
  в outbound завести ТОЛЬКО выбранную оператором страну (Шаг 5A.2–5A.3).
  **С v1.8.0 это enforced кодом:** `setup-routing.sh` при >1 страны в
  `UPSTREAM_COUNTRIES_JSON` (или при его отсутствии) делает exit 3 без
  `CONFIRM_MULTI_COUNTRY=yes`. Свободный разговор мимо скилла ловит рефлекс персоны
  3.8.6. Инцидент-первопричина: агент посоветовал ученику балансир между странами
  со словами «не влияет на блокировки нейронок» (ложь). См. ADR-0011 и
  `../../knowledge/networking/_reference/vpn-consultation-flow.md` §9.1.
- **VLESS+Reality на РФ-сервере для входа клиентов** — штатно избыточно (не
  запрещено). Маршрут «клиент в РФ → сервер в РФ» не пересекает TSPU, маскировка
  обычно ни от чего не защищает (заработал бы и WireGuard). Дефолт для `ru-server`
  inbound — `vless-tcp`. Reality на РФ-сервере создаётся только по осознанному
  подтверждению (`CONFIRM_REALITY_ON_RU=yes`) после менторского объяснения — для
  эксперимента/учёбы это нормально. Guard в `create-vless-inbound.sh` (exit 3 без
  подтверждения) ловит только СЛУЧАЙНУЮ подстановку, не осознанный выбор.
  Наблюдённый инцидент (2026-05): агент в свободном режиме сам, без запроса,
  создал Reality-inbound на РФ-сервере, сбив оператора. См. рефлекс персоны 3.8.5.
- **`outbound` правится через прямое CRUD-API** — НЕТ такого. Outbound редактируются
  только через `getXrayConfig` / `updateXrayConfig` (см. `3x-ui-api.md` §6.1).
- **«Сохранить» в UI не нажали** — изменения через API панель применяет сама,
  но **restart Xray** должен быть явный (`api_restart_xray`).
- **`leastPing` без observatory** — не работает. Скилл всегда добавляет observatory
  для этой стратегии.
- **`pingConfig` в balancer** — устаревшее имя, в современном Xray поле называется
  `observatory.probeInterval` + `observatory.probeUrl`.
- **Reality privateKey передан клиенту** — НИКОГДА. Клиенту даётся publicKey
  (см. `add-outbound-from-vless.sh` — privateKey хранится на сервере, в vless://
  идёт только pbk = publicKey).
- **Маршрутизация после restart не работает** — проверить `domainStrategy` в
  routing: должно быть `"IPIfNonMatch"`, не `"AsIs"`. Это включает sniffing.
- **Sniffing не включён на inbound** — domain-based routing не работает (геосайты
  не сматчатся). Скилл всегда включает `sniffing: { enabled: true,
  destOverride: ["http","tls","quic"] }` (и на vless-, и на mixed-inbound).
- **Одно объединённое direct-правило (geoip:ru+category-ru+private → direct)** —
  старая модель скилла (до 24 мая). Проблемы: (1) `geoip:private` мешался в одну
  кучу с РФ-правилами вместо отдельного приоритетного правила; (2) не было блока
  рекламы (`category-ads-all`) и bittorrent; (3) не было punycode-regex для `.рф`.
  Заменено на 7-правильную модель «золотая середина» (эталон §2.5). Реклама режется,
  приватные сети в отдельном правиле №2, РФ-сервисы ловятся `geoip:ru` (явный список
  доменов НЕ нужен — §2.6 эталона: домены типа `tinkoff.com` выдуманы).
- **`regexp:.*\\\\.ru$` (четыре бэкслеша в jq-программе)** — баг старого скрипта.
  В JSON это давало `regexp:.*\\.ru$`, а Xray интерпретировал `\\.` как «литеральный
  бэкслеш + любой символ» — regex не матчил реальные домены. Правильно: **два
  бэкслеша** в jq-источнике (`regexp:.+\\.ru$`), что даёт JSON `regexp:.+\\.ru$`
  и рантайм-regex `regexp:.+\.ru$` (литеральная точка). Совпадает с эталоном §4.1.

# Граничные случаи

- **Сервера ещё не извлечены из подписки** (нет файла
  `$INFRA/inventory/shared/vpn-subscriptions/<provider>.json`) → НЕ извлекать здесь.
  Направить оператора на `/extract-subscription-servers` (он делает извлечение
  «под ключ»: форматы, HWID-замок, слоты), потом вернуться сюда. См. Шаг 5A.1.
- **Подписка закрытая/зашифрованная** (Panterra, NurVPN — заглушка вместо серверов,
  HWID-замок) → это целиком зона `/extract-subscription-servers` (ADR-0010). Здесь
  не дублируется. configure-vpn-routing работает только с уже извлечённым JSON.
- **Reality dest валидируется при self-foreign** → если `parse-vless-link.sh`
  получил `serverName` с подсанкционным доменом или TLS 1.2 only — предупредить
  оператора (но не fail, провайдер мог использовать что-то нетривиальное).
- **Inbound уже существует** → скилл предлагает использовать существующий
  (не пересоздавать) и переходит к outbound.
- **Outbound уже существует с тем же tag** → скилл идемпотентно перезаписывает
  (см. `add-outbound-from-vless.sh` — `outbounds |= map(select(.tag != $tag))`
  перед добавлением).
- **Конфликт inboundTag в routing** → скилл при `setup-routing.sh` берёт все
  vless-inbound из `list`, не хардкодит. Если нужно ограничить — передать
  `INBOUND_TAGS_JSON='["inbound-443"]'`.
- **Cloudflare proxy включён на A-записи серверного inbound** → клиенту cert
  не валидируется, Reality не сработает. Решение: отключить proxy (серое
  облако) для VPN-домена.
- **Страна сервера = `?`** (тег без флага/текста) → `/extract-subscription-servers`
  НЕ выдумывает страну при разметке. Определить по гео-IP хоста
  (`curl -s ipinfo.io/<host>/country`) или честно спросить оператора. Не
  подставлять «правдоподобную» страну (правило №1).
- **Оператор хочет страну, которой нет в подписке** → честно сказать: «В твоей
  подписке нет серверов в <стране>. Есть: <список>.» Не выдумывать сервер.

# Связанные документы

- `/extract-subscription-servers` — извлечение серверов из подписки (в т.ч.
  закрытых HWID-locked). Запускается ДО этого скилла, сохраняет сервера в infra.
- `references/multi-hop-architectures.md` — два пути outbound + гибрид.
- `scripts/parse-vless-link.sh` — разбор одного vless://-link (для self-foreign и add-outbound).
- `decisions/0010-hwid-locked-subscriptions.md` — решение по HWID-замку и слотам.
- `../../knowledge/networking/_reference/vpn-protocols.md` §4 — теория multi-hop.
- `../../knowledge/networking/_reference/3x-ui-api.md` §6 — outbounds + routing через API.
- `../../knowledge/networking/_reference/3x-ui-panel.md` §1.3-1.4 — balancers + observatory.
- `decisions/0005-vpn-architecture.md` §3 — архитектурное решение.
- `evals/triggers.md` — фразы оператора.
