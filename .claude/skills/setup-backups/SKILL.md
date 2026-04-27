---
name: setup-backups
description: |
  Настройка бэкапов сервера с нуля: restic для encrypted snapshots, offsite-хранилище
  (S3-совместимое / Backblaze B2 / WebDAV — Яндекс.Диск, NextCloud, ownCloud — параметром),
  retention 7+4+6 (daily+weekly+monthly), алерт «бэкап старше 36 часов» в канал
  оператора (Telegram / Slack / email — берётся из inventory/access.md), фактический
  прогон restore на временный контейнер. Покрывает БД (PostgreSQL, MySQL, Redis dump).
  Используй когда оператор говорит "нужны бэкапы", "настрой backup",
  "restic с retention", "offsite на S3 / WebDAV / Backblaze",
  "без бэкапов нельзя ничего менять".
when_to_use: |
  Перед любыми деструктивными изменениями на сервере. Покрывает только БД (uploads —
  отдельный шаблон, не входит в скилл). Требует уже настроенного хранилища (S3 bucket /
  B2 bucket / WebDAV-endpoint — например, Яндекс.Диск, NextCloud) с известными
  credentials и настроенного канала алертов (Telegram-бот / Slack webhook / email —
  опционально, но рекомендуется для алертов о возрасте бэкапа).
disable-model-invocation: false
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

Скилл — STRICT-режим: без `sysadmin-config.json` он не запускается. Конфиг определяет, куда складываются бэкапы (S3 / B2 / WebDAV), какая retention, нужны ли Telegram-алерты и в каком менеджере паролей искать `restic`-passphrase. Без этих решений скилл угадывал бы намерения — это запрещено правилами агента.

