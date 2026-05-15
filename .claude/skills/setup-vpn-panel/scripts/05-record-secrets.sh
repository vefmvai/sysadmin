#!/usr/bin/env bash
# 05-record-secrets.sh — запись кредов панели в менеджер паролей оператора.
#
# Использует api_store_secret() из scripts/lib-api/3xui.sh.
#
# Вход через ENV:
#   MANAGER           — keychain | pass | bw | op (из sysadmin-config.json)
#   SERVER_ALIAS      — alias сервера (для имени записи)
#   DOMAIN            — домен панели
#   PANEL_PORT        — порт панели
#   WEB_BASE_PATH     — webBasePath
#   ADMIN_LOGIN       — логин
#   ADMIN_PASSWORD    — пароль (передаётся через stdin или ENV)
#
# Выход:
#   0 — запись создана
#   1 — ошибка

set -euo pipefail

# Путь к library — относительно этого скрипта
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
LIB_PATH="${REPO_ROOT}/scripts/lib-api/3xui.sh"

if [ ! -f "$LIB_PATH" ]; then
    echo "ERROR: не найдена библиотека $LIB_PATH" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$LIB_PATH"

MANAGER="${MANAGER:?MANAGER обязателен}"
SERVER_ALIAS="${SERVER_ALIAS:?SERVER_ALIAS обязателен}"
DOMAIN="${DOMAIN:?DOMAIN обязателен}"
PANEL_PORT="${PANEL_PORT:?PANEL_PORT обязателен}"
WEB_BASE_PATH="${WEB_BASE_PATH:?WEB_BASE_PATH обязателен}"
ADMIN_LOGIN="${ADMIN_LOGIN:?ADMIN_LOGIN обязателен}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:?ADMIN_PASSWORD обязателен}"

# Очищаем webBasePath от слешей
WEB_BASE_PATH_CLEAN="${WEB_BASE_PATH#/}"
WEB_BASE_PATH_CLEAN="${WEB_BASE_PATH_CLEAN%/}"

PANEL_URL="https://${DOMAIN}:${PANEL_PORT}/${WEB_BASE_PATH_CLEAN}/"
SERVICE_NAME="3xui-panel-${SERVER_ALIAS}"

echo "[secrets] Запись в $MANAGER:"
echo "  service:  $SERVICE_NAME"
echo "  account:  $ADMIN_LOGIN"
echo "  url:      $PANEL_URL"

# Используем helper из lib-api
api_store_secret \
    --manager "$MANAGER" \
    --service "$SERVICE_NAME" \
    --account "$ADMIN_LOGIN" \
    --secret "$ADMIN_PASSWORD" \
    --url "$PANEL_URL" \
    --notes "3X-UI panel admin credentials, server=$SERVER_ALIAS"

echo "[secrets] Готово."
echo ""
echo "Для последующих вызовов API через _lib-api.sh используется ссылка:"
echo "  --password-ref 'keychain:$SERVICE_NAME' (для macOS)"
echo "  --password-ref 'pass:$SERVICE_NAME'     (для Unix pass)"
echo "  --password-ref 'bw:$SERVICE_NAME'       (для Bitwarden)"
echo "  --password-ref 'op:Private/$SERVICE_NAME/password' (для 1Password)"

exit 0
