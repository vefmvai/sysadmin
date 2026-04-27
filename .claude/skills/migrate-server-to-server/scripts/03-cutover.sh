#!/usr/bin/env bash
# 03-cutover.sh — финальное переключение на новый сервер.
#
# Шаги:
#   1. Поднять сервисы на новом
#   2. Smoke-test перед DNS switch (если хоть один сервис не отвечает — STOP)
#   3. Напомнить оператору про DNS switch (атомарная операция в панели DNS)
#   4. Мониторить propagation
#
# DNS switch скрипт НЕ автоматизирует — это сознательный выбор оператора,
# делает один клик в панели Cloudflare/Selectel/etc после успешного smoke-test.
#
# Использование:
#   bash 03-cutover.sh user@new.vps.com domain1 [domain2 ...]

set -euo pipefail

NEW_SERVER="${1:-}"
shift || true
DOMAINS=("$@")

if [ -z "$NEW_SERVER" ] || [ ${#DOMAINS[@]} -eq 0 ]; then
    echo "Использование: $0 user@new.vps.com domain1 [domain2 ...]"
    exit 2
fi

echo "=== Cutover: $NEW_SERVER ==="
echo "Домены для проверки: ${DOMAINS[*]}"
echo ""

# 1. Start всех сервисов на новом
echo "[1/4] Старт сервисов на новом сервере..."
ssh "$NEW_SERVER" "
    for compose in /opt/*/docker-compose.yml; do
        cd \$(dirname \$compose) && docker compose up -d || echo \"WARN: не поднялся \$compose\"
    done
"

# Дать сервисам прогреться
echo "[2/4] Жду 30 сек для прогрева..."
sleep 30

# 2. Smoke-test — каждый домен должен отвечать с нового сервера НАПРЯМУЮ по IP
NEW_IP=$(ssh "$NEW_SERVER" "curl -sS https://api.ipify.org" || echo "")
if [ -z "$NEW_IP" ]; then
    echo "ERROR: не смог определить IP нового сервера"
    exit 3
fi

echo "[3/4] Smoke-test (новый IP: $NEW_IP)..."
FAIL=0
for domain in "${DOMAINS[@]}"; do
    # Проверяем напрямую по IP (DNS ещё не переключён)
    if curl -sSf -o /dev/null -H "Host: $domain" --resolve "$domain:443:$NEW_IP" \
            "https://$domain/" 2>/dev/null; then
        echo "  PASS: $domain"
    else
        echo "  FAIL: $domain не отвечает на новом сервере"
        FAIL=1
    fi
done

if [ "$FAIL" -ne 0 ]; then
    echo ""
    echo "STOP: smoke-test не прошёл. НЕ переключай DNS."
    echo "Расследуй проблемы на новом сервере, после исправления повтори."
    exit 4
fi

# 3. Напоминание про DNS switch
echo ""
echo "=== [4/4] Smoke-test PASSED ==="
echo ""
echo "СЛЕДУЮЩИЙ ШАГ — DNS SWITCH (вручную в панели DNS):"
echo ""
for domain in "${DOMAINS[@]}"; do
    echo "  $domain → A → $NEW_IP (TTL 300)"
done
echo ""
echo "После DNS switch — мониторь propagation:"
echo "  for i in {1..20}; do dig ${DOMAINS[0]} +short; sleep 30; done"
echo ""
echo "После 5-10 минут propagation — bash 04-post-migration-verify.sh"