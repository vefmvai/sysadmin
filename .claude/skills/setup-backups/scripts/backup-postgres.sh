#!/usr/bin/env bash
# backup-postgres.sh — дамп одной PostgreSQL БД через docker exec
#
# Использование:
#   ./backup-postgres.sh <container-name> <db-name> [output-dir]
#
# Принципы:
# - docker exec изнутри контейнера — версии клиента и сервера гарантированно совпадают
# - --format=custom для совместимости с pg_restore (двоичный, сжатый)
# - --no-owner --no-privileges — упрощает восстановление в чужой кластер
# - Идемпотентен: повторный запуск с тем же timestamp перезаписывает файл (timestamp по умолчанию уникален)
# - При ошибке возвращает ненулевой exit код — оркестратор распознаёт и идёт дальше

set -euo pipefail

CONTAINER="${1:?Usage: backup-postgres.sh <container> <db> [output-dir]}"
DB="${2:?Usage: backup-postgres.sh <container> <db> [output-dir]}"
OUTPUT_DIR="${3:-/opt/backups/dbs}"

DATE=$(date +%Y%m%d_%H%M%S)
DUMP_FILE="${OUTPUT_DIR}/${DB}_${DATE}.dump"

# Проверяем, что контейнер существует и работает
if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "ERROR: контейнер $CONTAINER не найден или не запущен" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

# Дамп БД
if docker exec "$CONTAINER" pg_dump \
    -U postgres \
    -d "$DB" \
    --format=custom \
    --no-owner \
    --no-privileges \
    > "$DUMP_FILE"; then
    echo "OK: $DB → $DUMP_FILE ($(du -sh "$DUMP_FILE" | cut -f1))"
else
    echo "FAIL: $DB — pg_dump вернул ошибку" >&2
    rm -f "$DUMP_FILE"
    exit 2
fi

# Заодно — globals (роли) ОДИН РАЗ за прогон, не на каждую БД.
# Если файл globals_${DATE_PREFIX}.sql уже существует за этот час — пропускаем.
DATE_PREFIX=$(date +%Y%m%d_%H)
GLOBALS_FILE="${OUTPUT_DIR}/globals_${DATE_PREFIX}0000.sql"

if [ ! -f "$GLOBALS_FILE" ]; then
    if docker exec "$CONTAINER" pg_dumpall -U postgres --globals-only > "$GLOBALS_FILE"; then
        echo "OK: globals → $GLOBALS_FILE"
    else
        echo "WARN: globals dump не удался (роли не сохранены) — продолжаем" >&2
        rm -f "$GLOBALS_FILE"
    fi
fi

echo "$DUMP_FILE"