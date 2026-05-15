#!/bin/bash
# create-vless-inbound.sh — создать VLESS inbound в панели через REST API.
#
# Поддерживает два протокола:
#  - vless-tcp (без Reality, для ru-server inbound).
#  - vless-reality (для foreign-server inbound с маскировкой от DPI).
#
# Вход через ENV:
#   PANEL_DOMAIN, PANEL_PORT, WEB_BASE_PATH — параметры панели
#   ADMIN_LOGIN, PASSWORD_REF              — для login
#   INBOUND_REMARK         — человеко-читаемая метка (например, "vless-tcp-main")
#   INBOUND_LISTEN_PORT    — порт inbound на сервере (обычно 443)
#   INBOUND_PROTOCOL       — vless-tcp | vless-reality
#   INBOUND_FLOW           — пусто или xtls-rprx-vision
#   SSH_TARGET             — для генерации Reality keypair при vless-reality
#   REALITY_DEST           — для vless-reality (например, www.cloudflare.com)
#
# Выход (на stdout): JSON-объект созданного inbound + UUID первого клиента.
#   { "inbound_id": 1, "first_client_uuid": "...", "tag": "..." }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
LIB="${REPO_ROOT}/scripts/lib-api/3xui.sh"

# shellcheck source=/dev/null
source "$LIB"

PANEL_DOMAIN="${PANEL_DOMAIN:?PANEL_DOMAIN обязателен}"
PANEL_PORT="${PANEL_PORT:?PANEL_PORT обязателен}"
WEB_BASE_PATH="${WEB_BASE_PATH:?WEB_BASE_PATH обязателен}"
ADMIN_LOGIN="${ADMIN_LOGIN:?ADMIN_LOGIN обязателен}"
PASSWORD_REF="${PASSWORD_REF:?PASSWORD_REF обязателен (например, keychain:3xui-panel-XXX)}"
INBOUND_REMARK="${INBOUND_REMARK:-vless-main}"
INBOUND_LISTEN_PORT="${INBOUND_LISTEN_PORT:-443}"
INBOUND_PROTOCOL="${INBOUND_PROTOCOL:-vless-tcp}"
INBOUND_FLOW="${INBOUND_FLOW:-}"

# Login
api_login \
    --domain "$PANEL_DOMAIN" \
    --port "$PANEL_PORT" \
    --web-path "$WEB_BASE_PATH" \
    --admin "$ADMIN_LOGIN" \
    --password-ref "$PASSWORD_REF"

# Генерация UUID для первого клиента
CLIENT_UUID="$(api_gen_uuid)"
CLIENT_EMAIL="${CLIENT_EMAIL:-admin}"

# Подготовка settings и streamSettings в зависимости от протокола
case "$INBOUND_PROTOCOL" in
    vless-tcp)
        SETTINGS_JSON="$(jq -nc \
            --arg uuid "$CLIENT_UUID" \
            --arg flow "$INBOUND_FLOW" \
            --arg email "$CLIENT_EMAIL" \
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
                }],
                decryption: "none",
                fallbacks: []
            }')"

        STREAM_SETTINGS_JSON='{"network":"tcp","security":"none","tcpSettings":{"header":{"type":"none"}}}'
        ;;

    vless-reality)
        SSH_TARGET="${SSH_TARGET:?SSH_TARGET обязателен для vless-reality (для генерации ключей)}"
        REALITY_DEST="${REALITY_DEST:?REALITY_DEST обязателен для vless-reality}"

        # Генерация ключевой пары
        KEYPAIR_JSON="$(api_gen_reality_keypair "$SSH_TARGET")"
        PRIVATE_KEY="$(echo "$KEYPAIR_JSON" | jq -r '.private_key')"
        PUBLIC_KEY="$(echo "$KEYPAIR_JSON" | jq -r '.public_key')"

        # Короткий ID
        SHORT_ID="$(api_random_string 8 'a-f0-9' | tr '[:upper:]' '[:lower:]')"

        SETTINGS_JSON="$(jq -nc \
            --arg uuid "$CLIENT_UUID" \
            --arg flow "${INBOUND_FLOW:-xtls-rprx-vision}" \
            --arg email "$CLIENT_EMAIL" \
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
                }],
                decryption: "none",
                fallbacks: []
            }')"

        STREAM_SETTINGS_JSON="$(jq -nc \
            --arg dest "${REALITY_DEST}:443" \
            --arg sni "$REALITY_DEST" \
            --arg priv "$PRIVATE_KEY" \
            --arg pub "$PUBLIC_KEY" \
            --arg sid "$SHORT_ID" \
            '{
                network: "tcp",
                security: "reality",
                realitySettings: {
                    show: false,
                    xver: 0,
                    dest: $dest,
                    serverNames: [$sni],
                    privateKey: $priv,
                    shortIds: [$sid],
                    settings: {
                        publicKey: $pub,
                        fingerprint: "chrome",
                        serverName: $sni,
                        spiderX: "/"
                    }
                }
            }')"
        ;;

    *)
        echo "ERROR: INBOUND_PROTOCOL='$INBOUND_PROTOCOL' не поддерживается. Допустимо: vless-tcp, vless-reality" >&2
        exit 2
        ;;
