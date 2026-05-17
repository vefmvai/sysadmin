---
name: refresh-vpn-knowledge
description: |
  Актуализация VPN-knowledge базы (`.claude/knowledge/networking/`) когда
  её содержимое старше TTL. База разделена на 3 слоя с разными TTL (ADR-0006):
  `_live/` (TTL 14 дней — фронт борьбы по странам), `_reference/` (TTL 60 дней —
  устройство протоколов/клиентов/панели/транспортов/fronting), `_meta/` (TTL 365
  дней — реестр источников, глоссарий, конфликты).
  Сценарий: блокировки и TSPU-сигнатуры в РФ меняются ежедневно, выходят новые
  версии клиентов sing-box/Hiddify/Karing, появляются issues в 3X-UI — без
  актуализации агент работает с устаревшей картой и рекомендует уже сломанное.
  Процесс: проверка frontmatter → WebSearch по фиксированным sources_checked →
  Tavily research по выявленным изменениям → дифф старого и нового → Yellow Zone
  подтверждение → переписывание разделов + обновление last_researched.
  Триггеры: «обнови vpn knowledge», «refresh vpn knowledge», «актуализируй знания
  про обходы», «проверь свежесть vpn-базы», «давно не обновляли блокировки»,
  + автотриггер из персоны §4.2 перед любой VPN-задачей если найден просроченный файл.
  НЕ для обновления самого мозга агента (это «обнови sysadmin» / git pull).
  НЕ для добавления новых VPN-протоколов с нуля (это исследовательская сессия отдельно).
allowed-tools: Bash, Read, Edit, Write, WebSearch, WebFetch
---

<role>
Я отвечаю за свежесть VPN-knowledge базы — общедоменных знаний про VPN-протоколы,
блокировки РФ, клиентов и панель 3X-UI, на которые опираются все VPN-скиллы.
Реальность в этой области меняется ежемесячно: TSPU добавляет сигнатуры, выходят
новые версии sing-box, появляются issues с iOS-клиентами, меняются reality-параметры.
Без актуализации скиллы рекомендуют сломанное.

Работаю в **Yellow Zone**: правлю knowledge-файлы только с явным подтверждением
оператора по каждому файлу. Не переписываю молча. Каждое изменение оператор
видит как дифф «было / стало» и принимает или отклоняет.
</role>

<context>
Что предполагается:
- VPN-knowledge живёт в `.claude/knowledge/networking/` в трёх слоях (ADR-0006):
  - `_live/` — frontline-{ru,cn,ir,by}.md + timeline.md (TTL 14 дней)
  - `_reference/` — vpn-protocols.md, transports.md, fronting-strategies.md,
    3x-ui-panel.md, 3x-ui-api.md, client-apps.md (TTL 60 дней)
  - `_meta/` — sources-registry.md, glossary.md, conflicts.md (TTL 365 дней)
- Каждый файл имеет frontmatter с полями `knowledge_domain: vpn`, `layer`,
  `last_researched`, `ttl_days`, `sources_checked` (см. helper
  `_lib/check-knowledge-freshness.sh`).
- Tavily — 9 ключей с авто-ротацией через `~/.local/bin/tavily-search.sh` и
  `tavily-extract.sh` (curl напрямую к API, при quota_exceeded — следующий ключ).
  Конфиг ключей: `~/.config/tavily-keys.json`. WebSearch встроен как fallback.
- Интернет на машине оператора работает (это локальный скилл, не серверный).

Что НЕ предполагается:
- Что оператор сам мониторит ntc.party и GitHub-issues. Скилл делает это за него.
- Что Tavily доступен — если упал, fallback на WebSearch+WebFetch.
- Что все файлы устарели одновременно — скилл может актуализировать выборочно.
</context>

<goals>
После выполнения должно стать TRUE:
- Все VPN-knowledge файлы с истёкшим TTL либо обновлены, либо явно подтверждены
  как актуальные (`last_researched` обновлён без правок содержимого).
- Каждое изменение по содержимому подтверждено оператором отдельно (Yellow Zone).
- Найденные новые источники (новые issues, новые клиенты) добавлены в
  `sources_checked` соответствующего файла.
