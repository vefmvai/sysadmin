#!/bin/bash
# setup-routing.sh — настроить routing rules в xray-конфиге:
#  - Правило 1: РФ-трафик (geosite:category-ru + geoip:ru) → direct.
#  - Правило 2: остальное → upstream (balancer или один outbound).
#  - Опционально: balancer объединяет несколько upstream outbound-ов.
#  - Опционально: observatory для leastPing-балансировки.
#
# Вход через ENV:
#   PANEL_DOMAIN, PANEL_PORT, WEB_BASE_PATH, ADMIN_LOGIN, PASSWORD_REF
#   UPSTREAM_TAGS_JSON  — JSON-массив тегов outbound-ов: ["upstream-de", "upstream-nl"]
#   BALANCER_STRATEGY   — random | roundRobin | leastPing | leastLoad (default: leastPing)
#   USE_BALANCER        — yes | no (default: auto — yes если UPSTREAM_TAGS > 1)
#   INBOUND_TAGS_JSON   — JSON-массив тегов inbound-ов, к которым применяется
#                         маршрутизация (default: все vless inbound из getInbounds)
#
# Выход (на stdout): JSON с описанием применённой схемы.

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
UPSTREAM_TAGS_JSON="${UPSTREAM_TAGS_JSON:?UPSTREAM_TAGS_JSON обязателен (например, [\"upstream-de\"])}"
BALANCER_STRATEGY="${BALANCER_STRATEGY:-leastPing}"

# Парсим массив upstream-тегов
UPSTREAM_COUNT="$(echo "$UPSTREAM_TAGS_JSON" | jq 'length')"
if [ "$UPSTREAM_COUNT" -lt 1 ]; then
    echo "ERROR: UPSTREAM_TAGS_JSON пустой" >&2
    exit 2
fi

# Auto-balancer: yes если >1 upstream
USE_BALANCER="${USE_BALANCER:-auto}"
if [ "$USE_BALANCER" = "auto" ]; then
    if [ "$UPSTREAM_COUNT" -gt 1 ]; then
        USE_BALANCER="yes"
    else
        USE_BALANCER="no"
    fi
fi

api_login \
    --domain "$PANEL_DOMAIN" \
    --port "$PANEL_PORT" \
    --web-path "$WEB_BASE_PATH" \
    --admin "$ADMIN_LOGIN" \
    --password-ref "$PASSWORD_REF"

# Текущий конфиг
CURRENT_CONFIG="$(api_call GET "/panel/api/inbounds/getXrayConfig" | jq '.obj')"

# Определяем INBOUND_TAGS — все vless inbounds, если не передано
if [ -z "${INBOUND_TAGS_JSON:-}" ]; then
    INBOUND_TAGS_JSON="$(api_call GET "/panel/api/inbounds/list" \
        | jq '[.obj[] | select(.protocol == "vless" or .protocol == "mixed") | .tag]')"
fi

# Убедимся, что direct outbound есть
HAS_DIRECT="$(echo "$CURRENT_CONFIG" | jq '[.outbounds[]? | select(.tag == "direct")] | length')"
if [ "$HAS_DIRECT" -eq 0 ]; then
    DIRECT_OUTBOUND='{"tag":"direct","protocol":"freedom","settings":{}}'
    CURRENT_CONFIG="$(echo "$CURRENT_CONFIG" | jq --argjson o "$DIRECT_OUTBOUND" '.outbounds = ((.outbounds // []) + [$o])')"
fi

# Формируем routing rules и опционально balancer
if [ "$USE_BALANCER" = "yes" ]; then
    # Balancer
    BALANCER_OBJ="$(jq -nc \
        --argjson selector "$UPSTREAM_TAGS_JSON" \
        --arg strategy "$BALANCER_STRATEGY" \
        '{
            tag: "upstream-balancer",
            selector: $selector,
            strategy: { type: $strategy },
            fallbackTag: "direct"
        }')"

    # Observatory (нужен для leastPing/leastLoad)
    if [ "$BALANCER_STRATEGY" = "leastPing" ] || [ "$BALANCER_STRATEGY" = "leastLoad" ]; then
        OBSERVATORY_OBJ="$(jq -nc \
            --argjson selector "$UPSTREAM_TAGS_JSON" \
            '{
                subjectSelector: $selector,
                probeUrl: "http://www.google.com/gen_204",
                probeInterval: "30s"
            }')"
    else
        OBSERVATORY_OBJ="null"
    fi

    # Rules
    ROUTE_RULES="$(jq -nc \
        --argjson inbounds "$INBOUND_TAGS_JSON" \
        '[
            {
                type: "field",
                outboundTag: "direct",
                domain: ["geosite:category-ru", "regexp:.*\\\\.ru$"],
                ip: ["geoip:ru", "geoip:private"]
            },
            {
                type: "field",
                inboundTag: $inbounds,
                balancerTag: "upstream-balancer"
            }
        ]')"

    NEW_CONFIG="$(echo "$CURRENT_CONFIG" | jq \
        --argjson balancer "$BALANCER_OBJ" \
        --argjson observatory "$OBSERVATORY_OBJ" \
        --argjson rules "$ROUTE_RULES" \
        '
        .routing = {
            domainStrategy: "IPIfNonMatch",
            balancers: [$balancer],
            rules: $rules
        }
        | if $observatory != null then .observatory = $observatory else . end
        ')"
else
    # Один upstream — direct routing без balancer
    SINGLE_UPSTREAM="$(echo "$UPSTREAM_TAGS_JSON" | jq -r '.[0]')"

    ROUTE_RULES="$(jq -nc \
        --argjson inbounds "$INBOUND_TAGS_JSON" \
        --arg upstream "$SINGLE_UPSTREAM" \
        '[
            {
                type: "field",
                outboundTag: "direct",
                domain: ["geosite:category-ru", "regexp:.*\\\\.ru$"],
                ip: ["geoip:ru", "geoip:private"]
            },
            {
                type: "field",
                inboundTag: $inbounds,
                outboundTag: $upstream
            }
        ]')"

    NEW_CONFIG="$(echo "$CURRENT_CONFIG" | jq \
        --argjson rules "$ROUTE_RULES" \
        '.routing = {
            domainStrategy: "IPIfNonMatch",
            rules: $rules
        }')"
fi

# Обновляем конфиг
echo "[routing] Применяю routing: balancer=$USE_BALANCER, upstream_count=$UPSTREAM_COUNT, strategy=$BALANCER_STRATEGY" >&2
api_update_xray_config "$NEW_CONFIG" >&2

api_restart_xray >&2

echo "[routing] ✓ Routing применён" >&2

# Финальный отчёт
jq -nc \
    --arg use_balancer "$USE_BALANCER" \
    --arg strategy "$BALANCER_STRATEGY" \
    --argjson upstream_tags "$UPSTREAM_TAGS_JSON" \
    --argjson inbound_tags "$INBOUND_TAGS_JSON" \
    '{
        use_balancer: $use_balancer,
        strategy: $strategy,
        upstream_tags: $upstream_tags,
        inbound_tags: $inbound_tags,
        rules_count: 2
    }'

api_logout >&2
exit 0