esac

# Sniffing для маршрутизации по доменам
SNIFFING_JSON='{"enabled":true,"destOverride":["http","tls","quic"]}'

# Финальный объект inbound для API
INBOUND_TAG="inbound-${INBOUND_LISTEN_PORT}"
INBOUND_JSON="$(jq -nc \
    --arg remark "$INBOUND_REMARK" \
    --argjson port "$INBOUND_LISTEN_PORT" \
    --arg protocol "vless" \
    --arg tag "$INBOUND_TAG" \
    --arg settings "$SETTINGS_JSON" \
    --arg stream "$STREAM_SETTINGS_JSON" \
    --arg sniffing "$SNIFFING_JSON" \
    '{
        remark: $remark,
        enable: true,
        expiryTime: 0,
        listen: "",
        port: $port,
        protocol: $protocol,
        settings: $settings,
        streamSettings: $stream,
        tag: $tag,
        sniffing: $sniffing
    }')"

echo "[inbound] Создаю inbound: remark=$INBOUND_REMARK port=$INBOUND_LISTEN_PORT protocol=$INBOUND_PROTOCOL" >&2

# Создание через API
RESULT="$(api_call POST "/panel/api/inbounds/add" --json-body "$INBOUND_JSON")"

# Извлекаем ID нового inbound
INBOUND_ID="$(echo "$RESULT" | jq -r '.obj.id // empty')"

if [ -z "$INBOUND_ID" ]; then
    echo "ERROR: не удалось извлечь inbound_id из ответа" >&2
    echo "$RESULT" >&2
    exit 1
fi

# Финальная проверка — читаем inbound обратно
VERIFY="$(api_call GET "/panel/api/inbounds/get/${INBOUND_ID}")"
if [ "$(echo "$VERIFY" | jq -r '.obj.port')" != "$INBOUND_LISTEN_PORT" ]; then
    echo "ERROR: верификация: порт не совпадает (ожидался $INBOUND_LISTEN_PORT)" >&2
    exit 1
fi

echo "[inbound] ✓ Inbound создан: id=$INBOUND_ID, tag=$INBOUND_TAG, первый клиент uuid=$CLIENT_UUID" >&2

# Перезапуск Xray
api_restart_xray >&2

# Возвращаем JSON для caller
jq -nc \
    --argjson inbound_id "$INBOUND_ID" \
    --arg uuid "$CLIENT_UUID" \
    --arg tag "$INBOUND_TAG" \
    --arg public_key "${PUBLIC_KEY:-}" \
    --arg short_id "${SHORT_ID:-}" \
    --arg sni "${REALITY_DEST:-}" \
    --arg flow "$INBOUND_FLOW" \
    '{
        inbound_id: $inbound_id,
        first_client_uuid: $uuid,
        tag: $tag,
        public_key: $public_key,
        short_id: $short_id,
        sni: $sni,
        flow: $flow
    }'

api_logout >&2
exit 0
