#!/bin/bash
# 04-add-proxy-routing.sh — добавить routing rules для mixed inbound по модели
# «золотая середина» (см. эталон 16-ЭТАЛОН-гибкой-маршрутизации-3xui.md §2.5/§3.2).
#
# Все правила scoped на inboundTag=mixed-server-proxy (не трогают vless-inbound),
# порядок сверху вниз — первое совпавшее применяется:
#   1. private               → direct   (локальная сеть; НЕ blocked)
#   2. bittorrent            → blocked
#   3. category-ads-all      → blocked  (реклама)
#   4. geoip:ru              → direct    (топ-РФ-сервисы по IP)
#   5. category-ru + regex   → direct    (.ru/.su/.рф)
#   6. default (этот inbound)→ upstream balancer (или один outbound)
#
# Особенность: НЕ заменяет существующие vless-inbound routing rules,
# а ДОБАВЛЯЕТ новые (idempotent через tag matching — удаляет старые правила
# с этим inboundTag перед вставкой).
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

# Убедимся, что есть outbound "blocked" (blackhole) — нужен для правил
# реклама → blocked и bittorrent → blocked.
HAS_BLOCKED="$(echo "$CURRENT_CONFIG" | jq '[.outbounds[]? | select(.tag == "blocked")] | length')"
if [ "$HAS_BLOCKED" -eq 0 ]; then
    BLOCKED_OUTBOUND='{"tag":"blocked","protocol":"blackhole","settings":{}}'
    CURRENT_CONFIG="$(echo "$CURRENT_CONFIG" | jq --argjson o "$BLOCKED_OUTBOUND" '.outbounds = ((.outbounds // []) + [$o])')"
fi

# Определяем, balancer или outbound по имени upstream
HAS_BALANCER="$(echo "$CURRENT_CONFIG" | jq --arg t "$UPSTREAM_REF" '[.routing.balancers[]? | select(.tag == $t)] | length')"
UPSTREAM_FIELD="outboundTag"
if [ "$HAS_BALANCER" -gt 0 ]; then
    UPSTREAM_FIELD="balancerTag"
fi

# Готовим полный блок правил «золотая середина», все scoped на inboundTag=mixed.
# Правила 1..5 — общие; правило 6 (default) — на upstream (balancer или outbound).
# Примечание про .рф: Xray regexp по punycode → .+\.xn--p1ai$.
# Два бэкслеша в jq-источнике дают JSON \\. и рантайм-regex \. (литеральная точка).
PROXY_RULES="$(jq -nc \
    --arg in "$MIXED_INBOUND_TAG" \
    --arg field "$UPSTREAM_FIELD" \
    --arg upstream "$UPSTREAM_REF" \
    '[
        {
            type: "field",
            inboundTag: [$in],
            ip: ["geoip:private"],
            outboundTag: "direct"
        },
        {
            type: "field",
            inboundTag: [$in],
            protocol: ["bittorrent"],
            outboundTag: "blocked"
        },
        {
            type: "field",
            inboundTag: [$in],
            domain: ["geosite:category-ads-all"],
            outboundTag: "blocked"
        },
        {
            type: "field",
            inboundTag: [$in],
            ip: ["geoip:ru"],
            outboundTag: "direct"
        },
        {
            type: "field",
            inboundTag: [$in],
            domain: [
                "geosite:category-ru",
                "regexp:.+\\.ru$",
                "regexp:.+\\.su$",
                "regexp:.+\\.xn--p1ai$"
            ],
            outboundTag: "direct"
        },
        ({
            type: "field",
            inboundTag: [$in]
        } + ({} | .[$field] = $upstream))
    ]')"

# Удаляем существующие правила с этим inboundTag (idempotency), затем вставляем
# полный блок В НАЧАЛО routing.rules. Все правила scoped на mixed-inbound, поэтому
# vless-трафика они не касаются; позиция в начале гарантирует корректный порядок
# (private → ads → ru → default) для серверного прокси независимо от vless-правил.
NEW_CONFIG="$(echo "$CURRENT_CONFIG" | jq \
    --arg in "$MIXED_INBOUND_TAG" \
    --argjson proxyrules "$PROXY_RULES" \
    '
    .routing = (.routing // {})
    | .routing.domainStrategy = (.routing.domainStrategy // "IPIfNonMatch")
    | .routing.rules = ((.routing.rules // []) | map(select((.inboundTag // []) | index($in) | not)))
    | .routing.rules = ($proxyrules + .routing.rules)
    ')"

echo "[proxy-routing] Применяю routing: $MIXED_INBOUND_TAG → ($UPSTREAM_FIELD=$UPSTREAM_REF)" >&2
api_update_xray_config "$NEW_CONFIG" >&2

api_restart_xray >&2

echo "[proxy-routing] ✓ Routing для server-proxy добавлен (6 правил, модель «золотая середина»)" >&2

jq -nc \
    --arg in "$MIXED_INBOUND_TAG" \
    --arg field "$UPSTREAM_FIELD" \
    --arg upstream "$UPSTREAM_REF" \
    '{inbound: $in, upstream_kind: $field, upstream: $upstream, rules_count: 6,
      model: "golden-middle scoped to mixed-inbound (private→direct, bittorrent→block, ads→block, geoip:ru→direct, category-ru+regex→direct, default→upstream)"}'

api_logout >&2
exit 0
