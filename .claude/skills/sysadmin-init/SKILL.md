---
name: sysadmin-init
description: |
  Интерактивная настройка/перенастройка агента-сисадмина под проект: создаёт ДВА конфига —
  agent-config.json (мозг: оператор, язык, менеджер паролей, реестр проектов) в корне sysadmin/
  и infra-config.json (карта: серверы, мониторинг-стек, бэкапы, Telegram, VPN-блок) в папке проекта,
  оба с валидацией по своим JSON Schema (ADR-0013).
  Режимы: первичный setup (нет конфига → интервью), идемпотентный no-op (конфиг есть → подсказка),
  --reconfigure (показывает текущее, спрашивает что менять), миграция legacy sysadmin-config.json
  (старый всё-в-одном → расщепление на два файла).
  Триггеры: «настрой агента», «первый запуск», «init agent», «/sysadmin-init», «хочу как у Василия»,
  «перенастрой конфиг», «поменять язык агента», «переключить менеджер паролей».
  НЕ для знакомства с агентом (sysadmin-meet); НЕ для настройки серверов (bootstrap-new-server).
allowed-tools: AskUserQuestion, Bash, Read, Write, Edit, WebSearch
---

<role>
Я провожу интерактивную первичную настройку и перенастройку агента-сисадмина под проект
оператора. На выходе — ДВА конфига (ADR-0013):

- **`agent-config.json`** (МОЗГ агента) — в корне публичного репо `sysadmin/`. Содержит
  оператора (имя, язык, таймзона), менеджер паролей, реестр проектов-инфраструктур
  (`projects[]`) и какой из них активен по умолчанию (`default_project`), мета-онбоардинг.
- **`infra-config.json`** (КАРТА инфры) — в папке проекта (`infra_root`), рядом с
  `inventory/`, `knowledge/`, `decisions/`. Содержит серверы, мониторинг, бэкапы,
  Telegram, VPN, опциональное оглавление `map`.

Оба валидны по своим JSON Schema (`agent-config.schema.json`, `infra-config.schema.json`).
Без них часть скиллов агента, требующих контекст оператора (install-monitoring-stack,
setup-backups, audit-security, setup-secrets-vault и другие, читающие конфиг),
останавливаются с понятным сообщением «запусти /sysadmin-init». Я — единственный
официальный путь создания, обновления и миграции этих конфигов.

Стиль общения — сеньор-ментор: на «ты», по-русски, простыми словами. Перед сложным
техническим вопросом (менеджер паролей, мониторинг, бэкапы) даю мини-урок и рекомендацию,
чтобы оператор-вайбкодер мог ответить «давай как ты советуешь» и двинуться дальше.
</role>

<context>
**Когда вызывают:** оператор склонировал инфру и работает с агентом (Cold Start §7.1
указал сюда); хочет поменять существующий конфиг (`--reconfigure`); сработал триггер.

**Предполагаю:** `agent-config.schema.json` и `infra-config.schema.json` есть в корне репо
(ADR-0013); на машине `jq` (≥1.6); `check-jsonschema` желателен, но есть jq-fallback; есть
`~/.ssh/config` (нет — спрошу алиас вручную).

**НЕ делаю:** не создаю секреты (это `setup-secrets-vault` — пишу только индекс: какой
менеджер/бот, без значений); не настраиваю SSH (`bootstrap-new-server`); не ставлю
мониторинг (`install-monitoring-stack` — пишу только желание); не наполняю `inventory/`
(`inventory-scan`). **v1.0 — один сервер и один проект** через интервью; второй
сервер/проект оператор добавит вручную в `servers[]`/`projects[]` (схема разрешает массивы
≥1; подробнее — `references/edge-cases.md`).
</context>

<goals>
После выполнения TRUE:
- В `sysadmin/` — валидный `agent-config.json` (мозг), в папке проекта — валидный
  `infra-config.json` (карта); оба проверены по своим схемам (или jq-fallback).
- Оба отражают реальные ответы оператора (не плейсхолдеры из `example.json`).
- Повторный запуск без флага → `no-op` + подсказка `--reconfigure`; с `--reconfigure` →
  по каждому ключу «оставить или поменять».
- Найден legacy `sysadmin-config.json` → предложена миграция (расщепить на два, старый → `.bak`).
- Оператор знает следующие шаги. Старые версии сохранены как `<имя>.bak.YYYYMMDD-HHMMSS`.
</goals>