- Если выявлен критический сдвиг (например: «Reality с serverName=cloudflare
  начала фейлиться в РФ») — создаётся ADR в `$INFRA/decisions/`.
</goals>

<parameters>
- `LAYER` — какой слой актуализировать (default: `live` — потому что чаще всего нужен):
  - `live` — `_live/frontline-*.md` и `_live/timeline.md` (TTL 14 дней, чаще всего)
  - `reference` — `_reference/*.md` (TTL 60 дней, реже)
  - `meta` — `_meta/*.md` (TTL 365 дней, почти никогда)
  - `all` — все слои подряд
- `DOMAIN` — какой knowledge-домен актуализировать (default: `vpn`).
- `FILES` — конкретные файлы через запятую, для точечной актуализации
  (default: все просроченные в домене + слое).
- `MODE` — `check` (только показать что устарело, не лезть в сеть) /
  `full` (полный цикл с WebSearch+Tavily) (default: `full`).
- `TAVILY_BUDGET` — сколько Tavily-запросов максимум (default: 25 для LAYER=live,
  30 для LAYER=reference, 0 для LAYER=meta — почти не нужен).
- `AUTO_REFRESH_DATES` — если `true`, для файлов где оператор сказал «всё актуально,
  ничего не меняем», обновить только `last_researched` без правок текста (default: `true`).
</parameters>

# Процедура

## Шаг 0: Проверка свежести (Green Zone)

Запускаю helper, чтобы понять — какие файлы просрочены.

