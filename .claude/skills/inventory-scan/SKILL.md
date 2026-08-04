---
name: inventory-scan
description: |
  Read-only инвентаризация сервера: dump-snapshot.sh → 9 текстовых документов в inventory/
  (services, networks, volumes, databases, domains, cron, host-scripts, automations, server).
  Сравнение с прошлым inventory с выделением drift'ов + чек «хлам» (сироты-volume, сети вне
  эталона, дубли compose) + чек «дрейф IaC» (репозиторий конфигураций ↔ сервер в обе стороны:
  vhost, каталоги стеков, вызовы деплоя, конфигурация только на сервере).
  Диаграммы не генерирует (ADR-0019: источник фактов — снимок,
  витрина — дашборд). Green Zone.
  Работает и на хостах БЕЗ Docker (нативный VPS: 3X-UI, nginx, systemd-сервисы) — снимок
  собирается по systemd/портам/nginx/TLS/firewall, секции контейнеров помечаются
  неприменимыми (ADR-0024).
  Триггеры: «инвентаризация», «снять снимок сервера», «что у меня на сервере», «обновить inventory»,
  «scan server», «inventory drift», «refresh inventory».
  НЕ для изменений на сервере (это cleanup-existing-server и др.); НЕ для аудита безопасности
  (audit-security).
allowed-tools: Bash, Read, Edit, Write
---

<role>
Я снимаю полный снимок реального состояния сервера, генерирую или обновляю текстовый
inventory и выделяю drift'ы между документацией и реальностью. Я работаю в Green Zone —
только чтение, никаких изменений на сервере.
</role>

<context>
Что предполагается:
- SSH-доступ к серверу настроен (агентский ключ, BatchMode=yes работает)
- Структура `inventory/hosts/<host>/` существует или будет создана при первом запуске

**Docker НЕ обязателен (ADR-0024).** Нативный VPS без Docker снимается полностью — по
systemd, портам, nginx, TLS, firewall, cron. Тип хоста объявляет `host_kind` в `meta.txt`:
`docker` (демон отвечает) / `native` (Docker не установлен) / `docker-down` (CLI есть,
демон молчит). От типа зависят verify на Шаге 2 и содержание документов на Шаге 4 —
разбор всех трёх в `references/snapshot-contents.md`.

Что НЕ предполагается:
- Mock-сервер или dry-run — скилл нужен для реального снимка реальности
- Изменение состояния сервера — это Yellow/Red Zone, для них есть другие скиллы
  (cleanup-existing-server, deploy-service)
- Наличие свежего бэкапа — скилл read-only, бэкапы не нужны
</context>

<goals>
После выполнения:
- Snapshot создан в `inventory/hosts/<host>/snapshots/YYYY-MM-DD/`
- Snapshot содержит все ожидаемые файлы (состав — `references/snapshot-contents.md`) —
  проверяется по непустоте ключевых, не по суммарному размеру
- 9 inventory-документов в `inventory/hosts/<host>/` обновлены или созданы из шаблона
  (`automations.md` — только при наличии хоть одной автоматизации)
- Drift между inventory и реальностью явно обозначен в `drift-report.md` свежего snapshot
- Honest unknown применён везде, где данные отсутствуют (`? уточнить` или `нет данных` —
  никаких выдуманных значений)
</goals>

# Параметры

| Параметр | Default | Описание |
|----------|---------|----------|
| `SSH_HOST` | (обязательный) | SSH-target — `user@<your-server-ip>`, SSH-алиас из `~/.ssh/config` или `local` (без SSH) |
| `INVENTORY_DIR` | `inventory` | Корневая папка inventory (относительно репо) |
| `SNAPSHOT_DATE` | `$(date +%Y-%m-%d)` | Дата снимка (формат YYYY-MM-DD) |
| `RETENTION_SNAPSHOTS` | `10` | Сколько последних snapshots оставлять |

# Процедура

## Шаг 1. Pre-check