```bash
CONFIG="${INFRA_DIR:-$(pwd)}/sysadmin-config.json"

# 1) Конфиг обязан быть
if [ ! -f "$CONFIG" ]; then
    cat <<'EOF' >&2
sysadmin-config.json не найден.

Без него я не знаю, куда заливать бэкапы и в каком менеджере паролей лежит passphrase.
Запусти /sysadmin-init для первичной настройки агента — это 3-5 минут вопросов,
после которых этот скилл заработает.
EOF
    exit 1
fi

# 2) Подсистема должна быть включена
BAK_ENABLED=$(jq -r '.backups.enabled' "$CONFIG")
if [ "$BAK_ENABLED" != "true" ]; then
    cat <<'EOF' >&2
В sysadmin-config.json указано backups.enabled=false — бэкапы не настраиваются.

Если хочешь включить — запусти /sysadmin-init --reconfigure
и переключи backups.enabled на true. После этого скилл заработает.
EOF
    exit 0
fi

# 3) Чтение значений из конфига (CLI-параметры остаются как override ниже)
BACKUP_DESTINATION_FROM_CONFIG=$(jq -r '.backups.destination' "$CONFIG")
RCLONE_REMOTE_FROM_CONFIG=$(jq -r '.backups.rclone_remote // empty' "$CONFIG")
RETENTION_DAYS_FROM_CONFIG=$(jq -r '.backups.retention.daily' "$CONFIG")
RETENTION_WEEKS_FROM_CONFIG=$(jq -r '.backups.retention.weekly' "$CONFIG")
RETENTION_MONTHS_FROM_CONFIG=$(jq -r '.backups.retention.monthly' "$CONFIG")

# Telegram — есть/нет
TG_ENABLED=$(jq -r '.notifications.telegram.enabled // false' "$CONFIG")
if [ "$TG_ENABLED" = "true" ]; then
    ALERT_CHANNEL_FROM_CONFIG="telegram"
else
    ALERT_CHANNEL_FROM_CONFIG=""
fi

# Менеджер паролей → конвенция индекса для restic-passphrase
SECRETS_MANAGER=$(jq -r '.secrets.manager' "$CONFIG")
case "$SECRETS_MANAGER" in
    keychain)   BACKUP_PASS_REF_FROM_CONFIG="keychain://infra/restic-passphrase" ;;
    pass)       BACKUP_PASS_REF_FROM_CONFIG="pass:infra/restic-passphrase" ;;
    1password)  BACKUP_PASS_REF_FROM_CONFIG="op://infra/restic/passphrase" ;;
    bitwarden)  BACKUP_PASS_REF_FROM_CONFIG="bw://infra/restic-passphrase" ;;
    *) BACKUP_PASS_REF_FROM_CONFIG="" ;;
esac

# 4) CLI-override > конфиг (для отладочных прогонов и edge cases)
BACKUP_DESTINATION="${BACKUP_DESTINATION:-$BACKUP_DESTINATION_FROM_CONFIG}"
RCLONE_REMOTE="${RCLONE_REMOTE:-$RCLONE_REMOTE_FROM_CONFIG}"
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
| `BACKUP_DESTINATION` | (из `sysadmin-config.json`: `backups.destination`) | `s3` / `b2` / `yandex-disk-webdav` / `nextcloud-webdav` / `owncloud-webdav` / `local` |
| `RCLONE_REMOTE` | (из `sysadmin-config.json`: `backups.rclone_remote` — для webdav) | Имя rclone-remote из `~/.config/rclone/rclone.conf` |
| `BACKUP_USER` | (required для webdav) | WebDAV username (берётся из менеджера паролей при выполнении) |
| `BACKUP_PASS_REF` | (из `sysadmin-config.json`: `secrets.manager` + конвенция индекса) | Ссылка на passphrase в менеджере паролей |
| `S3_ACCESS_KEY` / `S3_SECRET_KEY` | (required для s3, из менеджера паролей) | S3 credentials |
| `DATABASES` | (autodetect) | Список БД-контейнеров через запятую |
| `RETENTION_DAYS` | (из `sysadmin-config.json`: `backups.retention.daily`) | Daily snapshots |
| `RETENTION_WEEKS` | (из `sysadmin-config.json`: `backups.retention.weekly`) | Weekly snapshots |
| `RETENTION_MONTHS` | (из `sysadmin-config.json`: `backups.retention.monthly`) | Monthly snapshots |
| `ALERT_CHANNEL` | (из `sysadmin-config.json`: `notifications.telegram.enabled` → `telegram`) | `telegram` / `slack` / `email` — какой канал использовать |
| `ALERT_TOKEN` | (optional, из менеджера паролей) | Токен/webhook (Telegram bot token, Slack incoming webhook URL, SMTP credentials ref) |
| `ALERT_TARGET` | (optional) | Получатель (Telegram chat_id, Slack channel, email address) |
| `BACKUP_DIR` | `/opt/backups/dbs` | Локальная директория промежуточных дампов |
| `RESTIC_REPO_PATH` | `backups/infra` | Путь репозитория внутри хранилища |

# Процедура

## Шаг 1: Pre-check

Проверить инструменты и доступы перед началом:

```bash
# Инструменты
which rclone restic jq || echo "Поставить недостающие"

# Доступ к хранилищу (для WebDAV-варианта типа Яндекс.Диск, NextCloud)
# Имя remote'а в rclone задаётся оператором при `rclone config` — например, `webdav-backup`.
rclone lsd "$RCLONE_REMOTE": || echo "Сначала настроить rclone config"

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
case "$BACKUP_DESTINATION" in
  s3)     export RESTIC_REPOSITORY="s3:s3.amazonaws.com/$BACKUP_BUCKET/$RESTIC_REPO_PATH" ;;
  b2)     export RESTIC_REPOSITORY="b2:$BACKUP_BUCKET:$RESTIC_REPO_PATH" ;;
  webdav) export RESTIC_REPOSITORY="rclone:$RCLONE_REMOTE:$RESTIC_REPO_PATH" ;;  # Яндекс.Диск / NextCloud / ownCloud
  *) echo "ERROR: BACKUP_DESTINATION не задан или неизвестен (s3/b2/webdav)" >&2; exit 2 ;;