# Режимы работы

| Режим | Команда | Поведение |
|-------|---------|-----------|
| Первичный setup | `/sysadmin-init` | Конфигов нет → интервью → пишу agent-config.json (мозг) + infra-config.json (карта) |
| Идемпотентный no-op | `/sysadmin-init` | Оба конфига уже есть → «уже настроено, для перенастройки — `/sysadmin-init --reconfigure`» → выход 0 |
| Перенастройка | `/sysadmin-init --reconfigure` | Конфиги есть → показываю текущие значения → по каждому ключу «оставить или поменять» |
| Миграция legacy | `/sysadmin-init` (детект) | Найден старый `sysadmin-config.json` (всё-в-одном) → предлагаю расщепить на два новых файла |

# Процедура

## Шаг 0: Pre-check (5 секунд, без вопросов оператору)

### Шаг 0.0: Гейт окружения — ПЕРВЫМ ДЕЛОМ, до всего остального

**Зачем:** скилл стоит на `bash`+`jq`. На нативном Windows bash есть только с Git for
Windows, а `jq` туда не входит. Без явной проверки машинерия молча падает на середине, а
агент импровизирует суррогат (мёртвый `infra.md` — реальный инцидент 2026-05-24). Гейт это
предотвращает (запрет C.9).

```bash
# Гейт bash+jq + корень репо через locate_sysadmin_root (кросс-платформенно, единый источник).
# Шаг А: найти find-config.sh (от скилла, затем типичные локации). Не нашли — STOP.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || SCRIPT_DIR="$(pwd)"
LIB=""
for cand in \
    "$SCRIPT_DIR/../../_lib" \
    "./.claude/skills/_lib" \
    "../sysadmin/.claude/skills/_lib" \
    "$HOME/sysadmin/.claude/skills/_lib"; do
    [ -f "$cand/find-config.sh" ] && { LIB="$(cd "$cand" && pwd)"; break; }
done
if [ -z "$LIB" ]; then
    echo "Не нашёл общие helper'ы (.claude/skills/_lib/). Запусти /sysadmin-init из"
    echo "папки sysadmin/ или укажи путь к репо. Без helper'ов настройка невозможна."
    exit 1
fi

# Шаг Б: гейт окружения (bash+jq) — ПЕРВЫМ, до любой работы с конфигом.
source "$LIB/ensure-local-env.sh"
ensure_local_env || exit 1   # STOP если окружение непригодно — НЕ продолжаю импровизацией

# Шаг В: корень репо для последующих шагов (схема, шаблоны, скрипты).
source "$LIB/find-config.sh"
locate_sysadmin_root || SYSADMIN_ROOT="$(cd "$LIB/../../.." && pwd)"
```

**Если гейт вернул exit 1 (jq не поставился или нет bash):** STOP. Сообщаю оператору
ровно ту инструкцию, которую напечатал гейт (про winget/brew/apt или ручную установку
+ перезапуск сессии). **NEVER** обходить отсутствие jq «ручной сборкой JSON» — это путь
к суррогату `infra.md`. Запрет C.9 персоны имеет приоритет над желанием «всё-таки помочь».

> **⚠️ Про bash-блоки.** Claude Code может исполнять каждый ```bash-блок в ОТДЕЛЬНОМ
> процессе — переменные (`$LIB`, `$SYSADMIN_ROOT`, `$WORKDIR`, `$AGENT_PATH`,
> `$INFRA_CONFIG_PATH`) и `PATH` между блоками **теряются**. Поэтому: держи работу раунда в
> одном блоке; в начале блока, что использует helper'ы/jq, повтори мини-bootstrap (найти
> `$LIB` тем же циклом + `source "$LIB/find-config.sh"`). Скачанный jq лежит в
> `~/.sysadmin/bin/jq` постоянно; `source` helper'а заново дописывает папку в `PATH`.

### Шаг 0.1: Поиск конфигов (ДВА файла, ADR-0013)

Мозг `agent-config.json` — в корне `sysadmin/` («дом агента», без перебора); карта
`infra-config.json` — в папке проекта (`infra_root` из `projects[]`). Алгоритм = Cold Start
персоны (`references/cold-start.md`): `find_brain_config` → `resolve_active_project` → его
`infra-config.json`; перебор типичных путей — **только fallback** (новый/старый пользователь).
Helper'ы и `$SYSADMIN_ROOT` доступны из Шага 0.0.

```bash
# 1) Есть ли уже МОЗГ (новый формат)?
BRAIN_PATH=""; BRAIN_EXISTS=false
INFRA_PATH=""; INFRA_CONFIG_PATH=""; INFRA_EXISTS=false
if find_brain_config; then
    BRAIN_PATH="$BRAIN_CONFIG"; BRAIN_EXISTS=true
    if resolve_active_project ""; then
        INFRA_PATH="$ACTIVE_INFRA_ROOT"
        INFRA_CONFIG_PATH="$ACTIVE_INFRA_CONFIG"
        INFRA_EXISTS=true
    fi
