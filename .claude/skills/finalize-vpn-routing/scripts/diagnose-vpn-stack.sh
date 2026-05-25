#!/bin/bash
# diagnose-vpn-stack.sh — READ-ONLY снимок состояния VPN-стека в панели 3X-UI.
#
# Снимает фактическое состояние и сверяет с эталоном «как должно быть», выдаёт
# структурированный чеклист для скилла-дирижёра /finalize-vpn-routing. Ничего НЕ
# меняет на сервере (Green Zone).
#
# Проверяет:
#   1. inbound для клиентов (VLESS — вход устройств)
#   2. outbound выхода (upstream-*) + сколько, + есть ли balancer + observatory
#   3. routing rules: есть ли модель «золотая середина» (РФ→direct, реклама→block,
#      default→upstream) для клиентского inbound
#   4. локальный прокси: mixed inbound на 127.0.0.1
#   5. routing для mixed-inbound (прокси-правила)
#
# Вход через ENV:
#   PANEL_DOMAIN, PANEL_PORT, WEB_BASE_PATH, ADMIN_LOGIN, PASSWORD_REF
#
# Выход (stdout): JSON-диагноз. Каждый пункт: present(bool) + детали.
#   Человеко-читаемая сводка — в stderr.
# Коды возврата:
#   0 — диагноз снят (даже если дыры есть — это нормальный результат)
#   1 — не удалось снять (панель недоступна / логин не прошёл)

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

api_login \
    --domain "$PANEL_DOMAIN" \
    --port "$PANEL_PORT" \
    --web-path "$WEB_BASE_PATH" \
    --admin "$ADMIN_LOGIN" \
    --password-ref "$PASSWORD_REF" || {
    echo "ERROR: логин в панель не прошёл — проверь креды/доступность" >&2
    exit 1
}

INBOUNDS="$(api_list_inbounds | jq '.obj // []')"
XRAY="$(api_get_xray_config | jq '.obj // {}')"

# --- 1. Клиентский inbound (VLESS — вход устройств) -------------------------
VLESS_INBOUNDS="$(echo "$INBOUNDS" | jq '[.[] | select(.protocol == "vless")]')"
VLESS_COUNT="$(echo "$VLESS_INBOUNDS" | jq 'length')"
# Сколько клиентов суммарно (UUID в settings)
CLIENT_COUNT="$(echo "$VLESS_INBOUNDS" | jq '[.[] | (.settings | fromjson? | .clients // []) | length] | add // 0')"

# --- 2. Outbound выхода + balancer + observatory ----------------------------
UPSTREAM_OUTBOUNDS="$(echo "$XRAY" | jq '[.outbounds[]? | select(.tag | test("^upstream"))]')"
UPSTREAM_COUNT="$(echo "$UPSTREAM_OUTBOUNDS" | jq 'length')"
HAS_BALANCER="$(echo "$XRAY" | jq '((.routing.balancers // []) | length) > 0')"
BALANCER_STRATEGY="$(echo "$XRAY" | jq -r '.routing.balancers[0].strategy.type // "none"')"
HAS_OBSERVATORY="$(echo "$XRAY" | jq '((.observatory // null) != null) or ((.burstObservatory // null) != null)')"
PROBE_INTERVAL="$(echo "$XRAY" | jq -r '.observatory.probeInterval // "none"')"

# --- 3. Routing «золотая середина» для клиентского трафика ------------------
# ВАЖНО: теги/значения ниже (direct, blocked, geoip:ru, geosite:category-ads-all)
# должны совпадать с тем, что пишет ../configure-vpn-routing/scripts/setup-routing.sh.
# Если там изменится модель «золотая середина» — синхронизировать здесь (иначе
# диагноз даст ложный ❌ на корректно настроенной панели).
RULES="$(echo "$XRAY" | jq '.routing.rules // []')"
HAS_RU_DIRECT="$(echo "$RULES" | jq '[.[] | select((.outboundTag == "direct") and ((.ip // []) | index("geoip:ru")))] | length > 0')"
HAS_ADS_BLOCK="$(echo "$RULES" | jq '[.[] | select((.outboundTag == "blocked") and ((.domain // []) | index("geosite:category-ads-all")))] | length > 0')"
HAS_DEFAULT_UPSTREAM="$(echo "$RULES" | jq '[.[] | select((.balancerTag != null) or ((.outboundTag // "") | test("^upstream")))] | length > 0')"
RULES_COUNT="$(echo "$RULES" | jq 'length')"

