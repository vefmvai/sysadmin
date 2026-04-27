#!/usr/bin/env bash
# check-backup-age.sh — алерт «бэкап старше N часов»
#
# Использование:
#   ./check-backup-age.sh
#
# Конфигурация: читается из /root/.backup-env (тот же файл, что у backup-all.sh).
# Дополнительные переменные:
#   BACKUP_AGE_THRESHOLD_HOURS=36  # порог алерта в часах (default 36)
#
# Принципы:
# - Читает timestamp последнего snapshot через `restic snapshots --latest 1 --json`
# - Если ALERT_CHANNEL задан — алерт в выбранный канал (Telegram / Slack / email)
# - Без ALERT_CHANNEL — WARNING в /var/log/backup-cron.log
# - Не падает (exit 0) если бэкап свежий — иначе cron спамит уведомлениями

set -uo pipefail

CONFIG="${BACKUP_CONFIG:-/root/.backup-env}"
LOG_FILE="${BACKUP_LOG:-/var/log/backup-cron.log}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] check-backup-age: $*" | tee -a "$LOG_FILE"; }

if [ ! -r "$CONFIG" ]; then
    log "FATAL: $CONFIG не читается"
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG"

: "${BACKUP_AGE_THRESHOLD_HOURS:=36}"
: "${ALERT_CHANNEL:=}"  # telegram | slack | email | (пусто = только лог)

# Универсальный отправщик алерта по выбранному каналу.
# Telegram-вариант — наиболее частый кейс для соло-операторов; Slack/email
# поддерживаются как альтернативы. Канал берётся из inventory/access.md.
send_alert() {
    local msg="$1"
    case "$ALERT_CHANNEL" in
        telegram)
            # ALERT_TOKEN = bot token, ALERT_TARGET = chat_id
            curl -s -X POST "https://api.telegram.org/bot${ALERT_TOKEN}/sendMessage" \
                -d "chat_id=${ALERT_TARGET}" \
                -d "text=$(hostname): $msg" > /dev/null
            ;;
        slack)
            # ALERT_TOKEN = incoming webhook URL, ALERT_TARGET (опционально) = override channel
            curl -s -X POST -H 'Content-Type: application/json' \
                --data "{\"text\":\"$(hostname): $msg\"}" \
                "$ALERT_TOKEN" > /dev/null
            ;;
        email)
            # ALERT_TARGET = email address; mail должен быть настроен на хосте
            echo "$msg" | mail -s "$(hostname): backup alert" "$ALERT_TARGET"
            ;;
        *)
            # без ALERT_CHANNEL — алерт остаётся только в лог-файле (см. log выше)
            ;;
    esac
}

# Получаем timestamp последнего snapshot
LATEST_JSON=$(restic --password-file "$RESTIC_PASSWORD_FILE" snapshots --latest 1 --json 2>/dev/null || echo "[]")

if [ "$LATEST_JSON" = "[]" ] || [ -z "$LATEST_JSON" ]; then
    MSG="ALERT: в restic-репозитории нет snapshot'ов (или ошибка доступа)"
    log "$MSG"
    send_alert "$MSG"
    exit 2
fi

LATEST_TIME=$(echo "$LATEST_JSON" | jq -r '.[0].time')
if [ -z "$LATEST_TIME" ] || [ "$LATEST_TIME" = "null" ]; then
    log "FAIL: не удалось распарсить timestamp из restic"
    exit 3
fi

# Конвертируем в epoch (без учёта микросекунд)
LATEST_EPOCH=$(date -d "${LATEST_TIME%.*}" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "${LATEST_TIME%.*}" +%s 2>/dev/null)
NOW_EPOCH=$(date +%s)
AGE_HOURS=$(( (NOW_EPOCH - LATEST_EPOCH) / 3600 ))

log "INFO: latest snapshot $LATEST_TIME, age=${AGE_HOURS}h, threshold=${BACKUP_AGE_THRESHOLD_HOURS}h"

if [ "$AGE_HOURS" -gt "$BACKUP_AGE_THRESHOLD_HOURS" ]; then
    MSG="ALERT: последний бэкап ${AGE_HOURS}ч назад (порог ${BACKUP_AGE_THRESHOLD_HOURS}ч)"
    log "$MSG"
    send_alert "$MSG"
    exit 4
fi

exit 0