fi

# 2) Детект LEGACY всё-в-одном (sysadmin-config.json) — только если мозга ещё нет.
LEGACY_PATH=""
if [ "$BRAIN_EXISTS" != "true" ]; then
    for cand in \
        "./sysadmin-config.json" \
        "../infra/sysadmin-config.json" \
        "$HOME/infra/sysadmin-config.json" \
        "$HOME/work/infra/sysadmin-config.json" \
        "$HOME/projects/infra/sysadmin-config.json" \
        "${INFRA_DIR:-/dev/null}/sysadmin-config.json"; do
        if [ -f "$cand" ] && jq empty "$cand" >/dev/null 2>&1; then
            LEGACY_PATH="$(cd "$(dirname "$cand")" && pwd)/$(basename "$cand")"
            break
        fi
    done
fi

# 3) Идемпотентный выход без правок: оба новых файла на месте, флага нет.
if [ "$BRAIN_EXISTS" = "true" ] && [ "$INFRA_EXISTS" = "true" ] && [ "$ARG" != "--reconfigure" ]; then
    echo "Уже настроено:"
    echo "  мозг:  $BRAIN_PATH (operator/projects/default_project)"
    echo "  карта: $INFRA_CONFIG_PATH (servers/monitoring/backups)"
    echo "Для перенастройки запусти /sysadmin-init --reconfigure"
    exit 0
fi

# 4) Найден legacy и нового мозга нет → МИГРАЦИЯ (Шаг 0.2). MIGRATE=true ведёт веткой миграции.
MIGRATE=false
if [ "$BRAIN_EXISTS" != "true" ] && [ -n "$LEGACY_PATH" ]; then
    MIGRATE=true
    echo "Обнаружен старый конфиг (всё-в-одном): $LEGACY_PATH"
    echo "Предложу расщепить его на два новых файла (agent-config + infra-config)."
fi

# jq уже гарантирован гейтом Шага 0.0. check-jsonschema — опционален.
command -v check-jsonschema >/dev/null \
  || echo "WARN: check-jsonschema не установлен. Будет fallback-валидация на jq."

# Единый временный каталог (mktemp -d кросс-платформенно, не хардкод /tmp/). Все draft'ы
# скилла — внутри $WORKDIR. Чистим в конце (Шаг 10) или при отмене.
WORKDIR="$(mktemp -d 2>/dev/null || mktemp -d -t sysadmin)"
[ -d "$WORKDIR" ] || { echo "ERROR: не удалось создать временный каталог"; exit 1; }

# Автодетект (один JSON: { ssh_aliases:[...], os, docker, jq_version, ... }).
bash "$SYSADMIN_ROOT/.claude/skills/sysadmin-init/scripts/detect-defaults.sh" > "$WORKDIR/sysadmin-defaults.json"
```

**Если мозга нет (первичный setup):** в Раунде 1.5 спрашиваю id/title проекта и путь к
будущему `infra/`; запись путей и `mkdir -p` папки инфры делает `write-configs.sh` (Шаг 10).

### Шаг 0.2: Ветка миграции legacy (если `MIGRATE=true`)

Если на Шаге 0.1 найден старый `sysadmin-config.json` (всё-в-одном) и нового мозга ещё нет —
предлагаю расщепить. Через `AskUserQuestion` (radio): «Мигрировать сейчас» / «Не сейчас (выйти)».

Расщепление делает скрипт `scripts/migrate-legacy.sh` (правило раскладки полей —
в шапке скрипта; вкратце: `operator`/`language`/`secrets`/`meta`/`infrastructure.root_path`
→ мозг, `monitoring`/`backups`/`notifications`/`servers`/`vpn`/`map` → карта).

```bash
bash "$SYSADMIN_ROOT/.claude/skills/sysadmin-init/scripts/migrate-legacy.sh" \
     "$LEGACY_PATH" "$WORKDIR"   # → $WORKDIR/agent-config-draft.json + infra-config-draft.json
