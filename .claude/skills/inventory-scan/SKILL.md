---
name: inventory-scan
description: |
  Read-only инвентаризация сервера: dump-snapshot.sh → 8 документов в inventory/ (services,
  networks, volumes, databases, domains, cron, host-scripts, server). Сравнение с прошлым
  inventory с выделением drift'ов. Green Zone.
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
- Docker установлен и работает на сервере
- Структура `inventory/hosts/<host>/` существует или будет создана при первом запуске

Что НЕ предполагается:
- Mock-сервер или dry-run — скилл нужен для реального снимка реальности
- Изменение состояния сервера — это Yellow/Red Zone, для них есть другие скиллы
  (cleanup-existing-server, deploy-service)
- Наличие свежего бэкапа — скилл read-only, бэкапы не нужны
</context>

<goals>
После выполнения:
- Snapshot создан в `inventory/hosts/<host>/snapshots/YYYY-MM-DD/`
- Snapshot содержит все ожидаемые файлы (containers, networks, volumes, host-resources,
  crontab, nginx-sites, tls-certs, host-scripts-content, host-env-redacted, cron-d-content,
  systemd-enabled, compose-files, containers-inspect.json)
- 8 inventory-документов в `inventory/hosts/<host>/` обновлены или созданы из шаблона
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

Проверяю предусловия одной командой:

```bash
# SSH-доступ
ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_HOST" 'echo ok' || {
  echo "ОШИБКА: SSH-доступ к $SSH_HOST не настроен"; exit 1; }

# Существующий inventory
ls "$INVENTORY_DIR/hosts/" 2>/dev/null || mkdir -p "$INVENTORY_DIR/hosts/"
```

Если SSH не настроен — стоп, без выдумывания «возможно, ключ ниже». Прошу оператора
проверить ключ и повторить.

## Шаг 2. Запуск dump-snapshot.sh

```bash
bash scripts/dump-snapshot.sh "$SSH_HOST" "$SNAPSHOT_DATE"
```

Скрипт собирает (через single-shot SSH с timeout 10c):

- Список и inspect контейнеров (`containers.txt`, `containers-inspect.json`)
- Список compose-файлов (`compose-files.txt`)
- Docker-сети и volumes (`networks.txt`, `volumes.txt`)
- Ресурсы хоста — uptime, память, диск, открытые порты, доступные APT-обновления
  (`host-resources.txt`)
- Crontab + `/etc/cron.d/*` (`crontab.txt`, `cron-d-content.txt`)
- nginx-конфиг через `nginx -T` (`nginx-sites.txt`)
- TLS-сертификаты Let's Encrypt — даты валидности через `openssl x509`
  (`tls-certs.txt`)
- Список и содержимое host-скриптов в `/opt/*.sh` (`host-scripts-list.txt`,
  `host-scripts-content.txt`)
- Структура .env-файлов на хосте (имена переменных, значения redacted)
  (`host-env-redacted.txt`)
- Включённые systemd-юниты (`systemd-enabled.txt`)
- Метаданные снимка (`meta.txt`)

Verify: snapshot-директория не пуста, размер ≥1 МБ, есть хотя бы 14 файлов.

```bash
SNAPSHOT_DIR="$INVENTORY_DIR/hosts/<HOST_DIR>/snapshots/$SNAPSHOT_DATE"
[ -d "$SNAPSHOT_DIR" ] && [ "$(ls -1 "$SNAPSHOT_DIR" | wc -l)" -ge 14 ] || \
  { echo "ОШИБКА: snapshot неполный"; exit 1; }
```

Где `<HOST_DIR>` = `prod-<ip>` для удалённых или `local-<hostname>` для локальной машины.

## Шаг 3. Сравнение с существующим inventory

Для каждого из 8 документов сверяю snapshot с тем, что записано:

```bash
# Контейнеры
diff <(jq -r '.[].Name' "$SNAPSHOT_DIR/containers-inspect.json" | sort) \
     <(grep -oE 'container_name: \S+' "$INVENTORY_DIR/hosts/<host>/services.md" | sort)
```

Drift-категории:
- **drift+** — есть в реальности, нет в inventory (новый сервис не задокументирован)
- **drift-** — есть в inventory, нет в реальности (удалили, документация не обновлена)
- **drift~** — расхождение в полях (порт, образ, статус)

Результат — `$SNAPSHOT_DIR/drift-report.md`. Если drift'ов нет — пишу
«drift'ов не найдено, inventory синхронен».

