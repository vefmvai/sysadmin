#!/usr/bin/env bash
# backup-mysql.sh — дамп одной MySQL/MariaDB БД через docker exec
#
# Использование:
#   ./backup-mysql.sh <container-name> <db-name> [output-dir]
#
# Принципы:
# - docker exec изнутри контейнера (версии mysqldump и сервера совпадают)
# - --single-transaction для InnoDB — консистентный дамп без блокировки
# - --routines --triggers — полный дамп со stored procedures и триггерами
# - Сжатие gzip на лету — экономит место и сетевой трафик при upload через restic
#
# Требования к контейнеру: переменная MYSQL_ROOT_PASSWORD внутри контейнера
# (или альтернативный root-пароль через MYSQL_PWD env при exec).

set -euo pipefail

CONTAINER="${1:?Usage: backup-mysql.sh <container> <db> [output-dir]}"
DB="${2:?Usage: backup-mysql.sh <container> <db> [output-dir]}"
OUTPUT_DIR="${3:-/opt/backups/dbs}"

DATE=$(date +%Y%m%d_%H%M%S)
DUMP_FILE="${OUTPUT_DIR}/${DB}_${DATE}.sql.gz"

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "ERROR: контейнер $CONTAINER не найден или не запущен" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

# Получаем пароль из env контейнера (MYSQL_ROOT_PASSWORD), без логирования значения
ROOT_PWD=$(docker exec "$CONTAINER" sh -c 'echo "$MYSQL_ROOT_PASSWORD"')
if [ -z "$ROOT_PWD" ]; then
    echo "ERROR: MYSQL_ROOT_PASSWORD не задан в контейнере $CONTAINER" >&2
    exit 1
fi

if docker exec -e MYSQL_PWD="$ROOT_PWD" "$CONTAINER" mysqldump \
    --user=root \
    --single-transaction \
    --routines \
    --triggers \
    --databases "$DB" \
    | gzip > "$DUMP_FILE"; then
    echo "OK: $DB → $DUMP_FILE ($(du -sh "$DUMP_FILE" | cut -f1))"
else
    echo "FAIL: $DB — mysqldump вернул ошибку" >&2
    rm -f "$DUMP_FILE"
    exit 2
fi

echo "$DUMP_FILE"