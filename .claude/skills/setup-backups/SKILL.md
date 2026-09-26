---
name: setup-backups
description: |
  Бэкапы с нуля: restic для encrypted snapshots, хранилище — offsite (S3 / B2 / WebDAV —
  Яндекс.Диск, NextCloud) ИЛИ свой второй сервер по SFTP, retention 7+4+6
  (daily+weekly+monthly), алерт «бэкап >36 ч» в Telegram/Slack/email, обязательный прогон
  restore на временный контейнер. Покрывает БД (PostgreSQL, MySQL, Redis dump).
  Триггеры: «нужны бэкапы», «настрой backup», «restic с retention», «offsite на S3/WebDAV/Backblaze»,
  «бэкап на свой второй сервер», «бэкап по SFTP», «без бэкапов нельзя ничего менять».
  НЕ для бэкапа uploads/файлов (это отдельный шаблон); НЕ для setup без настроенного хранилища.
allowed-tools: Bash, Read, Edit, Write
---

<role>
Я настраиваю инфраструктуру бэкапов так, чтобы у оператора больше никогда не было «надежды
вместо бэкапа». Реальный прогон restore на временный контейнер — обязательная часть скилла;
без подтверждённого восстановления хотя бы одной БД скилл не считается завершённым.
</role>

<context>
Что предполагается на сервере:
- Docker и хотя бы одна БД (PostgreSQL / MySQL / Redis), которую нужно бэкапить
- Хранилище для бэкапов настроено (S3 bucket / Backblaze B2 / WebDAV-endpoint типа
  Яндекс.Диск / NextCloud)
- Креденшелы хранилища доступны через менеджер паролей (Keychain / pass / KeePassXC / ...)
- Канал алертов настроен (Telegram-бот / Slack webhook / email — опционально,
  но рекомендуется)

Что НЕ предполагается:
- Настройка хранилища с нуля (это отдельная задача, делает оператор)
- Бэкап файловых uploads приложений (отдельный шаблон, не входит в этот скилл)
- БД на отдельной машине / managed Cloud DB — другой подход, не покрывается
</context>

<goals>
После выполнения должно стать TRUE:
- restic-репозиторий создан с шифрованием AES-256, passphrase в менеджере паролей
- Скрипты дампа БД установлены (`backup-postgres.sh` / `backup-mysql.sh` / `backup-redis.sh`)
- Оркестратор `backup-all.sh` запускает все БД-дампы и заливает их через restic
- Cron-расписание установлено в `/etc/cron.d/backup` (бэкап в 03:00, проверка возраста в 09:00)
- `check-backup-age.sh` отправляет алерт «бэкап старше 36 часов» в канал оператора
  (Telegram / Slack / email — настраивается параметрами)
- Runbook `runbooks/backup-restore.md` сгенерирован по шаблону под конкретный сервер
- **Restore test пройден** — одна из БД восстановлена на временный контейнер, row counts сверены с продом
</goals>

# Шаг 0: Чтение конфига (STRICT)

Скилл — STRICT-режим: без конфига инфры (`infra-config.json`) он не запускается. Конфиг определяет, куда складываются бэкапы (S3 / B2 / WebDAV / свой сервер по SFTP), какая retention, нужны ли Telegram-алерты и в каком менеджере паролей искать `restic`-passphrase. Без этих решений скилл угадывал бы намерения — это запрещено правилами агента.

Используй общий helper `_lib/find-config.sh` (единая точка изменения для всех
STRICT/OPTIONAL скиллов — алгоритм идентичен Cold Start Protocol персоны).
`$SYSADMIN_ROOT` запоминается на Шаге 1 Cold Start.

