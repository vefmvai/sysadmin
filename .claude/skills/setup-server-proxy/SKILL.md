---
name: setup-server-proxy
description: |
  Настройка серверного прокси: создание mixed inbound (SOCKS5+HTTP)
  на 127.0.0.1:1080 в существующей панели 3X-UI (со sniffing — иначе
  domain-правила для серверных программ мертвы), маршрутизация через
  VPN-outbound по модели «золотая середина» (private→direct, реклама→block,
  geoip:ru + category-ru + regex→direct, остальное→upstream),
  systemd drop-in override для x-ui (КРИТИЧНО — без него self-loop через
  /etc/environment ломает панель), запись socks5h://-переменных
  в /etc/environment. Финальный smoke-test (api.anthropic.com через прокси,
  ya.ru напрямую). Цель — дать программам на сервере (боты, npm, pip, curl,
  git) доступ к заблокированным API через VPN, без касания UI/настроек
  каждой программы отдельно.
  Триггеры: «настрой прокси на сервере», «бот не видит Anthropic API»,
  «npm не качает», «pip не работает», «бот возвращает 403 от Anthropic»,
  «git push с сервера не работает», «curl таймаутит на api.anthropic.com»,
  «дай серверу доступ к заблокированным API».
  НЕ для установки панели — `/setup-vpn-panel`. НЕ для добавления клиентов
  устройствам — `/configure-vpn-routing`. НЕ для генерации клиентских конфигов —
  `/generate-client-config`.
allowed-tools: Bash, Read, Edit, Write
---

<role>
Я настраиваю серверный прокси на VPS оператора — даю программам, которые
живут на этом сервере (боты, скрипты, CI, пакетные менеджеры), доступ
к заблокированным API через тот же VPN-стек, что используют клиентские
устройства. Главная операционная ценность — автоматизация защиты от
self-loop, на котором ломается панель 3X-UI без правильной настройки.
</role>

<context>
Предполагается:
- 3X-UI установлен и работает (через `/setup-vpn-panel`).
- На панели уже есть outbound с VPN-сервером (через `/configure-vpn-routing`).
- В `sysadmin-config.json` секция `vpn` с `panel_url`, `panel_web_base_path`,
  `upstream_kind` ≠ `none`.
- Креды панели в менеджере паролей под `3xui-panel-${SERVER_ALIAS}`.
- ssh доступен из cwd (через SSH-alias или host).

НЕ предполагается:
- Знание операторами Privoxy / proxychains. Скилл настраивает только базовый
  SOCKS5+HTTP-прокси через панель.
- Поддержка нескольких mixed inbound на одной панели — один на серверный прокси,
  идемпотентно.
</context>

<goals>
После выполнения должно стать TRUE:
- systemd drop-in override `/etc/systemd/system/x-ui.service.d/override.conf`
  с очисткой HTTP_PROXY/HTTPS_PROXY/NO_PROXY.
- Mixed inbound на 127.0.0.1:1080 (или передан другой PROXY_PORT) в панели,
  protocol=mixed, no auth, udp=false, **sniffing ENABLED**
  (destOverride: http/tls/quic — иначе domain-правила для серверных программ мертвы).
- Routing rules для `inboundTag=mixed-server-proxy` по модели «золотая середина»
  (6 правил, scoped на mixed-inbound, порядок сверху вниз):
  1. `geoip:private` → direct;
  2. `bittorrent` → blocked;
  3. `geosite:category-ads-all` → blocked (реклама);
  4. `geoip:ru` → direct;
  5. `geosite:category-ru` + regex `.ru/.su/.рф` → direct;
  6. default (этот inbound) → upstream (balancer или один outbound).
- `/etc/environment` обновлён: `http_proxy`, `https_proxy`, `no_proxy` (+ uppercase)
  с `socks5h://127.0.0.1:1080`.
- Smoke check: `curl https://api.anthropic.com` через свежий SSH → HTTP/2;
  `curl https://ya.ru` → HTTP/2; панель 3X-UI открывается в браузере.
- `sysadmin-config.json` обновлён: `vpn.server_proxy_enabled=true`.
- Inventory обновлён: блок про server proxy в `networks.md`.
</goals>

# Параметры