```

После сборки draft'ов миграция идёт сразу на **Шаг 9 (валидация обоих)** → **Шаг 10
(превью + запись обоих)**, минуя интервью. На Шаге 10 старый `sysadmin-config.json`
переименовывается в `sysadmin-config.json.bak.YYYYMMDD-HHMMSS` (см. Шаг 10).

## Шаг 1: Приветствие (3-4 строки, дружелюбно)

> «Привет! Помогу настроить агента под твой проект: язык общения, менеджер паролей,
> сервер, мониторинг, бэкапы, алерты. Итог — ДВА файла: `agent-config.json` (мой мозг —
> кто ты, язык, проекты) в `sysadmin/` и `infra-config.json` (карта сервера) в твоей
> приватной папке инфры. 3-5 минут. Не уверен по вопросу — пиши «давай как ты советуешь».»

## Шаги 2–7.5: Интервью (Раунды 1–6.5)

Каждый раунд — через `AskUserQuestion`. **Полные сеньор-обёртки** (мини-урок, таблицы
плюсов/минусов, обоснования, обработка ответов) для сложных раундов — в
`references/wizard-flow.md` по указанным §. Здесь — что спрашиваю, куда пишу, и краткая
обёртка-затравка. Максимум 2 уровня вложенности вопросов (третий — в `--reconfigure`).

| Раунд | Поля | Файл | Обёртка |
|---|---|---|---|
| 1. Имя/язык/TZ | `operator.name`/`.language`/`.timezone` | мозг | без обёртки (defaults из `detect-defaults.json`) |
| 1.5. Проект | `projects[0].{id,title,infra_root}` + `default_project` | мозг | СЕНЬОР — `wizard-flow.md` §«Раунд 1.5» |
| 2. Менеджер паролей | `secrets.{manager,manager_name,cli_available}` | мозг | СЕНЬОР — `wizard-flow.md` §«Раунд 2» |
| 3. Сервер | `servers[0].{alias,ssh_alias,role,domain?}` | карта | лёгкая |
| 4. Мониторинг | `monitoring.{enabled,stack,panel_domain}` | карта | СЕНЬОР — `wizard-flow.md` §«Раунд 4» |
| 5. Бэкапы | `backups.{enabled,destination,retention,rclone_remote?}` | карта | СЕНЬОР — `wizard-flow.md` §«Раунд 5» |
| 6. Telegram | `notifications.telegram.{enabled,bot_username,chat_type}` | карта | лёгкая |
| 6.5. VPN | `vpn.*` (флаги, заполнят VPN-скиллы) | карта | лёгкая |

**Раунд 1.5 (проект + путь к инфре).** Дефолт `infra_root` — `../infra` (сосед `sysadmin/`),
лучше абсолютный путь. `id` нормализую в kebab-case (regex `^[a-z0-9][a-z0-9-]*$`); если
родителя пути нет — повторяю вопрос (опечатка). `default_project = projects[0].id` (v1.0 —
один проект). Записываю `infra_root` как ввёл оператор (резолвер раскроет tilde).

**Раунд 2 (менеджер паролей).** Enum `keychain`/`bitwarden`/`1password`/`pass`/`keepassxc`/
`other`; дефолт по OS (macOS→`keychain`, Linux→`pass`). Для известных — `cli_available:true`.
Ветка **«Другой менеджер»** (research CLI + честный выбор «остаться руками / перейти на
Bitwarden») — полностью в `wizard-flow.md` §«Другой менеджер»; пишу `manager_name` +
`cli_available` по результату ресёрча. Подсказка: реальные значения — не сюда, а в
`/setup-secrets-vault`.

**Раунд 3 (сервер).** Если `ssh_aliases` в `detect-defaults.json` непуст — выбор из
найденных (radio), иначе спрашиваю вручную. `role`: `production`/`staging`/`test`/`personal`.
**v1.0 — один сервер**; про второй: «добавишь вручную в `servers[]`, схема разрешает массив
≥1» (см. `references/edge-cases.md`).

**Раунд 4 (мониторинг).** `enabled` → при включении `stack` (массив из enum) и
`panel_domain` (hostname, regex `^[a-z0-9.-]+$`). Варианты: не ставить / базовый
(uptime-kuma+beszel) / полный (+dozzle+dockge+diun, ★ для production).

**Раунд 5 (бэкапы).** `enabled` → `destination` (enum: `yandex-disk-webdav` для РФ /
`s3`/`b2` / `nextcloud-webdav` / `local`(не советую)), `rclone_remote` (для webdav-вариантов,
regex `^[a-zA-Z][a-zA-Z0-9_-]+$`), `retention`. **⚠️ `retention` — ОБЪЕКТ `{daily,weekly,
monthly}` (целые), НЕ строка** (схема `additionalProperties:false`). Дефолт `{daily:7,
weekly:4,monthly:6}` (можно описать как «7д-4н-6м», но в конфиг пишется объектом).

**Раунд 6 (Telegram).** `enabled` → `bot_username` (без `@`, regex
`^[a-zA-Z][a-zA-Z0-9_]{4,31}$`; создать через @BotFather), `chat_type` (`personal`/`channel`).
Реальный токен — в менеджер паролей, не сюда.

**Раунд 6.5 (VPN).** Заготовка секции под VPN-скиллы. Если включил: `vpn.enabled=false`,
`panel_url=null`, `panel_web_base_path=null`, `server_proxy_enabled=false`,
`upstream_kind="none"`, `default_reality_dest="www.cloudflare.com"`. Конкретные значения
впишет `/setup-vpn-panel`. Не включил — секция не добавляется (попросят
`--reconfigure` при первом `/setup-vpn-panel`).

## Шаг 8: Сборка ДВУХ JSON во временные файлы

Из двух skeleton'ов (`templates/{agent,infra}-config-skeleton.json`) собираю два draft'а в
`$WORKDIR`, подменяя `__FILL__` и доливая опциональные блоки при `*_ENABLED=true`. Раскладка
ответов по файлам — в таблице раундов выше (мозг: Раунды 1/1.5/2; карта: Раунды 3–6.5).

### 8.1–8.2 Сборка обоих draft'ов — `scripts/assemble-configs.sh`

Сборку делает `scripts/assemble-configs.sh`: берёт оба skeleton'а, читает ответы интервью
из **переменных окружения** (полный контракт — в шапке скрипта) и доливает опциональные
блоки только при `*_ENABLED=true`. Агент выставляет переменные по ответам и вызывает:

```bash
NAME="$NAME" LANG="$LANG" TIMEZONE="$TIMEZONE" MANAGER="$MANAGER" \
  PROJ_ID="$PROJ_ID" PROJ_INFRA_ROOT="$PROJ_INFRA_ROOT" \
  SRV_ALIAS="$SRV_ALIAS" SRV_SSH="$SRV_SSH" SRV_ROLE="$SRV_ROLE" \
  ${PROJ_TITLE:+PROJ_TITLE="$PROJ_TITLE"} ${SRV_DOMAIN:+SRV_DOMAIN="$SRV_DOMAIN"} \
  ${MANAGER_NAME:+MANAGER_NAME="$MANAGER_NAME" CLI_AVAILABLE="$CLI_AVAILABLE"} \
  ${MON_ENABLED:+MON_ENABLED=true MON_STACK_JSON="$MON_STACK_JSON" MON_PANEL_DOMAIN="$MON_PANEL_DOMAIN"} \
  ${BACKUPS_ENABLED:+BACKUPS_ENABLED=true BACKUPS_DESTINATION="$BACKUPS_DESTINATION" BACKUPS_RETENTION_JSON="$BACKUPS_RETENTION_JSON" BACKUPS_RCLONE_REMOTE="$BACKUPS_RCLONE_REMOTE"} \
  ${TG_ENABLED:+TG_ENABLED=true TG_BOT_USERNAME="$TG_BOT_USERNAME" TG_CHAT_TYPE="$TG_CHAT_TYPE"} \
  ${VPN_ENABLED:+VPN_ENABLED=true} \
  bash "$SYSADMIN_ROOT/.claude/skills/sysadmin-init/scripts/assemble-configs.sh" "$WORKDIR" "$SYSADMIN_ROOT"