```bash
source "$SYSADMIN_ROOT/.claude/skills/_lib/find-config.sh"

# STRICT: exit 1 с понятным сообщением если конфига нет
find_sysadmin_config strict       # $CONFIG = infra-config.json (backups/notifications)
find_brain_config || true         # $BRAIN_CONFIG = agent-config.json (secrets.manager)

# secrets.manager — агент-поле (ADR-0013): живёт в мозге ($BRAIN_CONFIG).
# Legacy-совместимость: если мозга нет — читаем из $CONFIG (старый единый формат).
get_agent_field() {  # $1=jq-путь, $2=default (путь одинаков в мозге и legacy)
  local v=""
  [ -n "${BRAIN_CONFIG:-}" ] && v=$(jq -r "$1 // empty" "$BRAIN_CONFIG" 2>/dev/null)
  [ -z "$v" ] && [ -n "${CONFIG:-}" ] && [ -f "${CONFIG:-}" ] && v=$(jq -r "$1 // empty" "$CONFIG" 2>/dev/null)
  [ -z "$v" ] && v="$2"
  echo "$v"
}

# Подсистема должна быть включена (инфра-поле → $CONFIG)
BAK_ENABLED=$(get_config_field backups.enabled false)
if [ "$BAK_ENABLED" != "true" ]; then
    cat <<'EOF' >&2
В infra-config.json указано backups.enabled=false — бэкапы не настраиваются.

Если хочешь включить — запусти /sysadmin-init --reconfigure
и переключи backups.enabled на true. После этого скилл заработает.
EOF
    exit 0
fi

# Чтение значений из конфига
BACKUP_DESTINATION_FROM_CONFIG=$(get_config_field backups.destination)
RCLONE_REMOTE_FROM_CONFIG=$(get_config_field backups.rclone_remote)
# Приёмник «свой сервер по SFTP» (destination=sftp): адрес/алиас, путь репозитория, ключ.
SFTP_HOST_FROM_CONFIG=$(get_config_field backups.sftp.host)
SFTP_USER_FROM_CONFIG=$(get_config_field backups.sftp.user)
SFTP_PATH_FROM_CONFIG=$(get_config_field backups.sftp.path)
RETENTION_DAYS_FROM_CONFIG=$(get_config_field backups.retention.daily 7)
RETENTION_WEEKS_FROM_CONFIG=$(get_config_field backups.retention.weekly 4)
RETENTION_MONTHS_FROM_CONFIG=$(get_config_field backups.retention.monthly 6)

# Telegram — есть/нет
TG_ENABLED=$(get_config_field notifications.telegram.enabled false)
[ "$TG_ENABLED" = "true" ] && ALERT_CHANNEL_FROM_CONFIG="telegram" || ALERT_CHANNEL_FROM_CONFIG=""

# Менеджер паролей → конвенция индекса для restic-passphrase (агент-поле → мозг)
SECRETS_MANAGER=$(get_agent_field '.secrets.manager' keychain)
case "$SECRETS_MANAGER" in
    keychain)   BACKUP_PASS_REF_FROM_CONFIG="keychain://infra/restic-passphrase" ;;
    pass)       BACKUP_PASS_REF_FROM_CONFIG="pass:infra/restic-passphrase" ;;
    1password)  BACKUP_PASS_REF_FROM_CONFIG="op://infra/restic/passphrase" ;;
    bitwarden)  BACKUP_PASS_REF_FROM_CONFIG="bw://infra/restic-passphrase" ;;
    *) BACKUP_PASS_REF_FROM_CONFIG="" ;;
esac

# CLI-override > конфиг (для отладочных прогонов и edge cases)
BACKUP_DESTINATION="${BACKUP_DESTINATION:-$BACKUP_DESTINATION_FROM_CONFIG}"
RCLONE_REMOTE="${RCLONE_REMOTE:-$RCLONE_REMOTE_FROM_CONFIG}"
SFTP_HOST="${SFTP_HOST:-$SFTP_HOST_FROM_CONFIG}"
SFTP_USER="${SFTP_USER:-$SFTP_USER_FROM_CONFIG}"
SFTP_PATH="${SFTP_PATH:-$SFTP_PATH_FROM_CONFIG}"
RETENTION_DAYS="${RETENTION_DAYS:-$RETENTION_DAYS_FROM_CONFIG}"
RETENTION_WEEKS="${RETENTION_WEEKS:-$RETENTION_WEEKS_FROM_CONFIG}"
RETENTION_MONTHS="${RETENTION_MONTHS:-$RETENTION_MONTHS_FROM_CONFIG}"
ALERT_CHANNEL="${ALERT_CHANNEL:-$ALERT_CHANNEL_FROM_CONFIG}"
BACKUP_PASS_REF="${BACKUP_PASS_REF:-$BACKUP_PASS_REF_FROM_CONFIG}"
```

