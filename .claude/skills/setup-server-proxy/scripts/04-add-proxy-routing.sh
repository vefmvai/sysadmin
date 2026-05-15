#!/bin/bash
# 04-add-proxy-routing.sh — добавить routing rules для mixed inbound:
#  - inbound mixed-server-proxy + geoip:ru/geosite:category-ru → direct
#  - inbound mixed-server-proxy → upstream balancer (или один outbound)
#
# Особенность: НЕ заменяет существующие vless-inbound routing rules,
# а ДОБАВЛЯЕТ новые (idempotent через tag matching).
#
# Вход через ENV:
#   PANEL_DOMAIN, PANEL_PORT, WEB_BASE_PATH, ADMIN_LOGIN, PASSWORD_REF
#   MIXED_INBOUND_TAG  — обычно "mixed-server-proxy" (из 02-create-mixed-inbound.sh)
#   UPSTREAM_REF       — тег outbound ИЛИ balancer (например, "upstream-balancer" или "upstream-de")

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
MIXED_INBOUND_TAG="${MIXED_INBOUND_TAG:-mixed-server-proxy}"
UPSTREAM_REF="${UPSTREAM_REF:?UPSTREAM_REF обязателен (тег outbound или balancer)}"

api_login \
    --domain "$PANEL_DOMAIN" \
    --port "$PANEL_PORT" \
    --web-path "$WEB_BASE_PATH" \
    --admin "$ADMIN_LOGIN" \
    --password-ref "$PASSWORD_REF"

# Текущий конфиг
CURRENT_CONFIG="$(api_call GET "/panel/api/inbounds/getXrayConfig" | jq '.obj')"

# Определяем, balancer или outbound по имени upstream
HAS_BALANCER="$(echo "$CURRENT_CONFIG" | jq --arg t "$UPSTREAM_REF" '[.routing.balancers[]? | select(.tag == $t)] | length')"
UPSTREAM_FIELD="outboundTag"
if [ "$HAS_BALANCER" -gt 0 ]; then
    UPSTREAM_FIELD="balancerTag"
fi

# Готовим два новых правила (с inboundTag=mixed-server-proxy)
NEW_RULE_DIRECT="$(jq -nc --arg in "$MIXED_INBOUND_TAG" '{
    type: "field",
    inboundTag: [$in],
    outboundTag: "direct",
    domain: ["geosite:category-ru", "regexp:.*\\\\.ru$"],
    ip: ["geoip:ru", "geoip:private"]
}')"

NEW_RULE_UPSTREAM="$(jq -nc \
    --arg in "$MIXED_INBOUND_TAG" \
    --arg field "$UPSTREAM_FIELD" \
    --arg upstream "$UPSTREAM_REF" \
    '{
        type: "field",
        inboundTag: [$in]
    } + ({} | .[$field] = $upstream)')"

# Удаляем существующие правила с этим inboundTag (idempotency),
# затем добавляем оба новых
NEW_CONFIG="$(echo "$CURRENT_CONFIG" | jq \
    --arg in "$MIXED_INBOUND_TAG" \
    --argjson rule1 "$NEW_RULE_DIRECT" \
    --argjson rule2 "$NEW_RULE_UPSTREAM" \
    '
    .routing = (.routing // {})
    | .routing.rules = ((.routing.rules // []) | map(select((.inboundTag // []) | index($in) | not)))
    | .routing.rules = (.routing.rules + [$rule1, $rule2])
    ')"

echo "[proxy-routing] Применяю routing: $MIXED_INBOUND_TAG → ($UPSTREAM_FIELD=$UPSTREAM_REF)" >&2
api_update_xray_config "$NEW_CONFIG" >&2

api_restart_xray >&2

echo "[proxy-routing] ✓ Routing для server-proxy добавлен" >&2

jq -nc \
    --arg in "$MIXED_INBOUND_TAG" \
    --arg field "$UPSTREAM_FIELD" \
    --arg upstream "$UPSTREAM_REF" \
    '{inbound: $in, upstream_kind: $field, upstream: $upstream}'

api_logout >&2
exit 0
