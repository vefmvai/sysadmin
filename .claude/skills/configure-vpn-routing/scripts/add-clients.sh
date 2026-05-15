#!/bin/bash
# add-clients.sh — массовое добавление клиентов к существующему inbound.
#
# Поведение:
#  - Для каждого client_email из CLIENT_NAMES_JSON генерирует UUID и добавляет
#    к inbound через POST /panel/api/inbounds/addClient.
#  - Пауза 150ms между запросами (защита от SQLite locking, см. 3x-ui-api.md §12.1).
#  - При ошибке на одном клиенте — продолжает с следующим, фиксирует в отчёте.
#
# Вход через ENV:
#   PANEL_DOMAIN, PANEL_PORT, WEB_BASE_PATH, ADMIN_LOGIN, PASSWORD_REF
#   INBOUND_ID         — ID inbound, куда добавлять клиентов
#   CLIENT_NAMES_JSON  — JSON-массив имён (например, ["alice", "bob", "mum"])
#
# Выход (на stdout): JSON-массив добавленных клиентов с их UUID:
#   [{ "email": "alice", "uuid": "...", "added": true },
#    { "email": "bob",   "uuid": "...", "added": true }]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
LIB="${REPO_ROOT}/scripts/lib-api/3xui.sh"
# shellcheck source=/dev/null
source "$LIB"

PANEL_DOMAIN="${PANEL_DOMAIN:?обязателен}"
PANEL_PORT="${PANEL_PORT:?обязателен}"
WEB_BASE_PATH="${WEB_BASE_PATH:?обязателен}"
ADMIN_LOGIN="${ADMIN_LOGIN:?обязателен}"
PASSWORD_REF="${PASSWORD_REF:?обязателен}"
INBOUND_ID="${INBOUND_ID:?INBOUND_ID обязателен}"
CLIENT_NAMES_JSON="${CLIENT_NAMES_JSON:?CLIENT_NAMES_JSON обязателен}"

# Login
api_login \
    --domain "$PANEL_DOMAIN" \
    --port "$PANEL_PORT" \
    --web-path "$WEB_BASE_PATH" \
    --admin "$ADMIN_LOGIN" \
    --password-ref "$PASSWORD_REF"

# Получаем flow из существующего inbound (чтобы новые клиенты имели тот же flow)
INBOUND_INFO="$(api_call GET "/panel/api/inbounds/get/${INBOUND_ID}")"
INBOUND_FLOW="$(echo "$INBOUND_INFO" | jq -r '.obj.settings | fromjson | .clients[0].flow // ""')"

RESULTS="[]"
# Парсим имена и итерируем
while IFS= read -r email; do
    [ -z "$email" ] && continue

    UUID="$(api_gen_uuid)"

    # JSON для addClient: settings.clients = [новый клиент]
    CLIENT_SETTINGS="$(jq -nc \
        --arg uuid "$UUID" \
        --arg email "$email" \
        --arg flow "$INBOUND_FLOW" \
        '{
            clients: [{
                id: $uuid,
                flow: $flow,
                email: $email,
                limitIp: 0,
                totalGB: 0,
                expiryTime: 0,
                enable: true,
                tgId: "",
                subId: "",
                reset: 0
            }]
        }')"

    ADD_BODY="$(jq -nc \
        --argjson id "$INBOUND_ID" \
        --arg settings "$CLIENT_SETTINGS" \
        '{id: $id, settings: $settings}')"

    if api_call POST "/panel/api/inbounds/addClient" --json-body "$ADD_BODY" >/dev/null 2>&1; then
        ADDED="true"
        echo "[add-clients] ✓ $email (UUID=$UUID)" >&2
    else
        ADDED="false"
        echo "[add-clients] ✗ $email — ошибка API" >&2
    fi

    # Накапливаем в результат
    RESULTS="$(echo "$RESULTS" | jq \
        --arg email "$email" \
        --arg uuid "$UUID" \
        --arg added "$ADDED" \
        '. + [{
            email: $email,
            uuid: $uuid,
            added: ($added == "true")
        }]')"
done < <(echo "$CLIENT_NAMES_JSON" | jq -r '.[]')

api_restart_xray >&2

echo "$RESULTS"

api_logout >&2
exit 0
