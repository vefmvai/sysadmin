---
name: configure-vpn-routing
description: |
  Настройка VPN-маршрутизации на установленной панели 3X-UI: создание inbound
  для клиентов (VLESS-TCP для ru-server, VLESS+Reality для foreign-server),
  outbound (через подписку платного провайдера ИЛИ через свой загр.VPS —
  оба пути равноправны), balancer + observatory для нескольких outbound,
  routing rules (geoip:ru → direct, остальное → upstream), массовое
  добавление клиентов с UUID. Использует REST API панели как основной путь.
  Триггеры: «настрой маршрутизацию VPN», «добавь клиента», «настрой VLESS
  на панели», «семье нужен VPN», «outbound через подписку», «мульти-хоп
  через свой загр.VPS», «configure-routing», «добавь второй сервер в balancer».
  НЕ для установки панели — `/setup-vpn-panel`. НЕ для серверного прокси —
  `/setup-server-proxy`. НЕ для клиентских конфигов — `/generate-client-config`.
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
- Создан 1+ outbound: либо `OUTBOUND_KIND=subscription` (один на каждую
  ссылку из подписки), либо `OUTBOUND_KIND=self-foreign` (один с параметрами
  от своего загр.VPS).
- Если outbound > 1 — создан balancer со стратегией `leastPing` + observatory.
- Routing rules: `geoip:ru` + `geosite:category-ru` + `geoip:private` → direct;
  всё остальное → upstream (balancer или один outbound).
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
| `SUBSCRIPTION_URL` | условно | — | Для `OUTBOUND_KIND=subscription` |
| `UPSTREAM_VPN_URL` | условно | — | Прямой vless://-link (вместо subscription URL или для `self-foreign`) |
| `INBOUND_PORT` | нет | `443` | Порт inbound на сервере |
| `INBOUND_PROTOCOL` | нет | по `LOCATION` из config | `vless-tcp` (ru) / `vless-reality` (foreign) |
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
   routing geoip:ru → direct + остальное → $UPSTREAM_REF.
2. **ЗАЧЕМ**: чтобы клиенты могли подключаться через панель и ходить
   в свободный интернет, при этом РФ-трафик идёт напрямую (быстрее).
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
создаёт inbound:
- VLESS-TCP для ru-server.
- VLESS+Reality для foreign-server (генерирует keypair, выбирает shortId).

При создании — сразу один client_uuid для первичного клиента (имя из
`CLIENT_NAMES[0]` или `admin`).

## Шаг 5: Outbound — два пути

### Путь A: subscription

```bash
SUBSCRIPTION_URL=... ./scripts/parse-subscription.sh > /tmp/subs.json
# /tmp/subs.json — JSON-массив объектов vless

for vless in $(jq -c '.[]' /tmp/subs.json); do
    VLESS_JSON="$vless" ./scripts/add-outbound-from-vless.sh
done
```

Если в подписке 5 серверов — будет 5 outbound с tag вида
`upstream-<slug-of-tag>`.

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
UPSTREAM_TAGS_JSON='["upstream-de","upstream-nl","upstream-fi"]' \
BALANCER_STRATEGY=leastPing \
./scripts/setup-routing.sh
```

Создаёт routing.rules:
1. `geoip:ru + geosite:category-ru + geoip:private → direct`.
2. `все vless-inbounds → balancerTag=upstream-balancer` (или единственный upstream).

При `leastPing`/`leastLoad` — добавляется observatory с probeUrl и probeInterval=30s.

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
- `upstream-de`, `upstream-nl`, `upstream-fi` (от провайдера X / 3 сервера)
  ИЛИ
- `upstream-myhetzner` (свой загр.VPS)

### Balancer
- `upstream-balancer` (strategy=leastPing, fallback=direct, observatory enabled)

### Routing
- РФ-трафик (geoip:ru + geosite:category-ru) → direct
- Приватные сети (geoip:private) → direct
- Остальное → balancer
```

`sysadmin-config.json` — `vpn.upstream_kind` обновляется (`subscription` /
`self-foreign` / `mixed`).

## Шаг 10: Финальный отчёт

```
✓ Inbound создан/использован: id=$INBOUND_ID, port=$INBOUND_PORT, protocol=$INBOUND_PROTOCOL
✓ Outbounds: $UPSTREAM_COUNT штук, kind=$OUTBOUND_KIND
✓ Balancer: $BALANCER_STRATEGY (если применимо)
✓ Routing: geoip:ru → direct, остальное → upstream
✓ Клиентов: $CLIENT_COUNT
✓ Inventory обновлён: $INFRA/inventory/hosts/$SERVER_ALIAS/networks.md
✓ Config обновлён: vpn.upstream_kind=$OUTBOUND_KIND

🔍 Smoke check шагов:
  1. Зайди в панель: $PANEL_URL — должны быть видны новые inbound/outbound/clients.
  2. Возьми vless://-ссылку для одного из клиентов через `/generate-client-config`.
  3. Импортируй в Hiddify/Karing на телефоне.
  4. Проверь на 2ip.ru: РФ-сайты → твой РФ-IP; зарубежные → IP upstream-сервера.

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
  destOverride: ["http","tls","quic"] }`.

# Граничные случаи

- **Подписка отдаёт sing-box JSON, не xray** → сменить `USER_AGENT` в
  `parse-subscription.sh` на `v2rayN/6.42 (Windows; X64)`. Если провайдер
  всё равно отдаёт sing-box → попросить у провайдера прямой vless://-link
  и подать через `UPSTREAM_VPN_URL`.
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

# Связанные документы

- `references/multi-hop-architectures.md` — два пути outbound + гибрид.
- `references/subscription-formats.md` — форматы подписок провайдеров.
- `../../knowledge/networking/_reference/vpn-protocols.md` §4 — теория multi-hop.
- `../../knowledge/networking/_reference/3x-ui-api.md` §6 — outbounds + routing через API.
- `../../knowledge/networking/_reference/3x-ui-panel.md` §1.3-1.4 — balancers + observatory.
- `decisions/0005-vpn-architecture.md` §3 — архитектурное решение.
- `evals/triggers.md` — фразы оператора.