```bash
# SSH-доступ
ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_HOST" 'echo ok' || {
  echo "ОШИБКА: SSH-доступ к $SSH_HOST не настроен"; exit 1; }

# Существующий inventory
mkdir -p "$INVENTORY_DIR/hosts/"

# Конкурентный лок (P22): два одновременных скана пишут в одни файлы → гонка.
# Атомарно через mkdir (НЕ -p: падает, если каталог уже есть). Зависший лок
# старше 30 мин (предыдущий скан упал) снимаем как stale.
LOCK="$INVENTORY_DIR/.scan.lock"
[ -d "$LOCK" ] && find "$LOCK" -maxdepth 0 -mmin +30 2>/dev/null | grep -q . && {
  echo "→ лок старше 30 мин — снимаю как зависший (stale)."
  rm -f "$LOCK/started_at" 2>/dev/null; rmdir "$LOCK" 2>/dev/null; }
if mkdir "$LOCK" 2>/dev/null; then
  date -u +%Y-%m-%dT%H:%M:%SZ > "$LOCK/started_at" 2>/dev/null
  echo "→ лок inventory-scan взят: $LOCK"
else
  echo "СТОП: уже идёт inventory-scan (лок $LOCK, начат $(cat "$LOCK/started_at" 2>/dev/null || echo '?'))."
  echo "      Дождись его завершения. Если уверен, что скан не идёт — сними лок вручную:"
  echo "      rm -f \"$LOCK/started_at\" && rmdir \"$LOCK\""
  exit 1
fi
```

> ⚠️ **Снятие лока — две команды подряд, БЕЗ функции и БЕЗ рекурсивного удаления.**
> Именно так, и вот почему — три причины, все выяснены живым прогоном 2026-07-25:
>
> 1. **`rmdir` физически не может снести дерево.** При опечатке в `$LOCK` он просто
>    откажется (каталог непуст), а рекурсивное удаление снесло бы всё молча.
> 2. **Замок красной зоны (ADR-0022) блокирует рекурсивное удаление по переменной** —
>    он не знает, что внутри неё, и обязан считать боевым путём. С прежней формулировкой
>    Шаги 1 и 7 этого зелёного скилла были невыполнимы в принципе.
> 3. **Функцию заводить нельзя.** Claude Code исполняет ```bash-блоки скилла **в разных
>    процессах**, и объявленная в одном блоке функция в другом не существует. Первая
>    попытка вынести снятие лока в `release_lock()` дала мёртвую ветку: вызов стоял в
>    Шаге 1, объявление — ниже и в другом блоке, а Шаг 7 звал функцию из третьего.
>    Обе команды самодостаточны — их можно повторить дословно где угодно.
>
> Не «упрощать» ни обратно к рекурсивному удалению, ни вперёд к функции.

SSH не настроен — стоп, без выдумывания «возможно, ключ ниже». Прошу оператора проверить
ключ и повторить. **Лок держится до Шага 7** (снимается теми же двумя командами в конце
или при любой отмене, иначе следующий скан заблокирован).

## Шаг 2. Запуск dump-snapshot.sh

**Каноничное имя папки хоста — из `infra-config.json` `servers[].alias`**, не из
SSH-аргумента: иначе алиас раздвоит inventory (грабля в `references/dump-snapshot-quirks.md`).
Резолвлю канон и передаю в скрипт через env `HOST_DIR`:

```bash
INFRA="$(dirname "$INVENTORY_DIR")"
HOST_DIR="$(jq -r '.servers[0].alias // empty' "$INFRA/infra-config.json" 2>/dev/null)"
export HOST_DIR   # пусто → скрипт выведет из SSH-target (fallback)
bash scripts/dump-snapshot.sh "$SSH_HOST" "$SNAPSHOT_DATE" "$INVENTORY_DIR"
```

Что именно собирается в каждую секцию снимка — `references/snapshot-contents.md`
(таблица «файл → что внутри»). Читать её нужно на Шаге 4, когда заполняешь документы.

**Verify по СОДЕРЖАНИЮ, не по суммарному размеру.** Малый сервер даёт снимок <1 МБ — это
норма. Набор ключевых файлов зависит от типа хоста (ADR-0024): на нативном требовать
непустой `containers.txt` бессмысленно — там законная заглушка `NOT_APPLICABLE`.

```bash
SNAPSHOT_DIR="$INVENTORY_DIR/hosts/$HOST_DIR/snapshots/$SNAPSHOT_DATE"
ok=1
HOST_KIND=$(grep '^host_kind:' "$SNAPSHOT_DIR/meta.txt" | awk '{print $2}')