| Параметр | Required | Default | Описание |
|---|---|---|---|
| `SSH_TARGET`, `SERVER_ALIAS` | да | — | SSH-цель + имя сервера |
| `PANEL_DOMAIN`, `PANEL_PORT`, `WEB_BASE_PATH` | да | из `vpn.*` в config | Параметры панели |
| `ADMIN_LOGIN`, `PASSWORD_REF` | да | автодетект | Креды панели |
| `PROXY_PORT` | нет | `1080` | Порт mixed inbound |
| `PROXY_LISTEN` | нет | `127.0.0.1` | Listen IP. **НЕ менять на 0.0.0.0** — без auth прокси будет открыт в сеть! |
| `UPSTREAM_REF` | да | автодетект из routing | Тег outbound или balancer, через который идёт upstream-трафик |

# Процедура

## Шаг 0a: Чтение конфига (STRICT)

Скилл — STRICT-режим: без `sysadmin-config.json` он не запускается. Серверный
прокси работает поверх существующей VPN-инфраструктуры — нужны `vpn.panel_url`,
`vpn.panel_web_base_path` и `vpn.upstream_kind ≠ none`. Эта проверка
выполняется **до** запуска `scripts/00-detect-existing.sh`.

Используй общий helper `_lib/find-config.sh` (единая точка изменения для всех
STRICT/OPTIONAL скиллов — алгоритм идентичен Cold Start Protocol персоны).
`$SYSADMIN_ROOT` запоминается на Шаге 1 Cold Start.

```bash
source "$SYSADMIN_ROOT/.claude/skills/_lib/find-config.sh"

# STRICT: exit 1 если конфига нет
find_sysadmin_config strict

# vpn.panel_url + vpn.panel_web_base_path обязательны
require_config_field "vpn.panel_url" \
    "Это значит 3X-UI ещё не установлен. Сначала /setup-vpn-panel, потом /configure-vpn-routing, потом сюда."
require_config_field "vpn.panel_web_base_path" \
    "Это значит 3X-UI ещё не установлен. Сначала /setup-vpn-panel, потом /configure-vpn-routing, потом сюда."

# upstream_kind должен быть задан (≠ none)
UPSTREAM_KIND=$(get_config_field vpn.upstream_kind none)
if [ "$UPSTREAM_KIND" = "none" ]; then
    cat <<EOF >&2
В $CONFIG vpn.upstream_kind=none — нет настроенного upstream-outbound,
через который серверный прокси будет ходить к заблокированным API.

Сначала запусти /configure-vpn-routing для настройки outbound
(subscription или self-foreign), затем возвращайся к /setup-server-proxy.
EOF
    exit 1
fi

# Параметры (CLI override > конфиг)
PANEL_URL=$(get_config_field vpn.panel_url)
PANEL_WEB_BASE_PATH=$(get_config_field vpn.panel_web_base_path)
PANEL_DOMAIN="${PANEL_DOMAIN:-$(echo "$PANEL_URL" | sed -E 's|https?://||; s|:.*$||')}"
PANEL_PORT="${PANEL_PORT:-$(echo "$PANEL_URL" | sed -E 's|https?://[^:]+:||; s|/.*$||')}"
WEB_BASE_PATH="${WEB_BASE_PATH:-$PANEL_WEB_BASE_PATH}"
SECRETS_MANAGER=$(get_config_field secrets.manager keychain)
REPORT_LANGUAGE=$(get_config_field language ru)
```

После успешного чтения переходим к Шагу 0 (детекция существующей установки).

## Шаг 0: Pre-check (Green Zone) — детекция существующей установки

**Запускаю `scripts/00-detect-existing.sh` ПЕРВЫМ.** Скрипт проверяет 4
индикатора на сервере:

- A: `/etc/systemd/system/x-ui.service.d/override.conf` существует с
  `HTTP_PROXY=""`.
- B: `/etc/environment` содержит строки `https_proxy=socks5h://...`.
- C: На панели есть mixed-inbound на 127.0.0.1:1080 (через API или SQLite).
- D: `curl -x socks5h://127.0.0.1:1080 https://www.google.com` отвечает HTTP.

Решение по результату:

