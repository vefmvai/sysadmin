#!/bin/bash
# add-outbound-from-vless.sh — добавить outbound в xray-конфиг из распарсенной
# vless://-ссылки (либо от провайдера, либо со своего загр.VPS).
#
# Особенность: outbounds в 3X-UI не имеют отдельного API-эндпоинта.
# Работа идёт через getXrayConfig → modify → updateXrayConfig.
#
# Вход через ENV:
#   PANEL_DOMAIN, PANEL_PORT, WEB_BASE_PATH, ADMIN_LOGIN, PASSWORD_REF
#   VLESS_JSON   — JSON-результат parse-vless-link.sh (один объект)
#   OUTBOUND_TAG_PREFIX — префикс tag (default: "upstream"). Скрипт добавляет
#                        к нему индекс/имя из tag VLESS-ссылки.
#
# Выход (на stdout): JSON с финальным tag созданного outbound.
#   { "tag": "upstream-de" }

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
VLESS_JSON="${VLESS_JSON:?VLESS_JSON обязателен (результат parse-vless-link.sh)}"
OUTBOUND_TAG_PREFIX="${OUTBOUND_TAG_PREFIX:-upstream}"

# Распарсим VLESS_JSON
UUID="$(echo "$VLESS_JSON" | jq -r '.uuid')"
HOST="$(echo "$VLESS_JSON" | jq -r '.host')"
PORT="$(echo "$VLESS_JSON" | jq -r '.port')"
SECURITY="$(echo "$VLESS_JSON" | jq -r '.security')"
SNI="$(echo "$VLESS_JSON" | jq -r '.sni // empty')"
FP="$(echo "$VLESS_JSON" | jq -r '.fp // empty')"
PBK="$(echo "$VLESS_JSON" | jq -r '.pbk // empty')"
SID="$(echo "$VLESS_JSON" | jq -r '.sid // empty')"
SPX="$(echo "$VLESS_JSON" | jq -r '.spx // "/"')"
FLOW="$(echo "$VLESS_JSON" | jq -r '.flow // empty')"
TAG_FROM_LINK="$(echo "$VLESS_JSON" | jq -r '.tag // empty')"
TYPE="$(echo "$VLESS_JSON" | jq -r '.type // "tcp"')"

# Финальный tag — slugify
if [ -n "$TAG_FROM_LINK" ]; then
    SLUG="$(echo "$TAG_FROM_LINK" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-' | head -c 20)"
    [ -z "$SLUG" ] && SLUG="server"
else
    SLUG="server"
fi
FINAL_TAG="${OUTBOUND_TAG_PREFIX}-${SLUG}"

# Login
api_login \
    --domain "$PANEL_DOMAIN" \
    --port "$PANEL_PORT" \
    --web-path "$WEB_BASE_PATH" \
    --admin "$ADMIN_LOGIN" \
    --password-ref "$PASSWORD_REF"

# Получаем текущий xray-конфиг
CURRENT_CONFIG_RESPONSE="$(api_call GET "/panel/api/inbounds/getXrayConfig")"
CURRENT_CONFIG="$(echo "$CURRENT_CONFIG_RESPONSE" | jq '.obj')"

# Формируем streamSettings под security
if [ "$SECURITY" = "reality" ]; then
    [ -z "$PBK" ] && { echo "ERROR: для reality нужен pbk (public key) в VLESS_JSON" >&2; exit 1; }
    STREAM_SETTINGS="$(jq -nc \
        --arg sni "$SNI" \
        --arg fp "${FP:-chrome}" \
        --arg pbk "$PBK" \
        --arg sid "$SID" \
        --arg spx "$SPX" \
        '{
            network: "tcp",
            security: "reality",
            realitySettings: {
                show: false,
                fingerprint: $fp,
                serverName: $sni,
                publicKey: $pbk,
                shortId: $sid,
                spiderX: $spx
            }
        }')"
elif [ "$SECURITY" = "tls" ]; then
    STREAM_SETTINGS="$(jq -nc \
        --arg sni "$SNI" \
        --arg fp "${FP:-chrome}" \
        '{
            network: "tcp",
            security: "tls",
            tlsSettings: {
                serverName: $sni,
                fingerprint: $fp,
                alpn: ["h2", "http/1.1"]
            }
        }')"
else
    STREAM_SETTINGS="$(jq -nc --arg type "$TYPE" '{network: $type, security: "none"}')"
fi

# Outbound JSON
OUTBOUND_OBJ="$(jq -nc \
    --arg tag "$FINAL_TAG" \
    --arg host "$HOST" \
    --argjson port "$PORT" \
    --arg uuid "$UUID" \
    --arg flow "$FLOW" \
    --argjson stream "$STREAM_SETTINGS" \
    '{
        tag: $tag,
        protocol: "vless",
        settings: {
            vnext: [{
                address: $host,
                port: $port,
                users: [{
                    id: $uuid,
                    encryption: "none",
                    flow: $flow
                }]
            }]
        },
        streamSettings: $stream
    }')"

# Добавляем outbound в массив — но сначала удаляем существующий с таким же tag (idempotency)
NEW_CONFIG="$(echo "$CURRENT_CONFIG" | jq \
    --arg tag "$FINAL_TAG" \
    --argjson outbound "$OUTBOUND_OBJ" \
    '.outbounds = (.outbounds // []) | .outbounds |= map(select(.tag != $tag)) | .outbounds += [$outbound]')"

# Обновляем конфиг через API
echo "[outbound] Добавляю outbound: tag=$FINAL_TAG host=$HOST port=$PORT security=$SECURITY" >&2
api_update_xray_config "$NEW_CONFIG" >&2

# Verify
VERIFY="$(api_call GET "/panel/api/inbounds/getXrayConfig" | jq -r --arg tag "$FINAL_TAG" '.obj.outbounds[] | select(.tag == $tag) | .tag')"

if [ "$VERIFY" != "$FINAL_TAG" ]; then
    echo "ERROR: верификация: outbound с tag=$FINAL_TAG не найден после обновления" >&2
    exit 1
fi

api_restart_xray >&2

echo "[outbound] ✓ Outbound создан: tag=$FINAL_TAG" >&2

jq -nc --arg tag "$FINAL_TAG" '{tag: $tag}'

api_logout >&2
exit 0
