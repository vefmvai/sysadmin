#!/bin/bash
# 02-create-mixed-inbound.sh — создать mixed inbound для серверного прокси.
#
# Mixed inbound = SOCKS5 + HTTP на одном порту (3X-UI Mixed = обёртка над
# Xray SOCKS inbound с HTTP-совместимостью, см. vpn-protocols.md §5.1).
#
# Вход через ENV:
#   PANEL_DOMAIN, PANEL_PORT, WEB_BASE_PATH, ADMIN_LOGIN, PASSWORD_REF
#   PROXY_PORT — порт mixed inbound (default: 1080)
#   PROXY_LISTEN — listen IP (default: 127.0.0.1)
#
# Выход (на stdout): JSON с inbound_id и портом.

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
PROXY_PORT="${PROXY_PORT:-1080}"
PROXY_LISTEN="${PROXY_LISTEN:-127.0.0.1}"

if [ "$PROXY_LISTEN" != "127.0.0.1" ]; then
    echo "WARN: PROXY_LISTEN=$PROXY_LISTEN (не 127.0.0.1) — mixed inbound будет торчать в сеть!" >&2
    echo "WARN: это небезопасно (SOCKS без аутентификации). Подтвердить намеренно." >&2
fi

api_login \
    --domain "$PANEL_DOMAIN" \
    --port "$PANEL_PORT" \
    --web-path "$WEB_BASE_PATH" \
    --admin "$ADMIN_LOGIN" \
    --password-ref "$PASSWORD_REF"

# Проверяем, что mixed inbound на этом порту ещё не существует
EXISTING="$(api_call GET "/panel/api/inbounds/list" \
    | jq --arg port "$PROXY_PORT" '[.obj[] | select(.protocol == "mixed" and (.port | tostring) == $port)] | length')"

if [ "$EXISTING" -gt 0 ]; then
    echo "WARN: mixed inbound на порту $PROXY_PORT уже существует, пропускаю создание" >&2
    EXISTING_ID="$(api_call GET "/panel/api/inbounds/list" \
        | jq --arg port "$PROXY_PORT" '.obj[] | select(.protocol == "mixed" and (.port | tostring) == $port) | .id' | head -n1)"

    jq -nc \
        --argjson id "$EXISTING_ID" \
        --arg listen "$PROXY_LISTEN" \
        --argjson port "$PROXY_PORT" \
        '{inbound_id: $id, listen: $listen, port: $port, status: "existed"}'

    api_logout >&2
    exit 0
fi

# Settings для mixed (SOCKS5 + HTTP):
SETTINGS_JSON='{"auth":"noauth","udp":false,"ip":"127.0.0.1"}'
STREAM_SETTINGS_JSON='{"network":"tcp","security":"none"}'
SNIFFING_JSON='{"enabled":true,"destOverride":["http","tls","quic"]}'

INBOUND_TAG="mixed-server-proxy"
# remark виден оператору в панели — делаем его понятным новичку (что это и зачем).
INBOUND_JSON="$(jq -nc \
    --arg remark "🔌 локальный прокси для программ на сервере ($PROXY_LISTEN:$PROXY_PORT, SOCKS5+HTTP)" \
    --arg listen "$PROXY_LISTEN" \
    --argjson port "$PROXY_PORT" \
    --arg tag "$INBOUND_TAG" \
    --arg settings "$SETTINGS_JSON" \
    --arg stream "$STREAM_SETTINGS_JSON" \
    --arg sniffing "$SNIFFING_JSON" \
    '{
        remark: $remark,
        enable: true,
        expiryTime: 0,
        listen: $listen,
        port: $port,
        protocol: "mixed",
        settings: $settings,
        streamSettings: $stream,
        tag: $tag,
        sniffing: $sniffing
    }')"

echo "[mixed-in] Создаю mixed inbound на $PROXY_LISTEN:$PROXY_PORT..." >&2
RESULT="$(api_call POST "/panel/api/inbounds/add" --json-body "$INBOUND_JSON")"

INBOUND_ID="$(echo "$RESULT" | jq -r '.obj.id // empty')"
if [ -z "$INBOUND_ID" ]; then
    echo "ERROR: не удалось извлечь inbound_id" >&2
    echo "$RESULT" >&2
    exit 1
fi

api_restart_xray >&2

echo "[mixed-in] ✓ Создан: id=$INBOUND_ID tag=$INBOUND_TAG" >&2

jq -nc \
    --argjson id "$INBOUND_ID" \
    --arg listen "$PROXY_LISTEN" \
    --argjson port "$PROXY_PORT" \
    --arg tag "$INBOUND_TAG" \
    '{inbound_id: $id, listen: $listen, port: $port, tag: $tag, status: "created"}'

api_logout >&2
exit 0