## Шаг 4. Обновление 8 inventory-документов

Для каждого документа (services / networks / volumes / databases / domains / cron /
host-scripts / server):

- Если документ существует — `Edit` правлю изменённые строки, добавляю пометку
  `<!-- snapshot YYYY-MM-DD: было X, стало Y -->` рядом со старым значением
- Если не существует — генерирую из `templates/inventory-doc-template.md`,
  подставляю данные из snapshot

Никогда не переписываю файл с нуля — теряется история ручных правок и комментариев
оператора.

## Шаг 5. Honest unknown — везде

Если данные не получены (snapshot-файл пустой, syntax error, поле отсутствует) —
ставлю `? уточнить` или `нет данных`. **NEVER** выдумываю правдоподобные значения.

Это правило перекрывает любые другие — лучше пустое поле, чем красивая ложь.
Подробнее — `references/dump-snapshot-quirks.md` (известные баги и их симптомы).

## Шаг 6. Cleanup старых snapshots

```bash
# Оставляем последние RETENTION_SNAPSHOTS, остальные удаляем
find "$INVENTORY_DIR/hosts/<host>/snapshots/" -mindepth 1 -maxdepth 1 -type d \
  | sort -r | tail -n +$((RETENTION_SNAPSHOTS+1)) | xargs -r rm -rf
```

Сортировка по имени (snapshots датированы), не по `-mtime` — `find -mtime +N` округляет
вниз до целых дней (типичная грабля при чистке временных файлов).

## Шаг 7. Отчёт оператору

Формирую короткий отчёт в чат:
- Дата и путь нового snapshot
- Размер snapshot (МБ)
- Список drift'ов (если найдены) — с категориями + / - / ~
- Список изменённых inventory-документов
- Рекомендации, если нужно: что ещё проверить вручную

# Failed Attempts (граблекейс)

- **«tls-certs.txt syntax error»** — известный баг dump-snapshot v1, в v2 исправлен
  через `set +e` вокруг openssl-вызова. Симптом: tls-certs.txt пустой или содержит
  «openssl: unknown option». Лечение: убедиться, что используется bundled
  `scripts/dump-snapshot.sh` (v2), а не старый из `~/scripts/`.
- **«SSH-alias из ~/.ssh/config не работает в bash sandbox»** — sandbox запускает bash
  без загрузки пользовательской конфигурации SSH. Лечение: использовать прямой
  `user@host` вместо алиаса, ключ через `-i` если нужен явный.
- **«find -mtime +N округляет вниз»** — `find -mtime +1` найдёт файлы старше **2 дней**,
  а не 1. Для retention снимков использовать сортировку по имени, не -mtime.
- **«python-regex редакция не покрывает все паттерны»** — `host-env-redacted.txt`
  маскирует только `=value`, но в URL вида `postgres://user:pass@host` пароль
  виден. Лечение: добавлять новые regex-паттерны при обнаружении (см.
  `references/dump-snapshot-quirks.md`).
- **«gitleaks ругается на containers-inspect.json»** — env-переменные внутри Docker
  inspect видны как plain text. Файл лежит в `inventory/snapshots/` (gitignored по
  умолчанию), в публичный репо не попадает. Если нужно сохранить — отдельно
  redact через `jq`.

# Граничные случаи

- **Сервер недоступен (down)** — скилл валит с явной ошибкой ещё на Pre-check, не
  генерирует пустой snapshot
- **Disk full на сервере** — некоторые секции snapshot частично собраны, отчёт явно
  говорит «частичный snapshot, причина: disk full». В drift-report не доверяем
  частичным данным
- **Контейнер в restart loop** — попадает в snapshot со статусом `Restarting (N)`,
  в drift-report помечается отдельно как «требует внимания»
- **Несколько серверов** — переключаются параметром `SSH_HOST`. Не запускать
  одновременно (нет locking) — снимки будут вперемешку
- **Локальный режим (`SSH_HOST=local`)** — собирает данные с локальной машины через
  `eval`, не SSH. Полезно для разработки или mock-инфраструктуры

# Bundled resources

- `scripts/dump-snapshot.sh` — основной dump-скрипт (v2, копия из
  `scripts/inventory/dump-snapshot.sh` проекта-носителя)
- `templates/inventory-doc-template.md` — общий шаблон inventory-документа
- `references/dump-snapshot-quirks.md` — известные баги, симптомы, обходы