# draft'ы лежат тут (используются Шагами 9–10):
AGENT_DRAFT="$WORKDIR/agent-config-draft.json"; INFRA_DRAFT="$WORKDIR/infra-config-draft.json"
```

**Ключевое:** для `manager=other` передай `MANAGER_NAME` + `CLI_AVAILABLE` (из ресёрча
Раунда 2; известным менеджерам `cli_available=true` ставится сам). **`BACKUPS_RETENTION_JSON`
— JSON-ОБЪЕКТ** `{"daily":7,"weekly":4,"monthly":6}` (не строка `7d-4w-6m`!), `MON_STACK_JSON`
— JSON-массив из enum. Скрипт убирает агент-поля из карты (страховка ADR-0013) и валится с
понятной ошибкой при нехватке обязательной переменной (не пишет молча битый draft).
**Блок `meta`** остаётся из skeleton (`onboarding_completed:false`); в `--reconfigure` `meta`
и уже выставленные VPN-поля (`panel_url`, `panel_web_base_path`) НЕ затираются.

## Шаг 9: Валидация перед сохранением (ОБА файла)

`validate-config.sh` определяет схему по имени файла: `*agent-config*` → agent-схема,
`*infra-config*` → infra-схема. Валидирую оба draft'а.

```bash
# Пере-объявляем пути draft'ов (на случай отдельного процесса — см. ⚠️ про bash-блоки).
AGENT_DRAFT="$WORKDIR/agent-config-draft.json"; INFRA_DRAFT="$WORKDIR/infra-config-draft.json"
VALIDATOR="$SYSADMIN_ROOT/.claude/skills/sysadmin-init/scripts/validate-config.sh"
bash "$VALIDATOR" "$AGENT_DRAFT" "$INFRA_DRAFT" || {
    echo "Конфиг не прошёл валидацию (см. вывод выше: какой файл, какое поле)."
    echo "Что делаем — исправить вручную или вернуться в нужный раунд?"
    exit 2
}
```

Если ошибка — STOP, показываю файл/поле/причину (`check-jsonschema` даёт указатель типа
`.servers[0].ssh_alias must be string`; jq-fallback — `FAIL [agent]`/`FAIL [infra]`) и
спрашиваю «исправить вручную или вернуться в раунд X?».

## Шаг 10: Превью + подтверждение (ОБА файла)

```bash
AGENT_DRAFT="$WORKDIR/agent-config-draft.json"; INFRA_DRAFT="$WORKDIR/infra-config-draft.json"
echo "Мозг (agent-config.json → $SYSADMIN_ROOT/):"; jq '.' "$AGENT_DRAFT"
echo "Карта (infra-config.json → папка проекта):"; jq '.' "$INFRA_DRAFT"
```

Спрашиваю «всё верно?» через `AskUserQuestion` (radio: «Да, сохранить» / «Вернуться в
раунд X» / «Отмена»).

Если «Да» — запись делает `scripts/write-configs.sh`: целевые пути (мозг →
`$SYSADMIN_ROOT/agent-config.json`; карта → `<infra_root>/infra-config.json` из draft'а
мозга, с `mkdir -p` папки инфры), backup существующих и legacy в `.bak.YYYYMMDD-HHMMSS`,
mv обоих + **FINAL CHECK** (оба на диске + валидны; иначе ГРОМКИЙ отказ без суррогата — C.9):

```bash
# $3 — путь к legacy (если MIGRATE=true), иначе пусто. Внутри: backup + mv + FINAL CHECK.
bash "$SYSADMIN_ROOT/.claude/skills/sysadmin-init/scripts/write-configs.sh" \
     "$WORKDIR" "$SYSADMIN_ROOT" "${LEGACY_PATH:-}" || exit 1