# Общие для любого хоста: ресурсы, systemd-сервисы, firewall.
# МАССИВ, а не строка: zsh (оболочка macOS по умолчанию) не дробит `$VAR` на слова,
# и `for f in $KEY_FILES` даёт ОДНУ итерацию со слипшимися именами — валидный снимок
# объявляется битым. Проверено живым прогоном 2026-07-25 на zsh 5.9.
KEY_FILES=(host-resources.txt host-services.txt firewall.txt)
# Контейнерные — только там, где Docker реально работает
[ "$HOST_KIND" = "docker" ] && KEY_FILES+=(containers.txt networks.txt)

for f in "${KEY_FILES[@]}"; do
  [ -s "$SNAPSHOT_DIR/$f" ] || { echo "ОШИБКА: пустой ключевой файл $f"; ok=0; }
done
jq -e . "$SNAPSHOT_DIR/containers-inspect.json" >/dev/null 2>&1 \
  || { echo "ОШИБКА: containers-inspect.json не парсится"; ok=0; }
[ "$ok" = 1 ] || { echo "ОШИБКА: snapshot неполный"; exit 1; }
echo "Снимок валиден (host_kind=$HOST_KIND)"
```

Где `$HOST_DIR` = канон из `infra-config.json` (`prod-<ip>` для удалённых или
`local-<hostname>` для локальной машины).

## Шаг 3. Сравнение с существующим inventory

Две независимые оси сравнения — **не смешивать** (их смешение даёт «мнимый drift», когда
снимок просто старее обновлённого inventory):

**Ось A — что изменилось на сервере** (снимок-к-снимку, стабильный источник
`containers-inspect.json`, НЕ grep по рукописному `services.md`):

```bash
HOSTD="$INVENTORY_DIR/hosts/$HOST_DIR"
PREV="$(ls -1d "$HOSTD/snapshots"/*/ 2>/dev/null | sort | tail -2 | head -1)"
diff <(jq -r '.[].Name' "$PREV/containers-inspect.json" 2>/dev/null | sed 's#^/##' | sort) \
     <(jq -r '.[].Name' "$SNAPSHOT_DIR/containers-inspect.json"      | sed 's#^/##' | sort)
```

**Ось B — что не задокументировано** (реальность ↔ `services.md`). `services.md` ведёт
контейнеры **таблицей** `| имя | … |`, поэтому проверяю присутствие каждого имени как
ячейки, а не паттерном `container_name:`:

```bash
for name in $(jq -r '.[].Name' "$SNAPSHOT_DIR/containers-inspect.json" | sed 's#^/##'); do
  grep -qE "^\| *$name *\|" "$HOSTD/services.md" || echo "drift+ (не задокументирован): $name"
done
```

**Тома** сверяю по ИМЕНАМ (`docker volume ls` — часть `volumes.txt` ДО строки `---`),
не по `docker system df` (волатильные относительные даты `3 weeks ago` дают шум-diff).

Drift-категории: **drift+** (есть в реальности, нет в inventory) / **drift-** (есть в
inventory, нет в реальности) / **drift~** (расхождение полей — порт, образ, статус).

**Чек «хлам»** (якорь §3.10 персоны, «как в аптеке») — отдельная секция drift-отчёта:

```bash
# 1. Анонимные volume без потребителей (сироты restore-тестов/миграций)
grep -E "^local +[0-9a-f]{64}$" "$SNAPSHOT_DIR/volumes.txt" || true
# в volumes.txt (docker system df -v) сирота = LINKS 0 у hash-имени
# 2. Сети вне эталона: всё, что не {data, services, proxy-corridor/xray, monitoring,
#    bridge, host, none} — особенно автосети compose <project>_default
# 3. Дубли compose: один container_name в двух working_dir
jq -r '.[] | .Name + "\t" + (.Config.Labels["com.docker.compose.project.working_dir"] // "-")' \
  "$SNAPSHOT_DIR/containers-inspect.json"
# + сверить compose-files.txt: файлы, не породившие ни одного контейнера
# 4. Публичные порты (0.0.0.0/*) из host-resources.txt без владельца в services/server.md
```

Каждая находка — в секцию `## Хлам` drift-отчёта с предложением сноса. Сам не удаляю
(Green Zone + C.7) — решает оператор.