# --- 4. Локальный прокси: mixed inbound на 127.0.0.1 ------------------------
MIXED_INBOUND="$(echo "$INBOUNDS" | jq --arg p "$PROXY_PORT" '[.[] | select(.protocol == "mixed" and ((.port | tostring) == $p))]')"
HAS_PROXY="$(echo "$MIXED_INBOUND" | jq 'length > 0')"
PROXY_LISTEN="$(echo "$MIXED_INBOUND" | jq -r '.[0].listen // "none"')"
PROXY_TAG="$(echo "$MIXED_INBOUND" | jq -r '.[0].tag // "none"')"

# --- 5. Routing для mixed-inbound (прокси-правила) --------------------------
HAS_PROXY_ROUTING="$(echo "$RULES" | jq --arg tag "$PROXY_TAG" '[.[] | select((.inboundTag // []) | index($tag))] | length > 0')"

# --- Сборка диагноза --------------------------------------------------------
DIAGNOSIS="$(jq -nc \
    --argjson vless_count "$VLESS_COUNT" \
    --argjson client_count "$CLIENT_COUNT" \
    --argjson upstream_count "$UPSTREAM_COUNT" \
    --argjson has_balancer "$HAS_BALANCER" \
    --arg balancer_strategy "$BALANCER_STRATEGY" \
    --argjson has_observatory "$HAS_OBSERVATORY" \
    --arg probe_interval "$PROBE_INTERVAL" \
    --argjson has_ru_direct "$HAS_RU_DIRECT" \
    --argjson has_ads_block "$HAS_ADS_BLOCK" \
    --argjson has_default_upstream "$HAS_DEFAULT_UPSTREAM" \
    --argjson rules_count "$RULES_COUNT" \
    --argjson has_proxy "$HAS_PROXY" \
    --arg proxy_listen "$PROXY_LISTEN" \
    --argjson has_proxy_routing "$HAS_PROXY_ROUTING" \
    '{
        client_inbound:  { present: ($vless_count > 0), vless_inbounds: $vless_count, clients: $client_count },
        exit_outbound:   { present: ($upstream_count > 0), count: $upstream_count,
                           balancer: $has_balancer, strategy: $balancer_strategy,
                           observatory: $has_observatory, probe_interval: $probe_interval },
        routing:         { golden_middle: ($has_ru_direct and $has_ads_block and $has_default_upstream),
                           ru_direct: $has_ru_direct, ads_block: $has_ads_block,
                           default_to_upstream: $has_default_upstream, rules_count: $rules_count },
        local_proxy:     { present: $has_proxy, listen: $proxy_listen, routing_present: $has_proxy_routing }
    }')"

# Человеко-читаемая сводка → stderr
{
    echo "═══ ДИАГНОЗ VPN-СТЕКА ═══"
    chk() { [ "$1" = "true" ] && echo "  ✅ $2" || echo "  ❌ $2"; }
    chk "$([ "$VLESS_COUNT" -gt 0 ] && echo true || echo false)" "Вход для устройств (VLESS inbound): $VLESS_COUNT inbound, $CLIENT_COUNT клиентов"
    chk "$([ "$UPSTREAM_COUNT" -gt 0 ] && echo true || echo false)" "Выход (upstream outbound): $UPSTREAM_COUNT шт."
    chk "$HAS_BALANCER" "Балансировщик: $BALANCER_STRATEGY (probeInterval=$PROBE_INTERVAL)"
    chk "$([ "$HAS_RU_DIRECT" = "true" ] && [ "$HAS_ADS_BLOCK" = "true" ] && [ "$HAS_DEFAULT_UPSTREAM" = "true" ] && echo true || echo false)" "Гибкая маршрутизация «золотая середина» ($RULES_COUNT правил)"
    chk "$HAS_PROXY" "Локальный прокси для программ (mixed на 127.0.0.1:$PROXY_PORT)"
    chk "$HAS_PROXY_ROUTING" "Маршрутизация локального прокси"
    echo "═════════════════════════"
} >&2

echo "$DIAGNOSIS"

api_logout >&2
exit 0