AGENT_PATH="$SYSADMIN_ROOT/agent-config.json"
INFRA_CONFIG_PATH="$(jq -r '.projects[0].infra_root' "$AGENT_PATH")/infra-config.json"
rm -rf "$WORKDIR"   # запись подтверждена — чистим временные draft'ы
```

### Шаг 10.4: выездной bridge-указатель (`@sysadmin` из любой папки)

**Зачем:** чтобы звать `@sysadmin` из чужой папки, в `~/.claude/agents/` кладётся тонкий
указатель на `sysadmin/` (его читают `find-config.sh` и сам агент за ядром CLAUDE.md,
ADR-0015). Создание — единый helper `_lib/write-bridge.sh` (один источник, не копия heredoc).

```bash
source "$LIB/write-bridge.sh"
write_bridge "$SYSADMIN_ROOT"   # перезаписывает свежим путём; WARN+rc=1 если нет ~/.claude/agents
```

### Шаг 10.5: FINAL CHECK — внутри `write-configs.sh`

Проверка «оба конфига реально на диске и валидны» теперь выполняется самим
`write-configs.sh` (Шаг 10) перед возвратом rc=0. **NEVER печатать «Готово» при rc≠0** —
скрипт уже напечатал ГРОМКУЮ причину (C.9: не импровизировать суррогат).

### Шаг 10.6: Самопроверка «всё реально работает» + честный вердикт

**Зачем («не смог — скажи прямо»):** мало записать — нужно убедиться, что связка пригодна
(bash+jq, оба конфига валидны, папка инфры и bridge на месте). `self-test-setup.sh` печатает
«✅ проверено» либо вердикт «настройка не завершена, открой issue с диагностикой» (rc=1).
**«Готово» говорю ТОЛЬКО при rc=0** — иначе передаю оператору вердикт скрипта, не притворяюсь.

```bash
# Мини-bootstrap на случай, если этот блок — отдельный процесс и $LIB потерялся.
if [ -z "${LIB:-}" ] || [ ! -f "$LIB/self-test-setup.sh" ]; then
    for cand in "./.claude/skills/_lib" "../sysadmin/.claude/skills/_lib" "$HOME/sysadmin/.claude/skills/_lib"; do
        [ -f "$cand/self-test-setup.sh" ] && { LIB="$(cd "$cand" && pwd)"; break; }
    done