**Важно:** STOP-сообщение при `backups.enabled=false` дословно содержит `/sysadmin-init --reconfigure` — это единственный путь оператора к включению подсистемы. Без явного указания пути STOP превращается в тупик.

**Бэкап секретов всё равно из менеджера паролей.** TG-токен, S3-keys, restic passphrase — все живут в менеджере паролей оператора (определяется по `secrets.manager`), не в конфиге. Конфиг хранит только индекс/имя, по которому скилл найдёт значение в момент работы.

# Параметры

| Параметр | Default | Описание |
|----------|---------|----------|
| `BACKUP_DESTINATION` | (из `infra-config.json`: `backups.destination`) | `s3` / `b2` / `yandex-disk-webdav` / `nextcloud-webdav` / `owncloud-webdav` / `sftp` / `local` |
| `RCLONE_REMOTE` | (из `infra-config.json`: `backups.rclone_remote` — для webdav) | Имя rclone-remote из `~/.config/rclone/rclone.conf` |
| `BACKUP_USER` | (required для webdav) | WebDAV username (берётся из менеджера паролей при выполнении) |
| `SFTP_HOST` | (из `infra-config.json`: `backups.sftp.host` — required для sftp) | Как источник зовёт приёмник: ssh-алиас (предпочтительно) либо `host` |
| `SFTP_PATH` | (из `infra-config.json`: `backups.sftp.path` — required для sftp) | Путь репозитория на приёмнике. **При chroot — от корня chroot** |
| `SFTP_USER` | (из `infra-config.json`: `backups.sftp.user`, опционально) | Пользователь приёмника. Задаётся, ТОЛЬКО если не задан ssh-алиасом; уходит в адрес репозитория как `user@host`. Ключ, порт и прочее — исключительно в `~/.ssh/config` **того пользователя, от которого пойдёт задание** (обычно root): restic ssh-флаги не пробрасывает |
| `BACKUP_PASS_REF` | (из `agent-config.json`: `secrets.manager` + конвенция индекса) | Ссылка на passphrase в менеджере паролей |
| `S3_ACCESS_KEY` / `S3_SECRET_KEY` | (required для s3, из менеджера паролей) | S3 credentials |
| `DATABASES` | (autodetect) | Список БД-контейнеров через запятую |
| `BACKUP_PATHS` | (пусто) | Каталоги и файлы ХОСТА сверх дампов, через запятую: конфиги, код, данные приложений. Несуществующий путь — FAIL в логе, а не тихий пропуск |
| `SQLITE_DBS` | (пусто) | Базы-файлы через запятую (боты, панели). Снимок делается `sqlite3 .backup` — копировать живой файл нельзя, получишь битую базу; после снимка прогоняется `PRAGMA integrity_check` |
| `REMOTE_TARBALLS` | (пусто) | `имя=ssh-алиас` через запятую — забрать архив с сервера, у которого своего пути к хранилищу нет (другая страна, нет туннеля). Ключ на той стороне **обязан** быть заперт `command="..."` в `authorized_keys`, иначе ключ бэкапа = вход на чужой сервер. Пустой или битый архив считается отказом |
| `RETENTION_DAYS` | (из `infra-config.json`: `backups.retention.daily`) | Daily snapshots |
| `RETENTION_WEEKS` | (из `infra-config.json`: `backups.retention.weekly`) | Weekly snapshots |
| `RETENTION_MONTHS` | (из `infra-config.json`: `backups.retention.monthly`) | Monthly snapshots |
| `ALERT_CHANNEL` | (из `infra-config.json`: `notifications.telegram.enabled` → `telegram`) | `telegram` / `slack` / `email` — какой канал использовать |
| `ALERT_TOKEN` | (optional, из менеджера паролей) | Токен/webhook (Telegram bot token, Slack incoming webhook URL, SMTP credentials ref) |
| `ALERT_TARGET` | (optional) | Получатель (Telegram chat_id, Slack channel, email address) |
| `BACKUP_DIR` | `/opt/backups/dbs` | Локальная директория промежуточных дампов |
| `RESTIC_REPO_PATH` | `backups/infra` | Путь репозитория внутри хранилища |