esac

# Инициализация (только один раз!)
restic init
```

**Verify:** `restic snapshots` отвечает пустым списком без ошибки.

## Шаг 3: Установка скриптов дампа БД

Скопировать `scripts/backup-*.sh` в `/opt/backup/`:

```bash
install -m 0755 scripts/backup-postgres.sh /opt/backup/backup-postgres.sh
install -m 0755 scripts/backup-mysql.sh    /opt/backup/backup-mysql.sh
install -m 0755 scripts/backup-redis.sh    /opt/backup/backup-redis.sh
install -m 0755 scripts/backup-all.sh      /opt/backup/backup-all.sh
install -m 0755 scripts/check-backup-age.sh /opt/backup/check-backup-age.sh
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
0 3 * * * root /opt/backup/backup-all.sh >> /var/log/backup-cron.log 2>&1

# Проверка возраста раз в сутки в 09:00 UTC (после того как ночной бэкап точно завершился)
0 9 * * * root /opt/backup/check-backup-age.sh >> /var/log/backup-cron.log 2>&1
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

Процедура (для PostgreSQL — для MySQL/Redis см. `references/restic-quirks.md`):

```bash
# 1. Извлечь свежий snapshot во временную папку
restic restore latest --target /tmp/restore-test

# 2. Поднять временный контейнер (важно: образ совпадает с продом!)
# Для БД с pgvector — обязательно pgvector/pgvector:pg16, не чистый postgres:16!
docker run -d --name pg-restore-test \
  -e POSTGRES_PASSWORD=testpassword \
  -p 5433:5432 \
  pgvector/pgvector:pg16

until docker exec pg-restore-test pg_isready -U postgres; do sleep 1; done

# 3. Восстановить globals (роли) → создать БД → залить dump
docker exec -i pg-restore-test psql -U postgres < /tmp/restore-test/opt/backups/dbs/globals_*.sql
docker exec pg-restore-test createdb -U postgres <main-db>
docker exec -i pg-restore-test pg_restore -U postgres -d <main-db> --no-owner --no-privileges \
  < /tmp/restore-test/opt/backups/dbs/<main-db>_*.dump

# 4. Сверить row counts с продом
PROD_COUNT=$(docker exec <prod-pg-container> psql -U postgres -d <main-db> -tAc \
  "SELECT count(*) FROM <main-table>")
TEST_COUNT=$(docker exec pg-restore-test psql -U postgres -d <main-db> -tAc \
  "SELECT count(*) FROM <main-table>")

echo "PROD=$PROD_COUNT TEST=$TEST_COUNT"
[ "$PROD_COUNT" = "$TEST_COUNT" ] && echo "OK" || echo "MISMATCH — БЛОКЕР"

# 5. Удалить временный контейнер только после успешной сверки
docker rm -f pg-restore-test
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

# Параметризация по типу хранилища

| Хранилище | RESTIC_REPOSITORY | Дополнительно |
|-----------|-------------------|---------------|
| AWS S3 | `s3:s3.amazonaws.com/<bucket>/backups/infra` | `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` в env |
| Backblaze B2 | `b2:<bucket>:backups/infra` | `B2_ACCOUNT_ID` + `B2_ACCOUNT_KEY` в env |
| WebDAV (Я.Диск / NextCloud / ownCloud) | `rclone:<remote>:backups/infra` | `rclone config` создать remote (тип webdav, endpoint провайдера — например, `https://webdav.yandex.ru` для Я.Диска) |
| S3-совместимое (MinIO / Wasabi / Yandex Object Storage) | `s3:<endpoint>/<bucket>/backups/infra` | `AWS_*` env с подменённым endpoint |

# Failed Attempts (граблекейс)