fi
[ -z "${SYSADMIN_ROOT:-}" ] && SYSADMIN_ROOT="$(cd "$LIB/../../.." && pwd)"

source "$LIB/self-test-setup.sh"
# Передаю ОБА файла: мозг ($1) и карту активного проекта ($3). Папку инфры self-test
# берёт из projects[].infra_root мозга (ADR-0013).
if self_test_setup "$AGENT_PATH" "$SYSADMIN_ROOT" "$INFRA_CONFIG_PATH"; then
    echo ""
    echo "Готово. Оба конфига записаны и полностью проверены:"
    echo "  мозг:  $AGENT_PATH"
    echo "  карта: $INFRA_CONFIG_PATH"

    # Активация версионируемого pre-commit hook (персона + knowledge + секреты).
    # core.hooksPath включаем ОДИН раз на машине, идемпотентно; git-сбой не валит init.
    if [ -d "$SYSADMIN_ROOT/.git" ] && [ -f "$SYSADMIN_ROOT/.githooks/pre-commit" ]; then
        if [ "$(git -C "$SYSADMIN_ROOT" config core.hooksPath 2>/dev/null)" != ".githooks" ]; then
            git -C "$SYSADMIN_ROOT" config core.hooksPath .githooks 2>/dev/null \
                && echo "→ pre-commit hook активирован (core.hooksPath=.githooks)." \
                || echo "⚠️  не удалось включить core.hooksPath — пропускаю (необязательно)."
        fi
        # Блок «секреты» в хуке — fail-closed: без gitleaks коммиты в ЭТОТ репозиторий
        # будут отклоняться (C.5). Предупреждаем сразу, а не при первом непонятном отказе.
        command -v gitleaks >/dev/null 2>&1 || cat <<'GITLEAKS_HINT'
⚠️  gitleaks не найден. Хук проверяет коммиты на секреты и без него ОТКЛОНЯЕТ их.
    Установка: https://github.com/gitleaks/gitleaks#installing
GITLEAKS_HINT
    fi
    # дальше — Шаг 11
else
    # self_test_setup напечатал честный вердикт. НЕ печатаю «Готово», НЕ иду на Шаг 11,
    # НЕ предлагаю другие скиллы — система не готова. Останавливаюсь.
    exit 1
fi
```

Если «Вернуться» — перезапускаю нужный раунд, остальные ответы сохраняю.
Если «Отмена» — `rm -rf "$WORKDIR"`, ничего не пишу ни в `sysadmin/`, ни в папку инфры.

### Onboarding-флаг — спрашиваю про знакомство

После записи — короткий вопрос (`AskUserQuestion`, radio), чтобы агент не приставал с
напоминаниями про `/sysadmin-meet`, если оператор уже знаком: «Проходил ли знакомство
`/sysadmin-meet` (~20 мин, простым языком — что это, как работает, что умеет)?» —
**(1)** уже знаком / **(2)** позже / **(3)** запустить сейчас.

```bash
# (1) уже знаком → флаг true в МОЗГЕ (.meta в agent-config.json):
tmp=$(mktemp) && jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.meta.onboarding_completed=true | .meta.onboarding_completed_at=$ts' \
    "$AGENT_PATH" > "$tmp" && mv "$tmp" "$AGENT_PATH"
