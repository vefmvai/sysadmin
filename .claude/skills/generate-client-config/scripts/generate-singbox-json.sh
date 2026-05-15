#!/bin/bash
# generate-singbox-json.sh — собрать sing-box JSON-конфиг под платформу
# и vless://-link сервера.
#
# Стратегия совместимости (см. client-apps.md §9.3):
#   PLATFORM=ios     → sing-box 1.11.x (без AnyTLS, TLS-fragment, evaluate)
#   PLATFORM=android → sing-box 1.12.x
#   PLATFORM=desktop → sing-box 1.13.x
#   PLATFORM=universal (default) → sing-box 1.11.x — везде работает
#
# Вход через ENV:
#   VLESS_URL    — vless://-URI клиента (от generate-vless-link.sh)
#   PLATFORM     — ios | android | desktop | universal (default: universal)
#   PROFILE_NAME — название профиля (default: TAG из vless://)
#   USE_RULE_SET — yes | no (default: yes) — добавить ли geosite-ru → direct routing
#
# Выход (на stdout): sing-box JSON.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VLESS_URL="${VLESS_URL:?VLESS_URL обязателен}"
PLATFORM="${PLATFORM:-universal}"
PROFILE_NAME="${PROFILE_NAME:-vpn}"
USE_RULE_SET="${USE_RULE_SET:-yes}"

# Парсим vless://-link через соседний скилл
PARSE_VLESS="${SCRIPT_DIR}/../../configure-vpn-routing/scripts/parse-vless-link.sh"
if [ ! -x "$PARSE_VLESS" ]; then
    echo "ERROR: не найден parse-vless-link.sh: $PARSE_VLESS" >&2
    exit 1
fi

VLESS_JSON="$("$PARSE_VLESS" "$VLESS_URL")"

UUID="$(echo "$VLESS_JSON" | jq -r '.uuid')"
HOST="$(echo "$VLESS_JSON" | jq -r '.host')"
PORT="$(echo "$VLESS_JSON" | jq -r '.port')"
TAG="$(echo "$VLESS_JSON" | jq -r '.tag // empty')"
SECURITY="$(echo "$VLESS_JSON" | jq -r '.security')"
SNI="$(echo "$VLESS_JSON" | jq -r '.sni // empty')"
FP="$(echo "$VLESS_JSON" | jq -r '.fp // "chrome"')"
PBK="$(echo "$VLESS_JSON" | jq -r '.pbk // empty')"
SID="$(echo "$VLESS_JSON" | jq -r '.sid // empty')"
# SPX (spider-x path) — поле клиента Reality, но в sing-box-JSON оно не выносится
# отдельно (это серверная характеристика, клиенту достаточно publicKey + shortId).
FLOW="$(echo "$VLESS_JSON" | jq -r '.flow // empty')"

[ -z "$TAG" ] && TAG="$PROFILE_NAME"

# Outbound объект
OUTBOUND_BASE="$(jq -nc \
    --arg tag "vless-out" \
    --arg host "$HOST" \
    --argjson port "$PORT" \
    --arg uuid "$UUID" \
    --arg flow "$FLOW" \
    '{
        type: "vless",
        tag: $tag,
        server: $host,
        server_port: $port,
        uuid: $uuid,
        flow: $flow,
        network: "tcp"
    }')"

# TLS / Reality
if [ "$SECURITY" = "reality" ]; then
    TLS_BLOCK="$(jq -nc \
        --arg sni "$SNI" \
        --arg fp "$FP" \
        --arg pbk "$PBK" \
        --arg sid "$SID" \
        '{
            enabled: true,
            server_name: $sni,
            utls: { enabled: true, fingerprint: $fp },
            reality: { enabled: true, public_key: $pbk, short_id: $sid }
        }')"
    OUTBOUND="$(echo "$OUTBOUND_BASE" | jq --argjson tls "$TLS_BLOCK" '. + {tls: $tls}')"
elif [ "$SECURITY" = "tls" ]; then
    TLS_BLOCK="$(jq -nc \
        --arg sni "$SNI" \
        --arg fp "$FP" \
        '{
            enabled: true,
            server_name: $sni,
            utls: { enabled: true, fingerprint: $fp }
        }')"
    OUTBOUND="$(echo "$OUTBOUND_BASE" | jq --argjson tls "$TLS_BLOCK" '. + {tls: $tls}')"
else
    OUTBOUND="$OUTBOUND_BASE"
fi

# Inbounds под платформу
case "$PLATFORM" in
    ios)
        INBOUND="$(jq -nc '{
            type: "tun",
            tag: "tun-in",
            inet4_address: "172.19.0.1/30",
            inet6_address: "fdfe:dcba:9876::1/126",
            auto_route: true,
            stack: "system"
        }')"
        ;;
    android)
        INBOUND="$(jq -nc '{
            type: "tun",
            tag: "tun-in",
            inet4_address: "172.19.0.1/30",
            inet6_address: "fdfe:dcba:9876::1/126",
            auto_route: true,
            stack: "system"
        }')"
        ;;
    desktop)
        INBOUND="$(jq -nc '{
            type: "tun",
            tag: "tun-in",
            address: ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
            auto_route: true,
            auto_redirect: true,
            strict_route: true,
            stack: "mixed",
            mtu: 1500
        }')"
        ;;
    universal | *)
        # Универсальный — mixed inbound на 127.0.0.1, без TUN.
        # Работает на десктопе и в каждом приложении, которое принимает sing-box JSON
        # (Hiddify-app сам обернёт в TUN при включении VPN).
        INBOUND="$(jq -nc '{
            type: "mixed",
            tag: "mixed-in",
            listen: "127.0.0.1",
            listen_port: 2080
        }')"
        ;;
esac

# Routing rules
if [ "$USE_RULE_SET" = "yes" ]; then
    ROUTE_RULE_SETS="$(jq -nc '[
        {
            type: "remote",
            tag: "geoip-ru",
            format: "binary",
            url: "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs",
            update_interval: "1d"
        },
        {
            type: "remote",
            tag: "geosite-category-ru",
            format: "binary",
            url: "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ru.srs",
            update_interval: "1d"
        }
    ]')"

    ROUTE_RULES="$(jq -nc '[
        {
            rule_set: ["geoip-ru", "geosite-category-ru"],
            outbound: "direct-out"
        },
        {
            ip_is_private: true,
            outbound: "direct-out"
        }
    ]')"

    ROUTING_BLOCK="$(jq -nc \
        --argjson rule_sets "$ROUTE_RULE_SETS" \
        --argjson rules "$ROUTE_RULES" \
        '{
            rule_set: $rule_sets,
            rules: $rules,
            final: "vless-out",
            auto_detect_interface: true
        }')"
else
    ROUTING_BLOCK="$(jq -nc '{final: "vless-out", auto_detect_interface: true}')"
fi

# Финальный JSON
FINAL="$(jq -nc \
    --argjson inbound "$INBOUND" \
    --argjson outbound "$OUTBOUND" \
    --argjson routing "$ROUTING_BLOCK" \
    '{
        log: { level: "info", timestamp: true },
        inbounds: [$inbound],
        outbounds: [
            $outbound,
            { type: "direct", tag: "direct-out" }
        ],
        route: $routing
    }')"

# Pretty-print через jq
echo "$FINAL" | jq '.'

exit 0
