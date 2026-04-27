#!/usr/bin/env bash
# rotate-api-token.sh — общий шаблон ротации API token.
#
# Поскольку каждый провайдер выдаёт токены через свой UI/API, скрипт автоматизирует
# только серверную часть (подмена в .env + restart + verify). Создание нового
# токена и отзыв старого — оператор делает в провайдерской панели вручную.
#
# Использование:
#   bash rotate-api-token.sh \
#       --server <user>@<your-server> \
#       --env-file /opt/<service>/.env \
#       --var-name TELEGRAM_BOT_TOKEN \
#       --new-token "<токен из BotFather>" \
#       --consumer-dir /opt/<service> \
#       --verify-cmd 'curl -sS "https://api.telegram.org/bot$TOKEN/getMe" | jq -e .ok'

set -euo pipefail

SERVER=""
ENV_FILE=""
VAR_NAME=""
NEW=""
CONSUMER_DIR=""
VERIFY_CMD=""

while [ $# -gt 0 ]; do
    case "$1" in
        --server) SERVER="$2"; shift 2 ;;
        --env-file) ENV_FILE="$2"; shift 2 ;;
        --var-name) VAR_NAME="$2"; shift 2 ;;
        --new-token) NEW="$2"; shift 2 ;;
        --consumer-dir) CONSUMER_DIR="$2"; shift 2 ;;
        --verify-cmd) VERIFY_CMD="$2"; shift 2 ;;
        *) echo "Неизвестный аргумент: $1"; exit 2 ;;
    esac
done

for required in SERVER ENV_FILE VAR_NAME NEW CONSUMER_DIR; do
    if [ -z "${!required}" ]; then
        echo "Отсутствует --${required,,}"
        exit 2
    fi
done

echo "=== Ротация API token: $VAR_NAME ==="

# 1. Подмена в .env (с .bak страховкой)
echo "[1/3] Подменяем в $ENV_FILE..."
ssh "$SERVER" "sed -i.bak 's|^${VAR_NAME}=.*|${VAR_NAME}=${NEW}|' '$ENV_FILE'"

# 2. Restart сервиса
echo "[2/3] Restart $CONSUMER_DIR..."
ssh "$SERVER" "cd '$CONSUMER_DIR' && docker compose restart"
sleep 3

# 3. Verify
if [ -n "$VERIFY_CMD" ]; then
    echo "[3/3] Verify через test API call..."
    EXPORT_VERIFY="export TOKEN='$NEW' && $VERIFY_CMD"
    if eval "$EXPORT_VERIFY"; then
        echo "  ✓ Новый токен работает"
    else
        echo "  ✗ Verify FAILED — откати на старый из ${ENV_FILE}.bak"
        exit 3
    fi
else
    echo "[3/3] Verify пропущен (--verify-cmd не задан)"
    echo "  Проверь вручную, что сервис работает: docker logs --tail 20"
fi

echo ""
echo "=== Готово ==="
echo "Следующие шаги вручную:"
echo "  1. Revoke старого токена в провайдерской панели"
echo "  2. Обнови inventory/shared/access.md"
echo "  3. Создай incidents/$(date +%Y-%m-%d)-rotate-${VAR_NAME}.md"