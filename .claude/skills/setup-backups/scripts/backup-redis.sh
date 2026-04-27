#!/usr/bin/env bash
# backup-redis.sh — снимок Redis через BGSAVE + копия dump.rdb
#
# Использование:
#   ./backup-redis.sh <container-name> [output-dir]
#
# Принципы:
# - BGSAVE (а не SAVE!) — fork процесса, не блокирует БД на больших датасетах
# - Ждём завершения через LASTSAVE (timestamp последнего успешного снимка)
# - Копируем dump.rdb из контейнера наружу через docker cp
# - Сжатие gzip — RDB обычно компактен, но gzip даёт ещё ~50%
#
# Замечание: BGSAVE асинхронный — даём 60 секунд на завершение для крупных БД.

set -euo pipefail

CONTAINER="${1:?Usage: backup-redis.sh <container> [output-dir]}"
OUTPUT_DIR="${2:-/opt/backups/dbs}"

DATE=$(date +%Y%m%d_%H%M%S)
DUMP_FILE="${OUTPUT_DIR}/redis-${CONTAINER}_${DATE}.rdb.gz"

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "ERROR: контейнер $CONTAINER не найден или не запущен" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

# Запоминаем предыдущий timestamp LASTSAVE, чтобы понять когда BGSAVE завершился
PREV_LASTSAVE=$(docker exec "$CONTAINER" redis-cli LASTSAVE)

# Запускаем BGSAVE
if ! docker exec "$CONTAINER" redis-cli BGSAVE | grep -q "Background saving started"; then
    echo "FAIL: BGSAVE не запустился (возможно, уже идёт другой)" >&2
    exit 2
fi

# Ждём до 60 секунд, пока LASTSAVE изменится
for i in $(seq 1 60); do
    NEW_LASTSAVE=$(docker exec "$CONTAINER" redis-cli LASTSAVE)
    if [ "$NEW_LASTSAVE" != "$PREV_LASTSAVE" ]; then
        break
    fi
    sleep 1
done

if [ "$NEW_LASTSAVE" = "$PREV_LASTSAVE" ]; then
    echo "FAIL: BGSAVE не завершился за 60 секунд" >&2
    exit 3
fi

# Копируем dump.rdb наружу
TMP_RDB="/tmp/redis-${CONTAINER}-${DATE}.rdb"
if docker cp "$CONTAINER:/data/dump.rdb" "$TMP_RDB"; then
    gzip -c "$TMP_RDB" > "$DUMP_FILE"
    rm -f "$TMP_RDB"
    echo "OK: $CONTAINER → $DUMP_FILE ($(du -sh "$DUMP_FILE" | cut -f1))"
else
    echo "FAIL: docker cp не удался" >&2
    exit 4
fi

echo "$DUMP_FILE"