**Чек «дрейф IaC»** (репозиторий конфигураций `$INFRA/services/` ↔ сервер) — вторая
секция отчёта. Прежние чеки сравнивают inventory с реальностью; между репозиторием и
сервером дрейф не ловил никто, и он растёт в обе стороны.

```bash
# 1. vhost: что включено на сервере vs что записано в репозитории
ssh "$HOST" 'ls /etc/nginx/sites-enabled/' | sed 's/\.conf$//' | sort > /tmp/nginx-server.txt
ls "$INFRA/services/nginx/sites-available/" | sed 's/\.conf$//' | sort > /tmp/nginx-repo.txt
comm -23 /tmp/nginx-server.txt /tmp/nginx-repo.txt   # работает, но НЕ в репозитории — опаснее
comm -13 /tmp/nginx-server.txt /tmp/nginx-repo.txt   # лежит в репозитории, но не включено

# 2. каталоги стеков: порождают ли контейнер или юнит
for d in "$INFRA"/services/*/; do
  n=$(basename "$d")
  ssh "$HOST" "docker ps -a --format '{{.Names}}' | grep -qx '$n' \
    || grep -rqs '$n' /etc/systemd/system/ /etc/cron.d/ || echo 'кандидат в мусор: $n'"
done

# 3. вызовы в деплое, потерявшие адресата
grep -oE 'redeploy_if_touched "[^"]+"' "$INFRA/deploy.sh" | cut -d'"' -f2 | while read -r p; do
  [ -d "$INFRA/$p" ] || echo "деплой зовёт несуществующий путь: $p"
done

# 4. конфигурация, живущая ТОЛЬКО на сервере (обратный дрейф — самый незаметный)
#    fail2ban, conf.d, systemd-юниты своих сервисов: есть на сервере, нет в репозитории
```

**Направление важнее факта.** «Лишнее в репозитории» — беспорядок. «Есть на сервере, нет
в репозитории» — **потеря при восстановлении**: об этом классе говорю оператору первым.

**Кандидат в мусор ≠ мусор.** Каталог без контейнера может обслуживать хост-сервис.
Прежде чем предлагать снос, ищу упоминания в юнитах, `cron.d` и скриптах; нашёл — пишу
«используется, не трогать». Боевые примеры обоих правил — в
`references/dump-snapshot-quirks.md`, раздел про дрейф IaC.

Результат — `$SNAPSHOT_DIR/drift-report.md`. Нет drift'ов — пишу «drift'ов не найдено,
inventory синхронен». **Мнимый drift** (снимок старее, чем уже обновлённый inventory)
помечаю отдельно как объяснённый, не как реальное расхождение.

## Шаг 4. Обновление 9 inventory-документов

Для каждого документа (services / networks / volumes / databases / domains / cron /
host-scripts / automations / server):

- Документ существует — `Edit` правлю изменённые строки, добавляю пометку
  `<!-- snapshot YYYY-MM-DD: было X, стало Y -->` рядом со старым значением
- Не существует — генерирую из `templates/inventory-doc-template.md`, подставляю данные
  из snapshot

Никогда не переписываю файл с нуля — теряется история ручных правок и комментариев
оператора.

**Какой файл снимка отвечает за какую секцию документа — `references/snapshot-contents.md`.**
Там же: чем заполнять документы на нативном хосте и на `docker-down`, и как собирается
витрина `automations.md` (колонки, четыре источника, главная колонка `touches`).

**Хост-сервисы вне Docker** (из `host-services.txt`) веду в `services.md` отдельной
секцией «Хост-сервисы (не Docker)» — имя, роль, как запущен, что трогает. Ожог: сервис на
systemd + venv был невидимкой для `docker ps` и списка compose, из-за чего его БД
посчитали бесхозной и удалили.

## Шаг 5. Honest unknown — везде

Данные не получены (файл снимка пуст, syntax error, поле отсутствует) — ставлю
`? уточнить` или `нет данных`. **NEVER** выдумываю правдоподобные значения.

Это правило перекрывает любые другие — лучше пустое поле, чем красивая ложь.
Секция подозрительно пуста — до вердикта загляни в `references/dump-snapshot-quirks.md`:
у половины пустых секций известная причина и обход.