- **«Запуск без `sysadmin-config.json`»** — раньше скилл требовал кучу CLI-параметров,
  оператор вспоминал какие обязательные. Урок: скилл не угадывает намерения. Нет конфига —
  `exit 1` с указанием на `/sysadmin-init`. `backups.enabled=false` — `exit 0` с
  указанием на `/sysadmin-init --reconfigure`. Никаких defaults «как у меня».
- **«pg_dump с хоста»** — несовместимость версий клиента (хост) и сервера (контейнер) ломает
  дамп. ВСЕГДА `docker exec <container> pg_dumpall` — внутри контейнера версии гарантированно
  совпадают.
- **«restic forget без --prune»** — `forget` помечает snapshot'ы удалёнными в индексе, но не
  освобождает место в хранилище. Всегда `forget --prune` (или отдельный `prune` в воскресенье).
- **«rclone WebDAV без --transfers 1»** — некоторые WebDAV-провайдеры (в частности
  Яндекс.Диск) тротлят при параллельных upload'ах. В `/root/.config/rclone/rclone.conf`
  для соответствующего remote указать `transfers = 1`.
- **«backup-all c set -e»** — одна упавшая БД останавливает весь прогон, остальные не
  бэкапятся. set -e ОТКЛЮЧИТЬ для оркестратора (`set -uo pipefail` достаточно).
- **«ежедневный prune»** — `restic prune` через WebDAV-хранилища занимает 30+ минут
  на крупных репозиториях. Запускать только по воскресеньям, daily — только `forget`
  без `--prune`.
- **«passphrase в env-файле без chmod 600»** — любой пользователь с доступом на чтение
  получает ключ к расшифровке всех бэкапов. `chmod 600 /root/.backup-env` обязательно.

# Граничные случаи

- **pgvector** — для restore-test нужен образ `pgvector/pgvector:pg16`, не чистый
  `postgres:16`. Тип `public.vector` не существует в чистом postgres → pg_restore падает с
  `ERROR: type "public.vector" does not exist`. См. `references/pg-restore-order.md`.
- **Порядок restore PostgreSQL**: globals (`pg_dumpall --globals-only`) → `createdb` →
  `pg_restore`. Нарушение даёт ошибки `role does not exist` или `owner not found`.
- **Redis dump** — `redis-cli BGSAVE`, потом скопировать `dump.rdb`. НЕ `redis-cli SAVE` —
  блокирует БД на больших датасетах (минутами).
- **Большие БД (>5 ГБ)** — добавить `--ignore-inode` в `restic backup`; pg_dump может
  занимать >1 часа. Окно cron возможно перенести на 02:00 / 01:00.
- **БД на отдельной машине / managed (AWS RDS, Yandex Managed Postgres, Google Cloud SQL,
  Supabase и т.п.)** — этот скилл не покрывает. Нужен другой подход: либо managed snapshots
  провайдера, либо отдельный backup-узел с доступом к БД через приватную сеть.
- **Хранилище без публичного IP** — для S3-API через приватный VPC: добавить
  `--insecure-no-password` или endpoint override. См. `references/restic-quirks.md`.

# Связанные ресурсы

- `scripts/backup-postgres.sh` — дамп одной PostgreSQL БД
- `scripts/backup-mysql.sh` — дамп одной MySQL/MariaDB БД
- `scripts/backup-redis.sh` — дамп Redis (BGSAVE + копия dump.rdb)
- `scripts/backup-all.sh` — оркестратор всех дампов + restic backup + retention
- `scripts/check-backup-age.sh` — алерт «бэкап старше 36 часов» в канал оператора
  (Telegram / Slack / email — выбирается параметром `ALERT_CHANNEL`)
- `templates/backup-cron-d` — `/etc/cron.d/backup` шаблон
- `templates/backup-restore-runbook.md` — шаблон для генерации `runbooks/backup-restore.md`
- `references/restic-quirks.md` — известные грабли restic + WebDAV / S3 / B2
- `references/pg-restore-order.md` — порядок globals → createdb → pg_restore + pgvector edge case