# (2) позже → флаг остаётся false (мягкие напоминания при разговорах).
# (3) сейчас → "запусти /sysadmin-meet, конфиг сохранён"; exit 0 (Шаг 11 НЕ показываю —
#     он покажется после /sysadmin-meet, который сам ставит флаг и вернёт сюда).
```

## Шаг 11: Финал — подсказки по следующим шагам

Вывожу адаптированный список скиллов в зависимости от ответов оператора:

```
Создано ДВА конфига (ADR-0013): мозг {AGENT_PATH} (в sysadmin/) + карта {INFRA_CONFIG_PATH}.

Где работать дальше: открывай Claude Code в РОДИТЕЛЬСКОЙ папке (рядом sysadmin/ + папка
инфры) — оба репо видны сразу. @sysadmin технически зовётся из любой папки (подхвачу
конфиги по Cold Start, см. references/cold-start.md).

Что дальше — пошагово:
  1. [inventory/hosts/ пуст] /bootstrap-new-server — SSH/UFW/fail2ban/Docker/git на {server.alias}.
  2. [Всегда] Менеджер паролей ({secrets.manager}) не настроен → /setup-secrets-vault.
  3. [monitoring.enabled] /install-monitoring-stack — {monitoring.stack} на {monitoring.panel_domain}.
  4. [backups.enabled] /setup-backups — restic destination={backups.destination}, + cron/Telegram-алерты.
  5. [Всегда] /audit-security — проход по чек-листу (UFW/SSH/fail2ban/secrets).
```

# Режим --reconfigure

Текущие значения читаю из ДВУХ файлов: агент-поля (Раунды 1/1.5/2) из `$BRAIN_PATH`
(`agent-config.json`), инфра-поля (Раунды 3–6.5) из `$INFRA_CONFIG_PATH`. Оба пути непустые
после Шага 0.1. По каждому ключу показываю «Сейчас: <поле> = <значение>» и спрашиваю
«оставить / задать заново» (`AskUserQuestion`); при «заново» — тот же раунд, что в setup.

```bash
jq -r '.secrets.manager' "$BRAIN_PATH"        # пример агент-поля (Раунд 2)
jq -r '.servers[0].role' "$INFRA_CONFIG_PATH" # пример инфра-поля (Раунд 3)
```

После всех раундов — Шаги 8→9→10 (+10.6 самопроверка обязательна и здесь: после правок
оба конфига должны остаться рабочими). **НЕ затираю:** блок `meta` мозга и уже выставленные
VPN-поля (`panel_url`, `panel_web_base_path` — их заполняют VPN-скиллы) — переношу текущие
значения в draft перед записью.

# Граничные случаи и грабли

Полный список — `references/edge-cases.md` (Failed Attempts + все граничные случаи:
legacy-миграция, повреждённый конфиг, прерванное интервью, нативный Windows без
bash, пустой `~/.ssh/config`, multi-server/multi-project, «давай как ты советуешь»).
Самое важное, что нельзя забыть:

- **Молчаливый `exit 1` в bash = приглашение LLM импровизировать** (инцидент 2026-05-24,
  суррогат `infra.md`). Любой отказ — ГРОМКИЙ, с явной командой «STOP, не чини сам» (C.9).
- **Валидация ПЕРЕД `mv`** в финальное место; **backup `.bak.TS`** перед перезаписью
  каждого из двух файлов; **FINAL CHECK** (Шаг 10.5) ловит «записал, но файла нет».
- **Не задавай вопрос, на который отвечает системный файл** — `detect-defaults.sh` первым.

# Важные правила

- **АБСОЛЮТНЫЙ ЗАПРЕТ записывать в конфиг данные, которых не подтвердил оператор.**
  Если автодетект нашёл что-то — предлагаю, оператор подтверждает.
- **Никаких выдуманных доменов, ботов, токенов в шаблонах.** Если оператор пропустил
  поле — оставляю значение по умолчанию из схемы (`example.com`, `bot_username`
  опционален при `enabled=false`).
- **Тон — на «ты», по-русски, партнёрский.** Не «Вы», не «вы», не на английском.
- **Сеньор-обёртка применяется только к 3 сложным вопросам.** Простые вопросы (имя,
  язык, ssh_alias из найденных) — без обёртки, чтобы не утомлять оператора.
- **Никаких нарративных вставок «Василий сказал...».** Только императив, без рассказов.