## Шаг 5.5. Сверка паспортов карточек (дёшево, раз в прогон)

Шаги выше сверяют **состояние сервера**. Шапки карточек проектов при этом не проверяет
никто — а они стареют молча: репозиторий переименовали, закрытый открыли, источник переехал.
Утверждение «репозиторий приватный» про публичный — не косметика: на нём строятся решения
о том, что можно писать в код.

Для каждого репозитория, объявленного в карточках `inventory/projects/*.md`:

```bash
# Реальный адрес — из самого клона на сервере, а не из карточки.
ssh "$HOST" 'for d in /opt/apps/*/; do
    url=$(git -C "$d" remote get-url origin 2>/dev/null) || continue
    printf "%s\t%s\n" "$d" "$url"
done'
# Видимость — если у оператора есть gh. Нет gh — так и пишу «не проверено».
gh repo view "<owner>/<repo>" --json visibility -q .visibility
```

Расхождение → правлю **шапку карточки** и ставлю дату сверки. Историю (датированные абзацы
ниже по документу) не переписываю: вместо этого таблица соответствия старых и новых имён
в шапке. Нет `gh` или доступа — пишу «видимость не проверена», а не догадку (C.2).

**Грабля 2026-08-04:** карточка проекта два раза правилась в одной сессии и оба раза мимо
шапки, где стояли имена трёх репозиториев до переименования, все помечены приватными, —
хотя четыре из них были открыты двумя днями раньше. Сверка случилась только по прямому
вопросу оператора.

## Шаг 6. Cleanup старых snapshots

```bash
# Оставляем последние RETENTION_SNAPSHOTS, остальные удаляем
find "$INVENTORY_DIR/hosts/<host>/snapshots/" -mindepth 1 -maxdepth 1 -type d \
  | sort -r | tail -n +$((RETENTION_SNAPSHOTS+1)) | xargs -r rm -rf
```

Сортировка по имени (snapshots датированы), не по `-mtime`: `find -mtime +N` округляет
вниз до целых дней.

## Шаг 7. Отчёт оператору

Формирую короткий отчёт в чат:
- Дата и путь нового snapshot
- **Сводка здоровья из `health-flags.txt`** — подаю готовое (swap%, disk%, loadavg,
  exited-контейнеры, OOM-137, отложенные apt/security-обновления), не грепаю сырьё руками
- **Enforcement `automations.md`:** если в снимке есть автоматизации (непустые cron/
  systemd-timers/watchers), а `inventory/hosts/$HOST_DIR/automations.md` отсутствует —
  отдельной строкой «автоматизации есть, витрина не создана → нужен Шаг 4»
- Список drift'ов (если найдены) — с категориями + / - / ~; мнимый drift помечен отдельно
- **Секция «Хлам»** (если чек Шага 3 что-то нашёл): каждая находка с предложением сноса
- Список изменённых inventory-документов
- Рекомендации, если нужно: что ещё проверить вручную

Освобождаю конкурентный лок (взят на Шаге 1) — иначе следующий скан упрётся в «уже идёт»:

```bash
# Те же две команды, что в Шаге 1 — самодостаточные, функцию заводить нельзя
# (блоки скилла исполняются в разных процессах).
rm -f "$LOCK/started_at" 2>/dev/null; rmdir "$LOCK" 2>/dev/null
```

# Bundled resources

| Файл | Что это и когда открывать |
|---|---|
| `references/snapshot-contents.md` | **Состав снимка**: какой файл на какой вопрос отвечает, три типа хоста (`docker`/`native`/`docker-down`) и чем заполнять документы на каждом, устройство витрины `automations.md`. Открывать на Шаге 4 и когда секция снимка пуста |
| `references/dump-snapshot-quirks.md` | **Когда снимок ведёт себя странно**: известные баги, симптомы, обходы, редакция секретов, грабли самой процедуры скана, граничные случаи (сервер down, disk full, restart loop, несколько серверов, `SSH_HOST=local`) |
| `scripts/dump-snapshot.sh` | основной dump-скрипт (v2, копия из `scripts/inventory/dump-snapshot.sh` проекта-носителя) |
| `templates/inventory-doc-template.md` | общий шаблон inventory-документа |
| `tests/test-native-host.sh` | регрессионный тест сбора на хосте без Docker; прогон вручную |
