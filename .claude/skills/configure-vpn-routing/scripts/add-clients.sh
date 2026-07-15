#!/bin/bash
# add-clients.sh — массовое добавление клиентов к существующему inbound.
#
# Поведение:
#  - Для каждого client_email из CLIENT_NAMES_JSON добавляет клиента к inbound через
#    variant-aware враппер api_add_client (SPA: clients/add — UUID генерит ПАНЕЛЬ;
#    legacy: inbounds/addClient). Реальный UUID забирается перечитыванием входа по email
#    (api_get_client_uuid) — единый достоверный путь для обоих вариантов.
#  - Пауза между запросами — внутри api_call (защита от SQLite locking, см. 3x-ui-api.md §12.1).
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

# Получаем flow из существующего inbound (чтобы новые клиенты имели тот же flow).
# settings на SPA — объект, на legacy — строка → нормализуем перед разбором (иначе fromjson падает).
INBOUND_INFO="$(api_get_inbound "$INBOUND_ID")"
INBOUND_FLOW="$(echo "$INBOUND_INFO" | jq -r '(.obj.settings | if type=="string" then fromjson else . end).clients[0].flow // ""')"

RESULTS="[]"
# Парсим имена и итерируем
while IFS= read -r email; do
    [ -z "$email" ] && continue

    # Добавляем через variant-aware враппер. Свой UUID НЕ генерим: на SPA его назначает
    # панель (переданный игнорируется). Реальный UUID на обоих вариантах забираем
    # перечитыванием входа по email — это единственный достоверный источник на SPA.
    if api_add_client "$INBOUND_ID" "$email" "$INBOUND_FLOW" >/dev/null 2>&1; then
        UUID="$(api_get_client_uuid "$INBOUND_ID" "$email")"
        if [ -n "$UUID" ] && [ "$UUID" != "null" ]; then
            ADDED="true"
            echo "[add-clients] ✓ $email (UUID=$UUID)" >&2
        else
            ADDED="false"
            echo "[add-clients] ⚠ $email — добавлен, но UUID не прочитался (проверь панель)" >&2
        fi
    else
        UUID=""
        ADDED="false"
        echo "[add-clients] ✗ $email — ошибка API при добавлении" >&2
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
done < <(echo "$CLIENT_NAMES_JSON" | jq -r '.[]' | tr -d '\r')
# tr -d '\r': Windows-сборка jq выдаёт CRLF, и `read` иначе тащит \r в email
# (клиент с "papa\r" не добавляется / не находится по email). Скилл запускается и на
# Windows Git Bash оператора — стрипаем \r у источника.

api_restart_xray >&2

echo "$RESULTS"

api_logout >&2
exit 0