# Процедура

## Шаг 1: Pre-check

Проверить инструменты и доступы перед началом:

```bash
# Инструменты. rclone нужен ТОЛЬКО webdav-приёмникам — для s3/b2/sftp его отсутствие не беда.
which restic jq || echo "Поставить недостающие"

# Доступ к хранилищу — проверяется по типу приёмника
case "$BACKUP_DESTINATION" in
  yandex-disk-webdav|nextcloud-webdav|owncloud-webdav)
    # Имя remote'а задаёт оператор при `rclone config` — например, `webdav-backup`.
    which rclone || echo "Поставить rclone"
    rclone lsd "$RCLONE_REMOTE": || echo "Сначала настроить rclone config"
    ;;
  sftp)
    which ssh sftp || echo "Поставить клиент openssh — им ходит restic"
    # Ходим ТЕМ ЖЕ путём и ОТ ТОГО ЖЕ пользователя, от которого потом пойдёт задание
    # (обычно root: у него свой ~/.ssh/config и свой known_hosts — алиас из домашки
    # оператора root'у не виден, и ночью задание упадёт при зелёной дневной проверке).
    # Учётка приёмника обычно заперта (ForceCommand internal-sftp) — обычный ssh
    # к ней НЕ откроет шелл, и это правильно. Проверяем именно sftp-канал.
    sudo -n sftp -b /dev/null "${SFTP_USER:+$SFTP_USER@}$SFTP_HOST" && echo "sftp-канал открыт" || \
      echo "Нет доступа к приёмнику от имени пользователя задания: проверь ~/.ssh/config и known_hosts этого пользователя, ключ на источнике и authorized_keys приёмника"
    ;;
esac

# Список БД-контейнеров (autodetect)
docker ps --format '{{.Names}}' | grep -E '(postgres|mysql|mariadb|redis)'

# Свободное место под локальные дампы (>= 2x размер крупнейшей БД)
df -h /opt
```

**Verify:** все инструменты в PATH, хранилище доступно, есть >=2x места.

## Шаг 2: Создание restic-репозитория

restic создаёт зашифрованный репозиторий один раз. Passphrase ОБЯЗАТЕЛЬНО хранить в менеджере
паролей — если потерять, бэкапы становятся бесполезными (ключ AES-256 без passphrase не
расшифровать).

```bash
# Прочитать passphrase из менеджера паролей
export RESTIC_PASSWORD="$(read_from_vault $BACKUP_PASS_REF)"

# Установить URL репозитория (под выбранное хранилище)
# ВАЖНО: значения слева — ровно те, что разрешает enum схемы (`backups.destination`).
# Ветка `webdav)` не совпадала ни с одним из них, и облачный приёмник падал с «неизвестен»
# при исправном конфиге (аудит 2026-09-24).
case "$BACKUP_DESTINATION" in
  s3) export RESTIC_REPOSITORY="s3:s3.amazonaws.com/$BACKUP_BUCKET/$RESTIC_REPO_PATH" ;;
  b2) export RESTIC_REPOSITORY="b2:$BACKUP_BUCKET:$RESTIC_REPO_PATH" ;;
  yandex-disk-webdav|nextcloud-webdav|owncloud-webdav)
      export RESTIC_REPOSITORY="rclone:$RCLONE_REMOTE:$RESTIC_REPO_PATH" ;;
  # Свой второй сервер. SFTP_PATH — путь НА ПРИЁМНИКЕ; при ChrootDirectory он считается
  # от корня chroot, а не от корня файловой системы (см. references/restic-quirks.md).
  # Пользователь берётся из ssh-алиаса; SFTP_USER задают, только когда алиаса нет.
  sftp)
      if [ -n "${SFTP_USER:-}" ]; then
          export RESTIC_REPOSITORY="sftp:$SFTP_USER@$SFTP_HOST:$SFTP_PATH"
      else
          export RESTIC_REPOSITORY="sftp:$SFTP_HOST:$SFTP_PATH"
      fi ;;
  *) echo "ERROR: BACKUP_DESTINATION не задан или неизвестен (s3/b2/*-webdav/sftp)" >&2; exit 2 ;;
esac

# Инициализация (только один раз!)
restic init
```