```bash
SYSADMIN_ROOT=$(grep -oE '`/[^`]+sysadmin/?`' ~/.claude/agents/sysadmin.md 2>/dev/null \
    | head -1 | sed 's|`||g; s|/$||')
[ -z "$SYSADMIN_ROOT" ] && SYSADMIN_ROOT="$(pwd)"

# Список просроченных файлов в JSON-формате
STALE=$(bash "$SYSADMIN_ROOT/.claude/skills/_lib/check-knowledge-freshness.sh" \
    "${DOMAIN:-vpn}" --json --stale-only)

# Фильтр по LAYER (default: live — самый частый сценарий)
LAYER="${LAYER:-live}"
if [ "$LAYER" != "all" ]; then
    STALE=$(echo "$STALE" | jq --arg L "_${LAYER}/" '[.[] | select(.file | contains($L))]')
fi

STALE_COUNT=$(echo "$STALE" | jq 'length')
```

**Если `STALE_COUNT=0`** — выводим оператору одну строку и выходим:
> «Все VPN-knowledge файлы в слое `_${LAYER}/` в актуальном TTL. Проверять нечего.»

**Если есть просроченные** — показываем список (с указанием слоя):
```
Просроченные VPN-knowledge (LAYER=live):
  ⚠️  _live/frontline-ru.md — last_researched 2026-05-01 (16 дней, TTL 14)
  ⚠️  _live/timeline.md     — last_researched 2026-04-30 (17 дней, TTL 14)
```

Если `MODE=check` — на этом останавливаемся. Иначе переходим к Шагу 1.

## Шаг 1: Брифинг (Yellow Zone — переход к web-исследованию)

> «Я собираюсь актуализировать <N> VPN-knowledge файлов. Это значит:
>
> 1. Пройду WebSearch'ем по их `sources_checked` (короткие запросы, бесплатно).
> 2. Для файлов, где WebSearch выявил изменения — сделаю глубокий Tavily research
>    (бюджет до $TAVILY_BUDGET запросов из 1000/мес).
> 3. Покажу тебе **дифф для каждого файла** — что предлагаю изменить.
> 4. По твоему «да» правлю файл, обновляю `last_researched`.
> 5. Если выявлен критический сдвиг (Reality сломался, клиент удалён из App Store) —
>    предложу создать ADR в `$INFRA/decisions/`.
>
> Web-исследование может занять 3-10 минут. Tavily расходует общий лимит на месяц,
> поэтому я экономлю — иду в Tavily только за подтверждением WebSearch-находок.
>
> Подтверди старт: 'да' / 'давай' / 'погнали'.»

Без подтверждения — не запускаю web-запросы. Без `--mode=check`, оператор может
сначала посмотреть что устарело, потом решить запускать актуализацию.

## Шаг 2: WebSearch-обход (Green Zone — read-only веб)

Для каждого просроченного файла:

1. Извлекаю `sources_checked` из frontmatter:
   ```bash
   FILE=".claude/knowledge/networking/_reference/vpn-protocols.md"  # пример (любой слой)
   SOURCES=$(awk '/^---$/{c++; next} c==1 && /^  - /{sub("^  - ", ""); print}' "$FILE" | head -10)
   ```

2. Для каждого URL — WebSearch с запросом контекста файла. Источники
   разделены по слоям:

   **`_live/` слой** (ежедневное состояние блокировок):
   - frontline-ru.md: `site:ntc.party 2026 Russia VPN` + `site:gfw.report Russia`
     + `site:blog.cloudflare.com Russia` + Mediazona/Meduza/Moscow Times последние недели
   - frontline-cn.md: `site:gfw.report 2026` + greatfirewallguide.com + USENIX
   - frontline-ir.md: arxiv preprints + Iran censorship reports 2026
   - frontline-by.md: Carnegie + RFE/RL + CSO Meter Belarus 2026
   - timeline.md: добавляются новые события из всех frontline-*

   **`_reference/` слой** (устройство мира — реже меняется):
   - vpn-protocols.md: `XTLS/Xray-core releases` + `SagerNet/sing-box releases`
     + `MHSanaei/3x-ui releases`
   - transports.md: новые transport-фичи в release notes XTLS/sing-box
   - fronting-strategies.md: Cloudflare blog + новые CDN-fronting туториалы
   - client-apps.md: `sing-box iOS client release` + `Hiddify release notes` +
     `Karing release` + App Store removals
   - 3x-ui-panel.md, 3x-ui-api.md: MHSanaei/3x-ui issues/releases

   **`_meta/` слой** (стабильное, обновляется по запросу):
   - sources-registry.md: добавление/удаление источников по факту
   - glossary.md: новые термины (XHTTP, AnyTLS, и т.д.)
   - conflicts.md: разрешение старых конфликтов

3. Собираю результаты в один JSON-документ:
   ```json
   {
     "file": "vpn-protocols.md",
     "findings": [
       {"source": "ntc.party/c/blocking", "summary": "Новая статья о фейлах Reality 2026-06", "url": "..."},
       {"source": "XTLS/Xray-core releases", "summary": "Релиз v1.9 с fix'ом X25519 fingerprint", "url": "..."}
     ]
   }
   ```

4. Если по файлу findings пуст — **этот файл актуален**, переходим к Шагу 5
   (обновление только `last_researched`).

## Шаг 3: Tavily search/research (по бюджету)

Только для файлов, где WebSearch нашёл изменения, делаю глубокий поиск.

**Приоритет инструментов** (для экономии quota):
1. **`~/.local/bin/tavily-search.sh "query" advanced 8`** (curl-обёртка с
   ротацией 9 ключей) — обычные поиски, **default**
2. **`~/.local/bin/tavily-extract.sh "https://url"`** — извлечение конкретной
   страницы (тот же ротатор)
3. **`mcp__tavily__tavily_search`** (basic depth) — если curl недоступен
4. **`mcp__tavily__tavily_research`** (pro depth) — **только** для глубоких
   синтезов; имеет отдельный жёсткий лимит, не использовать на простых
   проверках актуальности
5. WebSearch + WebFetch — fallback при полном исчерпании Tavily

**Бюджет жёсткий**: не более `$TAVILY_BUDGET` запросов за весь прогон скилла.
По умолчанию для `LAYER=live` — 25, для `LAYER=reference` — 30, для
`LAYER=meta` — 0. При исчерпании — fallback на WebSearch.

```
Пример Tavily-запроса для _live/frontline-ru.md:
"Russia VPN blocking status May 2026 latest TSPU signatures
new blocks since 2026-05-01 mobile operators differences"
```

## Шаг 4: Дифф и подтверждение (Yellow Zone)

Для каждого файла, где найдены изменения, формирую **дифф-предложение**:

```
=== vpn-protocols.md ===

§3.3 «Блокировки Reality в РФ»

БЫЛО (на 2026-05-15):
> Reality с serverName=cloudflare.com работает стабильно. TSPU не блокирует
> TLS-ClientHello с этим SNI.

ПРЕДЛАГАЮ (на 2026-06-15):
> Reality с serverName=cloudflare.com работает в большинстве регионов, но
> с июня 2026 в Татарстане и Самарской области наблюдаются эпизодические фейлы
> (источник: ntc.party/t/12345). Рекомендация: для критичных клиентов в этих
> регионах использовать serverName=www.microsoft.com как fallback.

Изменения в sources_checked:
+ https://ntc.party/t/12345-reality-cloudflare-tatarstan-2026-06

Применить? (да / нет / показать ещё контекст)
```

Оператор:
- **«да»** — применяю Edit к файлу, добавляю URL в `sources_checked`, обновляю `last_researched`.
- **«нет»** — пропускаю этот файл, в конце предлагаю обновить только `last_researched` (если есть `AUTO_REFRESH_DATES=true`).
- **«показать ещё контекст»** — вывожу полные WebSearch+Tavily findings по этому файлу.

## Шаг 5: Обновление last_researched

Для каждого файла, по которому оператор принял решение (с правками или без):

```bash
TODAY=$(date -u +%Y-%m-%d)
# Через sed заменяю строку last_researched:
sed -i.bak -E "s/^last_researched:.*/last_researched: $TODAY/" "$FILE"
rm -f "${FILE}.bak"
```

## Шаг 6: Если найден критический сдвиг — действия по слою

**Поведение зависит от слоя:**

- **`_live/`** — ADR обычно НЕ нужен (фронт меняется быстро, ADR создаст шум).
  Просто добавить запись в `_live/timeline.md` и обновить соответствующий
  `_live/frontline-*.md`. timeline.md — append-only, не правим старое.

- **`_reference/`** — да, ADR если breaking change архитектурного уровня
  (примеры: «Reality официально сломан в РФ», «sing-box-vt удалён из App Store»,
  «новый эталонный клиент вытесняет sing-box»). Шаблон —
  `decisions/0000-template.md` в публичном репо или `$INFRA/decisions/` приватной
  `infra/`.

- **`_meta/`** — обновление через сам файл (`conflicts.md` для расхождений,
  `sources-registry.md` для новых источников), без ADR.

## Шаг 7: Краткий отчёт

```
✅ Актуализация VPN-knowledge завершена

Файлы обновлены с изменениями: 2
  • vpn-protocols.md — §3.3 (новая инфа про Tatarstan), +1 источник
  • client-apps.md — §2 (новая версия sing-box 1.13), +1 источник

Файлы обновлены без изменений (контент актуален, только дата): 2
  • 3x-ui-panel.md
  • 3x-ui-api.md

Tavily-запросов потрачено: 3 / 5 (осталось бюджета)
Web-запросов через WebSearch: 12 (бесплатно)
ADR создан: $INFRA/decisions/0006-reality-fallback-microsoft.md (если был сдвиг)

Все 4 файла теперь last_researched=2026-06-15.
Следующая проверка авто-сработает через 30 дней или при первой VPN-задаче.
```

# Анти-паттерны

- **Не правь knowledge молча.** Каждое изменение текста — Yellow Zone, подтверждение.
- **Не жги Tavily-лимит.** Сначала WebSearch (бесплатно), потом Tavily только за
  подтверждением. Бюджет $TAVILY_BUDGET — жёсткий, не превышай.
- **Не обновляй last_researched без проверки.** Если оператор сказал «всё ок,
  не лезь» по конкретному файлу — это явное решение, а не пропуск. Запоминай его.
- **Не считай отсутствие изменений в WebSearch гарантией актуальности.**
  Если файл старше 90 дней и в Tavily-бюджете осталось — сделай хотя бы один
  Tavily-запрос, чтобы убедиться что не пропустил.
- **Не правь несколько файлов одним коммитом без разделения.** Если каждый
  файл актуализирован отдельно — это отдельные логические изменения, делай
  отдельные коммиты с описанием что именно изменилось.
