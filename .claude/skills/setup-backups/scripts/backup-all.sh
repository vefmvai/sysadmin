#!/usr/bin/env bash
# backup-all.sh — оркестратор: дампы всех БД + restic backup + retention
#
# Использование:
#   ./backup-all.sh
#
# Журнал скрипт ведёт САМ (/var/log/backup-cron.log). Штатную cron-строку
# (`>> /var/log/backup-cron.log 2>&1`) он распознаёт; при ручном запуске не направляй его
# вывод в тот же журнал через канал (`| tee -a …`) — это изнутри не видно, строки задвоятся.
#
# Конфигурация: читается из /root/.backup-env (chmod 600!), пример:
#   POSTGRES_CONTAINERS="postgres,<your-pg-container>"  # ПРИМЕР, не реальные данные
#   POSTGRES_DBS_postgres="db1,db2,db3"                 # ПРИМЕР
#   MYSQL_CONTAINERS=""
#   REDIS_CONTAINERS="<your-redis-container>"           # ПРИМЕР
#   RESTIC_REPOSITORY="s3:s3.amazonaws.com/<bucket>/backups/infra"  # ПРИМЕР, варианты:
#                  # s3:..., b2:<bucket>:..., rclone:<webdav-remote>:...,
#                  # sftp:<ssh-алиас>:<путь> — свой сервер; путь при chroot считается
#                  # от корня chroot (references/restic-quirks.md)
#   RESTIC_PASSWORD_FILE="/root/.restic-password"
#   BACKUP_DIR="/opt/backups/dbs"
#   BACKUP_PATHS="/opt/apps,/etc/nginx,/etc/letsencrypt"   # файлы хоста сверх дампов
#   SQLITE_DBS="/opt/apps/bot/bot.db,/etc/x-ui/x-ui.db"    # базы-файлы: снимок через .backup
#   RETENTION_DAYS=7
#   RETENTION_WEEKS=4
#   RETENTION_MONTHS=6
#   PRUNE_DAY="Sun"        # день недели для prune (см. Failed Attempts в SKILL.md)
#   ALERT_CHANNEL="..."    # telegram | slack | email | (пусто = только лог)
#   ALERT_TOKEN="..."      # bot token / webhook URL / SMTP creds-ref
#   ALERT_TARGET="..."     # chat_id / channel / email-адрес
#
# Принципы:
# - НЕ set -e — упавшая БД не должна останавливать остальные
# - set -u включён — необъявленные переменные ловятся как ошибка конфигурации
# - Каждый шаг логируется в /var/log/backup-cron.log

set -uo pipefail

CONFIG="${BACKUP_CONFIG:-/root/.backup-env}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${BACKUP_LOG:-/var/log/backup-cron.log}"

# Каждая строка попадает в журнал ровно ОДИН раз. Cron-строка этого скилла сама направляет
# вывод скрипта в тот же файл (`>> /var/log/backup-cron.log 2>&1`, templates/backup-cron-d),
# и `tee -a` писал всё дважды (боевой журнал, разбор 25.09.2026). Вывод уже идёт в журнал —
# только печатаем; иначе (ручной запуск, ssh, systemd) — печатаем и дописываем в журнал.
if [ /dev/stdout -ef "$LOG_FILE" ]; then
    # В журнал — ПО ИМЕНИ и на дозапись, а не в stdout: stdout может быть открыт без дозаписи
    # (systemd StandardOutput=file:, `>` вместо `>>` в cron), и тогда метки затирают вывод
    # restic, который пишет в журнал по имени (проверка 25.09.2026, Linux и Git Bash).
    log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }
else
    log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
fi

if [ ! -r "$CONFIG" ]; then
    log "FATAL: $CONFIG не читается"
    exit 1
fi

# shellcheck disable=SC1090
# set -a: экспортируем переменные конфига в окружение. restic/rclone — дочерние
# процессы, и без экспорта они не видят RESTIC_REPOSITORY / AWS_ACCESS_KEY_ID /
# AWS_SECRET_ACCESS_KEY и падают «Fatal: Please specify repository location».
# (боевая находка Bronto 2026-07-09: дампы БД проходили, а restic backup молча
#  фейлил — конфиг читался в шелл, но не экспортировался в restic.)
set -a
source "$CONFIG"
set +a

: "${BACKUP_DIR:=/opt/backups/dbs}"
: "${RETENTION_DAYS:=7}"
: "${RETENTION_WEEKS:=4}"
: "${RETENTION_MONTHS:=6}"
: "${PRUNE_DAY:=Sun}"

mkdir -p "$BACKUP_DIR"

log "=== BACKUP START ==="

SUCCESS=0
FAIL=0

