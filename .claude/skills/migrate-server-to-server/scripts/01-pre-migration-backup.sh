#!/usr/bin/env bash
# 01-pre-migration-backup.sh — обязательный бэкап перед миграцией.
#
# БЕЗ ЭТОГО СКРИПТА МИГРАЦИЯ НЕ НАЧИНАЕТСЯ. Создаёт три типа страховки:
#   1. Логический дамп всех БД (pg_dumpall)
#   2. tar архив всех Docker volumes
#   3. Запись в restic offsite repository
#
# Использование:
#   bash 01-pre-migration-backup.sh user@old.vps.com
#
# На выходе:
#   /backup/pre-migration-YYYYMMDD-HHMMSS/full.sql.gz
#   /backup/pre-migration-YYYYMMDD-HHMMSS/docker-volumes.tar.gz
#   restic snapshot с тегом pre-migration-YYYYMMDD

set -euo pipefail

OLD_SERVER="${1:-}"
if [ -z "$OLD_SERVER" ]; then
    echo "Использование: $0 user@old.vps.com"
    exit 2
fi

TS=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/backup/pre-migration-${TS}"

echo "=== Pre-migration backup: $OLD_SERVER → $BACKUP_DIR ==="

# 1. Создать директорию на удалённом сервере
ssh "$OLD_SERVER" "mkdir -p '$BACKUP_DIR'"

# 2. Логический дамп всех БД (pg_dumpall работает с любым клиентом, ловит роли)
echo "[1/3] pg_dumpall..."
ssh "$OLD_SERVER" "
    docker exec postgres pg_dumpall -U postgres | gzip > '$BACKUP_DIR/full.sql.gz'
    ls -lh '$BACKUP_DIR/full.sql.gz'
"

# 3. tar архив всех Docker volumes (через alpine helper для прав)
echo "[2/3] tar volumes..."
ssh "$OLD_SERVER" "
    tar czf '$BACKUP_DIR/docker-volumes.tar.gz' /var/lib/docker/volumes/
    ls -lh '$BACKUP_DIR/docker-volumes.tar.gz'
"

# 4. restic backup с тегом
echo "[3/3] restic backup..."
ssh "$OLD_SERVER" "
    restic backup '$BACKUP_DIR' --tag pre-migration --tag '$TS'
    restic snapshots --tag pre-migration --json | tail -3
"

echo "=== Backup готов: $BACKUP_DIR ==="
echo ""
echo "Проверка целостности (test restore на staging):"
echo "  restic restore latest --target /tmp/test-restore --tag pre-migration"
echo ""
echo "Если staging нет — минимум проверь что архив не битый:"
echo "  ssh $OLD_SERVER 'gunzip -t $BACKUP_DIR/full.sql.gz && tar tzf $BACKUP_DIR/docker-volumes.tar.gz | head -5'"