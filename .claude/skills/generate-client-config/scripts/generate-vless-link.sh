#!/bin/bash
# generate-vless-link.sh — собрать vless://-URI для клиента из inbound панели.
#
# Скилл получает inbound_id + client_uuid + параметры с панели, формирует URI.
# Поддерживает:
#  - vless-tcp без шифрования (для ru-server inbound).
#  - vless-reality с serverName, fingerprint, publicKey, shortId, spiderX, flow.
#
# Вход через ENV:
#   PANEL_DOMAIN, PANEL_PORT, WEB_BASE_PATH, ADMIN_LOGIN, PASSWORD_REF
#   INBOUND_ID    — ID inbound в панели
#   CLIENT_UUID   — UUID существующего клиента в этом inbound
#   PUBLIC_ADDRESS — публичный адрес VPN-сервера (домен), на который клиент
#                    подключается. Если не задан — берётся из PANEL_DOMAIN
#                    (типично совпадает).
#   TAG_NAME       — имя клиента в URI fragment (default: client_email из API)
#
# Выход (на stdout): одна строка с vless://-URI.

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
INBOUND_ID="${INBOUND_ID:?обязателен}"
CLIENT_UUID="${CLIENT_UUID:?обязателен}"
PUBLIC_ADDRESS="${PUBLIC_ADDRESS:-$PANEL_DOMAIN}"

api_login \
    --domain "$PANEL_DOMAIN" \
    --port "$PANEL_PORT" \
    --web-path "$WEB_BASE_PATH" \
    --admin "$ADMIN_LOGIN" \
    --password-ref "$PASSWORD_REF"

# Получаем inbound
INBOUND_RAW="$(api_call GET "/panel/api/inbounds/get/${INBOUND_ID}")"
INBOUND="$(echo "$INBOUND_RAW" | jq '.obj')"

# Парсим settings и streamSettings (они строки внутри JSON)
SETTINGS="$(echo "$INBOUND" | jq -r '.settings' | jq '.')"
STREAM_SETTINGS="$(echo "$INBOUND" | jq -r '.streamSettings' | jq '.')"

# Проверяем, что клиент с этим UUID есть
CLIENT_EXISTS="$(echo "$SETTINGS" | jq --arg uuid "$CLIENT_UUID" '[.clients[] | select(.id == $uuid)] | length')"
if [ "$CLIENT_EXISTS" -eq 0 ]; then
    echo "ERROR: клиент с UUID=$CLIENT_UUID не найден в inbound $INBOUND_ID" >&2
    exit 1
fi

# Параметры клиента
CLIENT_EMAIL="$(echo "$SETTINGS" | jq -r --arg uuid "$CLIENT_UUID" '.clients[] | select(.id == $uuid) | .email')"
CLIENT_FLOW="$(echo "$SETTINGS" | jq -r --arg uuid "$CLIENT_UUID" '.clients[] | select(.id == $uuid) | .flow // ""')"

# Параметры inbound
PORT="$(echo "$INBOUND" | jq -r '.port')"
PROTOCOL="$(echo "$INBOUND" | jq -r '.protocol')"

if [ "$PROTOCOL" != "vless" ]; then
    echo "ERROR: inbound $INBOUND_ID не vless (protocol=$PROTOCOL). Этот скрипт только для VLESS." >&2
    exit 1
fi

# Сборка URI
NETWORK="$(echo "$STREAM_SETTINGS" | jq -r '.network')"
SECURITY="$(echo "$STREAM_SETTINGS" | jq -r '.security')"

# URL-encoding для значений query
urlencode() {
    local s="$1"
    local result=""
    local i=0
    while [ $i -lt ${#s} ]; do
        local c="${s:$i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) result="${result}${c}" ;;
            *) result="${result}$(printf '%%%02X' "'$c")" ;;
        esac
        i=$((i + 1))
    done
    printf '%s' "$result"
}

TAG_NAME="${TAG_NAME:-$CLIENT_EMAIL}"
TAG_ENCODED="$(urlencode "$TAG_NAME")"

QUERY_PARTS=()
QUERY_PARTS+=("type=${NETWORK}")
QUERY_PARTS+=("security=${SECURITY}")
[ -n "$CLIENT_FLOW" ] && QUERY_PARTS+=("flow=${CLIENT_FLOW}")

if [ "$SECURITY" = "reality" ]; then
    REALITY="$(echo "$STREAM_SETTINGS" | jq '.realitySettings')"
    SNI="$(echo "$REALITY" | jq -r '.serverNames[0] // .settings.serverName // ""')"
    PUBLIC_KEY="$(echo "$REALITY" | jq -r '.settings.publicKey // ""')"
    FP="$(echo "$REALITY" | jq -r '.settings.fingerprint // "chrome"')"
    SHORT_ID="$(echo "$REALITY" | jq -r '.shortIds[0] // ""')"
    SPIDER_X="$(echo "$REALITY" | jq -r '.settings.spiderX // "/"')"

    QUERY_PARTS+=("sni=$(urlencode "$SNI")")
    QUERY_PARTS+=("pbk=$(urlencode "$PUBLIC_KEY")")
    QUERY_PARTS+=("fp=${FP}")
    [ -n "$SHORT_ID" ] && QUERY_PARTS+=("sid=${SHORT_ID}")
    QUERY_PARTS+=("spx=$(urlencode "$SPIDER_X")")
elif [ "$SECURITY" = "tls" ]; then
    TLS_SETTINGS="$(echo "$STREAM_SETTINGS" | jq '.tlsSettings')"
    SNI="$(echo "$TLS_SETTINGS" | jq -r '.serverName // ""')"
    FP="$(echo "$TLS_SETTINGS" | jq -r '.fingerprint // "chrome"')"

    QUERY_PARTS+=("sni=$(urlencode "$SNI")")
    QUERY_PARTS+=("fp=${FP}")
fi

# Дополнительные поля для разных transport
if [ "$NETWORK" = "ws" ]; then
    WS="$(echo "$STREAM_SETTINGS" | jq '.wsSettings')"
    WS_PATH="$(echo "$WS" | jq -r '.path // "/"')"
    WS_HOST="$(echo "$WS" | jq -r '.headers.Host // .headers.host // ""')"
    QUERY_PARTS+=("path=$(urlencode "$WS_PATH")")
    [ -n "$WS_HOST" ] && QUERY_PARTS+=("host=$(urlencode "$WS_HOST")")
elif [ "$NETWORK" = "grpc" ]; then
    GRPC="$(echo "$STREAM_SETTINGS" | jq '.grpcSettings')"
    SERVICE_NAME="$(echo "$GRPC" | jq -r '.serviceName // ""')"
    [ -n "$SERVICE_NAME" ] && QUERY_PARTS+=("serviceName=$(urlencode "$SERVICE_NAME")")
fi

QUERY="$(IFS='&'; echo "${QUERY_PARTS[*]}")"

# Финальный URI
URI="vless://${CLIENT_UUID}@${PUBLIC_ADDRESS}:${PORT}?${QUERY}#${TAG_ENCODED}"

echo "$URI"

api_logout >&2
exit 0