- **`ALREADY_INSTALLED` (все 4 TRUE)** → серверный прокси уже настроен и
  работает. STOP. Сообщаю оператору:
  > «Серверный прокси уже работает (127.0.0.1:$PROXY_PORT). Я ничего не
  > трогаю. Если конкретная программа не идёт через прокси (бот, aiohttp,
  > anthropic SDK) — это **troubleshooting библиотеки**, не установки.
  > Скорее всего нужно `trust_env=True` (aiohttp) или явный httpx-клиент
  > (anthropic SDK issue #923 / openai SDK). Подробнее — `.claude/skills/
  > setup-server-proxy/references/python-libs-with-proxy.md`. Хочешь
  > пройти по конкретному кейсу — скажи, какая библиотека и что показывает
  > трассировка.»

- **`PARTIAL` с `recommendation=troubleshoot`** (override и /etc/environment
  есть, но curl не работает) → проблема в текущей установке. Спрашиваю
  оператора: «прокси настроен, но не работает. Это либо upstream-сервер
  лёг, либо панель упала. Запустить `/health-check` для диагностики, или
  предпочитаешь полный rollback и переустановку?»

- **`PARTIAL` с `recommendation=resume`** (часть индикаторов TRUE — например,
  override есть, но inbound не создан) → прерванная сессия. Предлагаю
  оператору: «нашёл частичную установку. Продолжить с того места, где
  остановились, или откатить и поставить заново?»

- **`NOT_INSTALLED` (все 4 FALSE)** → чистая установка. Продолжаю обычным flow.

Дополнительные проверки (выполняются только при `recommendation=install` или
`resume`):

- Панель отвечает: `curl -sI https://$PANEL_DOMAIN:$PANEL_PORT/$WEB_BASE_PATH/` → 200.
- В `vpn.upstream_kind` в config ≠ `none` (иначе нет outbound — некуда маршрутизировать).
- SSH-доступ работает.

## Шаг 1: Брифинг 6 пунктов (Yellow Zone) с критическим предупреждением

1. **ЧТО ДЕЛАЮ**: создаю drop-in override для x-ui (защита от self-loop) →
   mixed inbound на $PROXY_PORT → routing-rules → /etc/environment → smoke test.
2. **ЗАЧЕМ**: программы на сервере (боты, скрипты, pip/npm/git) смогут
   обращаться к заблокированным API (Anthropic, OpenAI, GitHub) через VPN.
3. **ЧТО ПРОИЗОЙДЁТ**: ~30 секунд изменений. Restart x-ui (1-2 сек). Текущие
   SSH-сессии не подхватят новые env-vars — придётся exit + новый ssh.
4. **ЧТО ПРОВЕРИЛ**: панель работает, upstream outbound настроен, prock.port
   свободен на 127.0.0.1.
5. **🔴 КРИТИЧЕСКИЙ РИСК**: без drop-in override для x-ui — самый громкий
   подводный камень VPN-блока — панель уйдёт в петлю при попытке использовать
   собственный mixed inbound как HTTPS_PROXY и упадёт. Этот скилл делает
   override **ПЕРВЫМ шагом** (до правки /etc/environment). Откат при сбое:
   `rm /etc/systemd/system/x-ui.service.d/override.conf && systemctl daemon-reload
   && systemctl restart x-ui` + удаление proxy-строк из /etc/environment.
6. **СТРАХОВКА**: после изменений — smoke check (5 проверок). При FAIL — откат
   через backup /etc/environment.

После брифинга жду «ок».

## Шаг 2: 🔴 Drop-in override (САМЫЙ ВАЖНЫЙ ШАГ)

`scripts/01-systemd-override-xui.sh`:

```
/etc/systemd/system/x-ui.service.d/override.conf:

[Service]
Environment="HTTP_PROXY="
Environment="HTTPS_PROXY="
Environment="NO_PROXY=*"
```

`systemctl daemon-reload && systemctl restart x-ui`.

**Verify**: `systemctl is-active x-ui` → `active`. Если нет — STOP, откат
override и доложить оператору.

## Шаг 3: Mixed inbound (Yellow Zone)

`scripts/02-create-mixed-inbound.sh` через REST API:

- Идемпотентно: проверяет, что mixed inbound на этом порту ещё нет.
- Если есть — пропускает создание, использует существующий.
- Если нет — создаёт с `listen=127.0.0.1`, `port=$PROXY_PORT`, `protocol=mixed`,
  `auth=noauth`, `udp=false`, **sniffing ENABLED** (`{enabled:true,
  destOverride:["http","tls","quic"]}`).

> 🚨 **Sniffing на mixed-inbound 1080 обязателен.** Без него прокси видит только
> IP назначения, и domain-правила (реклама `category-ads-all`, банки/сервисы на
> `.com`) для серверных программ не работают — остаётся лишь грубое деление по
> geoip. На боевом сервере он был ВЫКЛ (баг, эталон §2.2) — скрипт всегда включает.

**Verify**: `api_list_inbounds` показывает новый inbound, `port` совпадает,
`sniffing.enabled=true`.

## Шаг 4: Routing для mixed inbound

`scripts/04-add-proxy-routing.sh`:

- Получает текущий xray-конфиг.
- Гарантирует наличие outbound `blocked` (blackhole) — нужен для правил реклама
  и bittorrent.
- Добавляет **шесть правил** модели «золотая середина», все scoped на
  `inboundTag=mixed-server-proxy` (порядок сверху вниз):
  1. `geoip:private` → direct (локальная сеть; НЕ blocked).
  2. `bittorrent` → blocked.
  3. `geosite:category-ads-all` → blocked (реклама).
  4. `geoip:ru` → direct.
  5. `geosite:category-ru` + regex `.ru/.su/.рф` → direct.
  6. default (этот inbound) → upstream (balancer или single outbound).
- Идемпотентно: удаляет существующие правила с этим inboundTag перед вставкой.
- Вставляет блок **в начало** `routing.rules` — все правила scoped на mixed-inbound,
  поэтому vless-трафика не касаются, а позиция в начале гарантирует корректный
  внутренний порядок (private → ads → ru → default) для серверного прокси.
- Авто-детект: если в текущем routing есть `balancers[]`, использует
  `balancerTag`, иначе `outboundTag`.

**Verify**: `api_get_xray_config` показывает новые правила (6 штук с
`inboundTag=mixed-server-proxy`).

## Шаг 5: /etc/environment

`scripts/03-write-environment.sh`:

- **Pre-check**: убедиться, что drop-in override уже на месте (защита от
  неправильного порядка вызова).
- Бэкап `/etc/environment` с timestamp.
- Удалить существующие http_proxy/https_proxy/no_proxy строки (идемпотент).
- Добавить новые с `socks5h://127.0.0.1:$PROXY_PORT` (lowercase и uppercase).
- `no_proxy=localhost,127.0.0.1,::1,.local`.

**Verify**: `cat /etc/environment` через свежий SSH (новые vars подхватятся
в новой сессии).

## Шаг 6: Smoke test

`scripts/05-smoke-test.sh` через свежий SSH:

```bash
ssh $SSH_TARGET "source /etc/environment; curl -sI https://api.anthropic.com" → HTTP/2 ...
ssh $SSH_TARGET "source /etc/environment; curl -sI https://ya.ru" → HTTP/2 ...
ssh $SSH_TARGET "source /etc/environment; curl -sI https://www.google.com" → HTTP/2 ...
ssh $SSH_TARGET "systemctl is-active x-ui" → active
```

5 проверок (Anthropic, OpenAI, Google, ya.ru, x-ui status). Все должны
пройти.

## Шаг 7: Обновление inventory и config

Inventory (`networks.md`):

```markdown
## Server-side proxy

- **Тип**: SOCKS5+HTTP (Mixed inbound в 3X-UI), sniffing ENABLED
- **Адрес**: 127.0.0.1:$PROXY_PORT (только локально)
- **DNS**: socks5h (DNS-резолв на прокси, без локального leak)
- **Routing**: «золотая середина» (6 правил, scoped на mixed-inbound) —
  private→direct, реклама/bittorrent→block, geoip:ru + category-ru + regex→direct,
  остальное → $UPSTREAM_REF
- **Upstream**: $UPSTREAM_REF (через 3X-UI outbound)
- **Защита**: systemd drop-in override для x-ui (предотвращает self-loop)
- **Применение**: бот, скрипты, pip/npm/curl/git через HTTPS_PROXY env
```

Config (`sysadmin-config.json`):

```jsonc
"vpn": {
  ...,
  "server_proxy_enabled": true
}
```

## Шаг 8: Финальный отчёт

```
✓ Drop-in override для x-ui применён (защита от self-loop)
✓ Mixed inbound создан: 127.0.0.1:$PROXY_PORT (id=$ID), sniffing ENABLED
✓ Routing rules для mixed inbound: 6 правил (модель «золотая середина»)
✓ /etc/environment: http_proxy/https_proxy с socks5h:// (+ NO_PROXY)
✓ Smoke check: 5/5 PASS

📋 Что делать дальше оператору:

1. ❗ Открыть НОВУЮ SSH-сессию (старые не подхватили env-vars).
2. В новой сессии проверить: `env | grep -i proxy` — должны быть три строки.
3. Программа, ради которой настраивали (бот / pip / npm) — должна работать.
4. Если программа не использует HTTPS_PROXY автоматически (aiohttp, anthropic
   SDK с issue #923, Go net/http) — см. references/python-libs-with-proxy.md.

⚠ Известные исключения (Privoxy для них — отдельная задача):
  - apt — не поддерживает SOCKS5
  - Node.js https/http core — не уважает HTTPS_PROXY нативно
  - Go stdlib — только HTTP/HTTPS-прокси, для SOCKS нужен golang.org/x/net/proxy
```

# Откат

```bash
# 1. Удалить override
ssh $SSH_TARGET "rm -f /etc/systemd/system/x-ui.service.d/override.conf && \
                 rmdir /etc/systemd/system/x-ui.service.d 2>/dev/null; \
                 systemctl daemon-reload && systemctl restart x-ui"

# 2. Удалить env-переменные (восстановить из backup)
ssh $SSH_TARGET "LATEST_BACKUP=\$(ls -t /etc/environment.backup.* | head -1); \
                 cp \$LATEST_BACKUP /etc/environment"

# 3. Удалить mixed inbound (через API)
api_call DELETE "/panel/api/inbounds/del/$MIXED_INBOUND_ID"

# 4. Удалить routing rules (через getXrayConfig + filter + updateXrayConfig)
# (см. add-proxy-routing.sh для логики — удаление через тот же jq-filter
# с inboundTag != "mixed-server-proxy")

# 5. Восстановить config
# vpn.server_proxy_enabled = false
```

# Failed attempts (граблекейс)

- **🔴 Записал /etc/environment без override → панель упала с INVALIDARGUMENT** —
  ГЛАВНАЯ грабля. Этот скилл всегда делает override **первым шагом**, и
  `03-write-environment.sh` проверяет наличие override перед записью.
- **`socks5://` без `h`** — Anthropic API возвращает 403 (DNS-leak +
  геолокация). Скилл всегда пишет `socks5h`. См. `socks5-vs-socks5h.md`.
- **mixed inbound на 0.0.0.0** — без auth прокси торчит в интернет → может
  использоваться кем угодно. Скилл предупреждает и требует подтверждения
  если оператор настаивает на не-127.0.0.1.
- **Текущая SSH-сессия не подхватила env-vars** — это нормально, env-vars
  читаются при login. Оператору надо exit + новый ssh, или `source /etc/environment`.
- **Программа не уважает HTTPS_PROXY нативно (aiohttp, anthropic SDK)** — это
  баги/особенности конкретных библиотек, см. `python-libs-with-proxy.md`.
- **Sniffing на mixed-inbound 1080 выключен** — domain-правила (реклама, банки/сервисы
  на `.com`) для серверных программ мертвы: прокси видит только IP. На боевом сервере
  он был ВЫКЛ (эталон §2.2). `02-create-mixed-inbound.sh` всегда создаёт inbound со
  sniffing `{enabled:true, destOverride:["http","tls","quic"]}`.
- **Упрощённое `geoip:ru → direct, остальное → upstream` для прокси** — старая модель
  (до 24 мая). Реклама не резалась, regex по TLD не было. Заменено на 6-правильную
  модель «золотая середина», scoped на mixed-inbound (эталон §2.5/§3.2).
- **`regexp:.*\\\\.ru$` (четыре бэкслеша в jq)** — давал рантайм-regex `\\.` (литеральный
  бэкслеш), не матчил домены. Правильно — два бэкслеша в jq-источнике (`regexp:.+\\.ru$`).

# Граничные случаи

- **На сервере уже есть свой mixed inbound на другом порту** → скилл идемпотентен,
  использует существующий с указанным портом, или создаёт новый на свободном.
- **upstream outbound — только в routing для VLESS-inbound, не для mixed** →
  скилл явно добавляет правило `inboundTag=mixed-server-proxy → upstream`,
  не зависит от существующих правил для vless-inbound.
- **Нет балансировщика, один outbound** → скилл использует `outboundTag`
  вместо `balancerTag` (auto-детект).
- **Программа в Docker-контейнере** — env-vars из /etc/environment попадают
  в контейнер только если явно пробросить: `environment: - HTTPS_PROXY`
  в docker-compose. Скилл предупреждает в финальном отчёте.

# Связанные документы

- `references/python-libs-with-proxy.md` — таблица библиотек и проблемных кейсов.
- `references/socks5-vs-socks5h.md` — почему буква `h` критична.
- `../../knowledge/networking/_reference/vpn-protocols.md` §5 — серверный прокси теория.
- `../../knowledge/networking/_reference/3x-ui-panel.md` §7.7 — подводный камень self-loop.
- `../../knowledge/networking/_reference/3x-ui-api.md` — REST API для inbound/routing.
- `decisions/0005-vpn-architecture.md` §4 — архитектурное решение.
- `evals/triggers.md` — фразы оператора.