**Verify:** `restic snapshots` отвечает пустым списком без ошибки.

## Шаг 3: Установка скриптов дампа БД

Скопировать `scripts/backup-*.sh` в `/opt/infra/scripts/backup/`:

```bash
install -m 0755 scripts/backup-postgres.sh /opt/infra/scripts/backup/backup-postgres.sh
install -m 0755 scripts/backup-mysql.sh    /opt/infra/scripts/backup/backup-mysql.sh
install -m 0755 scripts/backup-redis.sh    /opt/infra/scripts/backup/backup-redis.sh
install -m 0755 scripts/backup-all.sh      /opt/infra/scripts/backup/backup-all.sh
install -m 0755 scripts/check-backup-age.sh /opt/infra/scripts/backup/check-backup-age.sh
```

Каждый скрипт принимает имя контейнера как аргумент, делает `docker exec` для дампа изнутри
контейнера (НЕ с хоста — иначе несовместимость версий клиента и сервера ломает дамп) и
складывает результат в `$BACKUP_DIR` с timestamp в имени.

## Шаг 4: Конфигурация оркестратора `backup-all.sh`

Оркестратор последовательно:
1. Запускает все БД-дампы по списку `$DATABASES`
2. Делает `restic backup` всей `$BACKUP_DIR`
3. Удаляет локальные файлы старше 1 дня (только локальные, offsite остаётся)
4. Запускает `restic forget --prune` с retention 7+4+6
5. Логирует всё в `/var/log/backup-cron.log`

`set -e` намеренно НЕ включён — если упала одна БД, остальные должны успеть забэкапиться.

## Шаг 5: Cron-расписание

Скопировать `templates/backup-cron-d` в `/etc/cron.d/backup`:

```cron
# Полный бэкап раз в сутки в 03:00 UTC (наименьшая нагрузка)
0 3 * * * root /opt/infra/scripts/backup/backup-all.sh >> /var/log/backup-cron.log 2>&1

# Проверка возраста раз в сутки в 09:00 UTC (после того как ночной бэкап точно завершился)
0 9 * * * root /opt/infra/scripts/backup/check-backup-age.sh >> /var/log/backup-cron.log 2>&1
```

**Verify:** `systemctl status cron` running, `cat /etc/cron.d/backup` показывает обе строки.

## Шаг 6: Алерт о возрасте бэкапа

`scripts/check-backup-age.sh`:
1. Читает `restic snapshots --latest 1 --json` → timestamp последнего snapshot
2. Если старше 36 часов И `ALERT_CHANNEL` настроен → отправляет алерт через
   соответствующий транспорт (Telegram bot API / Slack incoming webhook /
   `mail`-команда — выбирается case-блоком).
3. Без `ALERT_CHANNEL` — пишет WARNING в `/var/log/backup-cron.log`
   (не молчит, но и не падает).

Порог 36 часов (а не 24) — даёт 12-часовое окно на повторный прогон, если первая попытка
упала из-за временной недоступности хранилища.

## Шаг 7: Restore test (ОБЯЗАТЕЛЬНО)

Без этого шага скилл НЕ считается завершённым. Бэкап, который ни разу не восстанавливали, —
это надежда, а не бэкап.

**Ветка «БД на сервере ещё нет»** (свежий сервер: бэкапы настраиваются ДО переноса данных).
Конвейер всё равно проверяется целиком, на синтетике: тестовый контейнер с известным числом
строк → прогон **оркестратора `backup-all.sh`** (не отдельного дамп-скрипта!) → restore во
второй контейнер → сверка counts → уборка обоих контейнеров и тестового snapshot
(`restic forget --tag e2e-test --prune`). Полная процедура ветки и грабля ожидания
`pg_isready` — `references/pipeline-pitfalls.md`.