# --- PostgreSQL ---
if [ -n "${POSTGRES_CONTAINERS:-}" ]; then
    IFS=',' read -ra PG_CONTAINERS <<< "$POSTGRES_CONTAINERS"
    for PG in "${PG_CONTAINERS[@]}"; do
        DBS_VAR="POSTGRES_DBS_${PG//-/_}"
        DBS="${!DBS_VAR:-}"
        if [ -z "$DBS" ]; then
            log "WARN: для $PG не задан $DBS_VAR — пропускаю"
            continue
        fi
        IFS=',' read -ra DB_LIST <<< "$DBS"
        for DB in "${DB_LIST[@]}"; do
            log "INFO: pg dump $PG → $DB"
            if "$SCRIPT_DIR/backup-postgres.sh" "$PG" "$DB" "$BACKUP_DIR" >> "$LOG_FILE" 2>&1; then
                SUCCESS=$((SUCCESS + 1))
            else
                FAIL=$((FAIL + 1))
                log "FAIL: pg $PG/$DB"
            fi
        done
    done
fi

# --- MySQL/MariaDB ---
if [ -n "${MYSQL_CONTAINERS:-}" ]; then
    IFS=',' read -ra MY_CONTAINERS <<< "$MYSQL_CONTAINERS"
    for MY in "${MY_CONTAINERS[@]}"; do
        DBS_VAR="MYSQL_DBS_${MY//-/_}"
        DBS="${!DBS_VAR:-}"
        if [ -z "$DBS" ]; then continue; fi
        IFS=',' read -ra DB_LIST <<< "$DBS"
        for DB in "${DB_LIST[@]}"; do
            log "INFO: mysql dump $MY → $DB"
            if "$SCRIPT_DIR/backup-mysql.sh" "$MY" "$DB" "$BACKUP_DIR" >> "$LOG_FILE" 2>&1; then
                SUCCESS=$((SUCCESS + 1))
            else
                FAIL=$((FAIL + 1))
                log "FAIL: mysql $MY/$DB"
            fi
        done
    done
fi

# --- Redis ---
if [ -n "${REDIS_CONTAINERS:-}" ]; then
    IFS=',' read -ra REDIS_LIST <<< "$REDIS_CONTAINERS"
    for R in "${REDIS_LIST[@]}"; do
        log "INFO: redis dump $R"
        if "$SCRIPT_DIR/backup-redis.sh" "$R" "$BACKUP_DIR" >> "$LOG_FILE" 2>&1; then
            SUCCESS=$((SUCCESS + 1))
        else
            FAIL=$((FAIL + 1))
            log "FAIL: redis $R"
        fi
    done
fi

# --- Забор с другого сервера, у которого нет своего пути к хранилищу ---
# Случай: второй VPS стоит в другой стране, до приёмника бэкапов достучаться не может, а
# этот сервер может. Тогда забирает ЭТОТ: подключается к тому и получает готовый архив на
# stdout. Ключ на стороне источника обязан быть заперт forced command в authorized_keys —
# иначе ключ для бэкапа превращается в полноценный вход на чужой сервер.
# Формат: REMOTE_TARBALLS="имя=ssh-алиас,имя2=алиас2" (алиас — из ~/.ssh/config ПОЛЬЗОВАТЕЛЯ
# задания, обычно root).
if [ -n "${REMOTE_TARBALLS:-}" ]; then
    IFS=',' read -ra REMOTE_LIST <<< "$REMOTE_TARBALLS"
    for ENTRY in "${REMOTE_LIST[@]}"; do
        [ -n "$ENTRY" ] || continue
        R_NAME="${ENTRY%%=*}"
        R_TARGET="${ENTRY#*=}"
        R_OUT="$BACKUP_DIR/${R_NAME}-$(date +%Y%m%d-%H%M%S).tar.gz"
        # Пустой файл и битый архив — это НЕ успех: «забрали» и «забрали годное» разные вещи.
        # -T: команду подставляет forced command, терминал не нужен. Без флага ssh, не
        # получив команды, просит терминал и на каждом прогоне пишет в журнал «Pseudo-terminal
        # will not be allocated because stdin is not a terminal» — шум, в котором теряются
        # настоящие строки (замечено в бою 2026-09-26).
        if ssh -T -o BatchMode=yes -o ConnectTimeout=20 "$R_TARGET" > "$R_OUT" 2>> "$LOG_FILE" \
           && [ -s "$R_OUT" ] \
           && gzip -t "$R_OUT" 2>> "$LOG_FILE"; then
            log "OK: удалённый архив $R_NAME ← $R_TARGET ($(du -h "$R_OUT" | cut -f1))"
            SUCCESS=$((SUCCESS + 1))
        else
            log "FAIL: удалённый архив $R_NAME ← $R_TARGET (нет связи, пусто или битый gzip)"
            rm -f "$R_OUT"
            FAIL=$((FAIL + 1))
        fi
    done
