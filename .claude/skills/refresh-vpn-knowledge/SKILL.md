---
name: refresh-vpn-knowledge
description: |
  Актуализация VPN-knowledge базы (`.claude/knowledge/networking/`) когда
  её содержимое старше TTL (по умолчанию 30 дней). Сценарий: блокировки и
  TSPU-сигнатуры в РФ меняются быстро, выходят новые версии клиентов sing-box/
  Hiddify/Karing, появляются issues в 3X-UI — без актуализации агент работает
  с устаревшей картой и рекомендует уже сломанное.
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
- VPN-knowledge живёт в `.claude/knowledge/networking/` (4 файла: vpn-protocols.md,
  3x-ui-panel.md, 3x-ui-api.md, client-apps.md).
- Каждый файл имеет frontmatter с полями `knowledge_domain: vpn`, `last_researched`,
  `ttl_days`, `sources_checked` (см. helper `_lib/check-knowledge-freshness.sh`).
- Tavily MCP-сервер настроен (1000 запросов/мес бесплатно), WebSearch встроен.
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
- `DOMAIN` — какой knowledge-домен актуализировать (default: `vpn`).
- `FILES` — конкретные файлы через запятую, для точечной актуализации
  (default: все просроченные в домене).
- `MODE` — `check` (только показать что устарело, не лезть в сеть) /
  `full` (полный цикл с WebSearch+Tavily) (default: `full`).
- `TAVILY_BUDGET` — сколько Tavily-запросов максимум (default: 5 — экономим лимит).
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

STALE_COUNT=$(echo "$STALE" | jq 'length')
```

**Если `STALE_COUNT=0`** — выводим оператору одну строку и выходим:
> «Все VPN-knowledge файлы в актуальном TTL (30 дней). Проверять нечего.»

**Если есть просроченные** — показываем список:
```
Просроченные VPN-knowledge:
  ⚠️  client-apps.md      — last_researched 2026-04-01 (45 дней, TTL 30)
  ⚠️  vpn-protocols.md    — last_researched 2026-03-20 (57 дней, TTL 30)
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
   FILE=".claude/knowledge/networking/vpn-protocols.md"
   SOURCES=$(awk '/^---$/{c++; next} c==1 && /^  - /{sub("^  - ", ""); print}' "$FILE" | head -10)
   ```

2. Для каждого URL — WebSearch с запросом контекста файла:
   - vpn-protocols.md: `"Russia VPN blocks TSPU 2026" + "Reality protocol blocked"`
   - client-apps.md: `"sing-box iOS client 2026" + "Hiddify release notes"`
   - 3x-ui-panel.md: `"3x-ui release 2026 changelog" + "MHSanaei issues open"`
   - 3x-ui-api.md: `"3x-ui API breaking change 2026"`

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

## Шаг 3: Tavily research (по бюджету)

Только для файлов, где WebSearch нашёл изменения, делаю глубокий research через
`mcp__tavily__tavily_research`:

```
Q: "Что изменилось в реальности блокировок РФ VPN с 2026-05-15 по сегодня?
    Особенно интересуют: Reality protocol, sing-box iOS, TSPU сигнатуры,
    блокировки конкретных провайдеров."
```

Tavily возвращает структурированный синтез с цитатами. **Бюджет жёсткий**:
не более `$TAVILY_BUDGET` запросов за весь прогон скилла. Если бюджет исчерпан
— переключаюсь обратно на WebSearch+WebFetch (бесплатно, но менее глубоко).

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

## Шаг 6: Если найден критический сдвиг — ADR

Если в Tavily-research найдено **breaking change** (примеры: «Reality официально
сломан в РФ», «sing-box-vt удалён из App Store», «новый эталонный клиент
вытесняет sing-box»), предлагаю оператору:

> «Я обнаружил критическое изменение: <описание>. Это влияет на наш ADR-0005
> "VPN-архитектура". Хочешь, создам новый ADR в `$INFRA/decisions/` с обоснованием
> миграции на <новое решение>?»

ADR пишется по шаблону `decisions/0000-template.md` приватной `infra/` оператора.

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