**Ветка «БД уже есть» — боевая сверка.** Порядок восстановления PostgreSQL канонический и
описан по шагам в `references/pg-restore-order.md` (образ контейнера → globals → `createdb`
→ `pg_restore` → сверка row counts); там же готовые команды, игнорируемые ошибки и
pgvector. Здесь не дублирую — открываю справочник и иду по нему. Для MySQL и Redis
пошагового справочника нет; что известно и чего не проверяли — `references/pipeline-pitfalls.md`.

Каркас прогона:

```bash
restic restore latest --target /tmp/restore-test     # 1. извлечь свежий snapshot
# 2-4. поднять временный контейнер тем же образом, что на проде,
#      восстановить globals → createdb → pg_restore   (см. pg-restore-order.md)
# 5. сверить row counts главной таблицы: прод против временного контейнера
docker rm -f pg-restore-test                          # 6. только после успешной сверки
```

**Verify:** row counts совпадают (допуск ±несколько записей от дневной активности между
дампом и сверкой); если расхождение значимое → блокер, скилл не закрывается, разбираться.

## Шаг 8: Документация в runbook

Скопировать `templates/backup-restore-runbook.md` → `runbooks/backup-restore.md` и заполнить
плейсхолдеры:

- `<CONTAINERS>` → конкретные имена контейнеров на этом сервере
- `<MAIN_DB>` → имя главной БД для restore-test
- `<DESTINATION>` → конкретное хранилище (s3 / b2 / webdav-через-Я.Диск или NextCloud + путь)
- `<LAST_VERIFIED>` → дата фактического прогона Шага 7

Финальная строка runbook: `Last verified: YYYY-MM-DD, by <agent>, on <production-host>`.

# Что помню до чтения справки

Три правила обязаны срабатывать сразу, иначе бэкап будет выглядеть настроенным и не быть им:

- **Бэкап без проверенного restore — не бэкап.** Шаг 7 не пропускается никогда, а прогон
  идёт **через сам `backup-all.sh`**: ручной вызов restic с руками экспортированными
  переменными маскирует главный класс багов (разбор — `references/pipeline-pitfalls.md`).
- **Потеря passphrase = потеря всех бэкапов навсегда.** AES-256 без ключа не расшифровать.
  Passphrase живёт в менеджере паролей оператора, а не в конфиге и не в git.
- **Managed-БД этот скилл не покрывает.** Увидел RDS / Managed Postgres / Supabase — говорю
  честно, что нужен другой подход, и не изображаю настройку.

# Bundled resources

| Файл | Что это и когда открывать |
|---|---|
| `references/pipeline-pitfalls.md` | **Обвязка ведёт себя не так, как обещано**: `source` без `set -a` (самая дорогая грабля, симптом «дампы SUCCESS, restic Fatal»), `pg_dump` с хоста, `set -e` в оркестраторе, Redis `SAVE` вместо `BGSAVE`, `curl` без таймаута, тарифицируемые multipart-огрызки, права на env-файл, граничные случаи (большие БД, managed, приватная сеть) |
| `references/restic-quirks.md` | **Сам restic и хранилища**: форма `RESTIC_REPOSITORY` по типам, WebDAV-тротлинг и `transfers = 1`, права bucket-полиси, `forget` без `--prune`, параметры backup, безопасность passphrase, производительность, таблица частых ошибок |
| `references/pg-restore-order.md` | **Порядок восстановления PostgreSQL**: globals → `createdb` → `pg_restore`, pgvector (нужен образ `pgvector/pgvector`, иначе `type "public.vector" does not exist`), игнорируемые ошибки, сверка row counts, большие БД и параллельный restore. Открывать на Шаге 7 |
| `scripts/backup-postgres.sh`, `backup-mysql.sh`, `backup-redis.sh` | дампы по типам БД (Шаг 3) |
| `scripts/backup-all.sh` | оркестратор: все дампы + `restic backup` + retention (Шаг 4) |
| `scripts/check-backup-age.sh` | алерт «бэкап старше 36 часов» в канал оператора (Шаг 6) |
| `templates/backup-cron-d` | шаблон `/etc/cron.d/backup` (Шаг 5) |
| `templates/backup-restore-runbook.md` | шаблон `runbooks/backup-restore.md` (Шаг 8) |
