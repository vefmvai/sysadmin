#!/usr/bin/env bash
# 04-post-migration-verify.sh — проверка целостности после миграции.
#
# Сравнивает row counts на старом и новом сервере, проверяет healthcheck'и,
# TLS-срок, бэкапы, cron entries.
#
# Использование:
#   bash 04-post-migration-verify.sh user@old.vps.com user@new.vps.com domain1 [domain2 ...]
#
# Если всё PASS — старый сервер можно отключить через safe-период (1-2 недели).
# Если хоть один FAIL — НЕ ВЫКЛЮЧАЙ старый, расследуй.

set -uo pipefail

OLD_SERVER="${1:-}"
NEW_SERVER="${2:-}"
shift 2 || true
DOMAINS=("$@")

if [ -z "$OLD_SERVER" ] || [ -z "$NEW_SERVER" ]; then
    echo "Использование: $0 user@old.vps.com user@new.vps.com domain1 [domain2 ...]"
    exit 2
fi

PASS=0
FAIL=0

ok()   { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

echo "=== Post-migration verify ==="
echo ""

# 1. Row counts — главная метрика отсутствия потерь
echo "[1/5] Row counts (PostgreSQL)..."
DBS=$(ssh "$OLD_SERVER" "docker exec postgres psql -U postgres -tAc \
    \"SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres'\"" || echo "")
for db in $DBS; do
    OLD_TABLES=$(ssh "$OLD_SERVER" "docker exec postgres psql -U postgres -d $db -tAc \
        \"SELECT count(*) FROM pg_stat_user_tables\"" 2>/dev/null || echo "0")
    NEW_TABLES=$(ssh "$NEW_SERVER" "docker exec postgres psql -U postgres -d $db -tAc \
        \"SELECT count(*) FROM pg_stat_user_tables\"" 2>/dev/null || echo "0")
    if [ "$OLD_TABLES" = "$NEW_TABLES" ] && [ "$OLD_TABLES" != "0" ]; then
        ok "$db: $OLD_TABLES таблиц на обоих"
    else
        fail "$db: старый=$OLD_TABLES новый=$NEW_TABLES"
    fi
done

# 2. Healthcheck'и доменов
echo ""
echo "[2/5] Healthcheck доменов (через DNS, после propagation)..."
for domain in "${DOMAINS[@]}"; do
    if curl -sSf -o /dev/null "https://$domain/" 2>/dev/null; then
        ok "$domain отвечает"
    else
        fail "$domain не отвечает"
    fi
done

# 3. TLS-срок на новом сервере
echo ""
echo "[3/5] TLS-сертификаты на новом сервере..."
for domain in "${DOMAINS[@]}"; do
    EXPIRY=$(echo | openssl s_client -connect "$domain:443" -servername "$domain" 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || echo "")
    if [ -n "$EXPIRY" ]; then
        ok "$domain: $EXPIRY"
    else
        fail "$domain: TLS не работает"
    fi
done

# 4. Бэкапы работают на новом
echo ""
echo "[4/5] Бэкапы на новом сервере..."
if ssh "$NEW_SERVER" "restic snapshots --json 2>/dev/null | tail -1 | grep -q '\"time\"'"; then
    ok "restic snapshots доступны"
else
    fail "restic snapshots недоступны (или restic не настроен)"
fi

# 5. Cron entries активны
echo ""
echo "[5/5] Cron entries на новом..."
CRON_LINES=$(ssh "$NEW_SERVER" "crontab -l 2>/dev/null | grep -cv '^#' || echo 0")
if [ "$CRON_LINES" -gt 0 ]; then
    ok "$CRON_LINES активных cron-задач в crontab root"
else
    fail "0 активных cron-задач (проверь /etc/cron.d/ тоже)"
fi

echo ""
echo "=== Итог: $PASS PASS / $FAIL FAIL ==="
if [ "$FAIL" -eq 0 ]; then
    echo ""
    echo "✓ Миграция прошла успешно. Старый сервер можно держать 1-2 недели как страховку,"
    echo "  затем отключить."
    exit 0
else
    echo ""
    echo "✗ Найдены FAIL'ы. НЕ ВЫКЛЮЧАЙ старый сервер. Расследуй проблемы."
    exit 1
fi