fi

# --- SQLite на хосте (боты, панели: файл базы, а не контейнер СУБД) ---
# Копировать живой .db файлом НЕЛЬЗЯ: запись в момент копирования даёт битую базу, и
# узнаёшь об этом при восстановлении. Штатный способ — `.backup` средствами самой sqlite3:
# он берёт согласованный снимок под блокировкой.
if [ -n "${SQLITE_DBS:-}" ]; then
    if ! command -v sqlite3 >/dev/null 2>&1; then
        log "FAIL: заданы SQLITE_DBS, но sqlite3 не установлен — базы НЕ сохранены"
        FAIL=$((FAIL + 1))
    else
        IFS=',' read -ra SQLITE_LIST <<< "$SQLITE_DBS"
        for DB_FILE in "${SQLITE_LIST[@]}"; do
            [ -n "$DB_FILE" ] || continue
            if [ ! -f "$DB_FILE" ]; then
                log "FAIL: sqlite $DB_FILE — файла нет"
                FAIL=$((FAIL + 1))
                continue
            fi
            OUT="$BACKUP_DIR/$(basename "$DB_FILE" | tr -c 'A-Za-z0-9._-' '_')-$(date +%Y%m%d-%H%M%S).sqlite"
            if sqlite3 "$DB_FILE" ".backup '$OUT'" >> "$LOG_FILE" 2>&1 \
               && [ -s "$OUT" ] \
               && [ "$(sqlite3 "$OUT" 'PRAGMA integrity_check;' 2>/dev/null)" = "ok" ]; then
                log "OK: sqlite $DB_FILE → $(basename "$OUT")"
                SUCCESS=$((SUCCESS + 1))
            else
                # Пустой файл или проваленная integrity_check — это НЕ успех: снимок
                # «сделан», а восстанавливать из него нечего.
                log "FAIL: sqlite $DB_FILE — снимок пуст или не прошёл integrity_check"
                FAIL=$((FAIL + 1))
            fi
        done
    fi
fi

log "DUMPS DONE: SUCCESS=$SUCCESS, FAIL=$FAIL"

# --- restic backup ---
# BACKUP_PATHS — каталоги и файлы хоста сверх дампов (конфиги, код, данные приложений).
# Разделитель — запятая, как у остальных списков этого скрипта; пути с пробелами при этом
# не разрываются (в отличие от разбора по пробелам).
RESTIC_TARGETS=("$BACKUP_DIR")
if [ -n "${BACKUP_PATHS:-}" ]; then
    IFS=',' read -ra EXTRA_PATHS <<< "$BACKUP_PATHS"
    for P in "${EXTRA_PATHS[@]}"; do
        [ -n "$P" ] || continue
        if [ -e "$P" ]; then
            RESTIC_TARGETS+=("$P")
        else
            # Молча пропустить — значит однажды восстанавливать пустоту.
            log "FAIL: путь из BACKUP_PATHS не существует: $P"
            FAIL=$((FAIL + 1))
        fi
    done
fi

log "INFO: restic backup → $RESTIC_REPOSITORY (целей: ${#RESTIC_TARGETS[@]})"
if restic --password-file "$RESTIC_PASSWORD_FILE" backup "${RESTIC_TARGETS[@]}" >> "$LOG_FILE" 2>&1; then
    log "OK: restic backup"
else
    log "FAIL: restic backup — алерт обязателен"
    FAIL=$((FAIL + 1))
fi

# --- retention: forget ежедневно, prune по воскресеньям ---
log "INFO: restic forget"
restic --password-file "$RESTIC_PASSWORD_FILE" forget \
    --keep-daily   "$RETENTION_DAYS" \
    --keep-weekly  "$RETENTION_WEEKS" \
    --keep-monthly "$RETENTION_MONTHS" \
    >> "$LOG_FILE" 2>&1 || log "WARN: forget вернул ошибку"

if [ "$(date +%a)" = "$PRUNE_DAY" ]; then
    log "INFO: restic prune (воскресенье)"
    restic --password-file "$RESTIC_PASSWORD_FILE" prune >> "$LOG_FILE" 2>&1 || log "WARN: prune вернул ошибку"
fi

# --- очистка локальных дампов старше 1 дня (offsite остаётся в restic) ---
find "$BACKUP_DIR" -type f -mtime +1 -delete

log "=== BACKUP DONE: SUCCESS=$SUCCESS, FAIL=$FAIL ==="

# Алерт при ошибках
if [ "$FAIL" -gt 0 ] && [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    curl -s -m 20 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=BACKUP $(hostname): SUCCESS=$SUCCESS FAIL=$FAIL — проверь $LOG_FILE" \
        > /dev/null
fi

[ "$FAIL" -eq 0 ]