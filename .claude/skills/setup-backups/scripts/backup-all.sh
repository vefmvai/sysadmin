#!/usr/bin/env bash
# backup-all.sh — оркестратор: дампы всех БД + restic backup + retention
#
# Использование:
#   ./backup-all.sh
#
# Конфигурация: читается из /root/.backup-env (chmod 600!), пример:
#   POSTGRES_CONTAINERS="postgres,<your-pg-container>"  # ПРИМЕР, не реальные данные
#   POSTGRES_DBS_postgres="db1,db2,db3"                 # ПРИМЕР
#   MYSQL_CONTAINERS=""
#   REDIS_CONTAINERS="<your-redis-container>"           # ПРИМЕР
#   RESTIC_REPOSITORY="s3:s3.amazonaws.com/<bucket>/backups/infra"  # ПРИМЕР, варианты:
#                  # s3:..., b2:<bucket>:..., rclone:<webdav-remote>:...
#   RESTIC_PASSWORD_FILE="/root/.restic-password"
#   BACKUP_DIR="/opt/backups/dbs"
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

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

if [ ! -r "$CONFIG" ]; then
    log "FATAL: $CONFIG не читается"
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG"

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

log "DUMPS DONE: SUCCESS=$SUCCESS, FAIL=$FAIL"

# --- restic backup ---
log "INFO: restic backup → $RESTIC_REPOSITORY"
if restic --password-file "$RESTIC_PASSWORD_FILE" backup "$BACKUP_DIR" >> "$LOG_FILE" 2>&1; then
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
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=BACKUP $(hostname): SUCCESS=$SUCCESS FAIL=$FAIL — проверь $LOG_FILE" \
        > /dev/null
fi

[ "$FAIL" -eq 0 ]