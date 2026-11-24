#!/bin/bash
# parse-hysteria2-link.sh — разбор hysteria2:// (или hy2://) ссылки в JSON.
#
# Зачем отдельно от parse-vless-link.sh: Hysteria2 — другой протокол (QUIC/UDP),
# у него пароль вместо UUID и свой набор параметров. Подписки «под ключ» всё
# чаще кладут такие серверы рядом с VLESS (Quattro, 2026-09: 12 из 337).
# Раньше они молча пропадали из результата.
#
# Формат URI:
#   hysteria2://<PASSWORD>@<HOST>:<PORT>/?<QUERY>#<TAG>
#   hy2://...   — короткий синоним
#
# Query-параметры: sni, insecure (0/1), alpn, obfs, obfs-password, pinSHA256.
#
# Использование:
#   ./parse-hysteria2-link.sh 'hysteria2://pass@host:443?sni=...#name'
#
# Выход (stdout): JSON
#   { "protocol": "hysteria2", "password": "...", "host": "...", "port": N,
#     "tag": "...", "security": "tls", "type": "udp", "sni": "...",
#     "alpn": "...", "insecure": "...", "obfs": "...", "obfs_password": "...",
#     "pin_sha256": "..." }

set -euo pipefail

if [ "$#" -ge 1 ]; then
    URL="$1"
else
    URL="$(cat)"
fi
URL="$(printf '%s' "$URL" | tr -d '[:space:]')"

case "$URL" in
    hysteria2://*) BODY="${URL#hysteria2://}" ;;
    hy2://*)       BODY="${URL#hy2://}" ;;
    *) echo "ERROR: ссылка должна начинаться с 'hysteria2://' или 'hy2://'" >&2; exit 1 ;;
esac

# Тег (#fragment), URL-decode
TAG=""
if [[ "$BODY" == *"#"* ]]; then
    TAG_ENCODED="${BODY##*#}"
    BODY="${BODY%#*}"
    TAG="$(printf '%b' "${TAG_ENCODED//%/\\x}")"
fi

# Query. '?' в parameter expansion — glob, экранируем (см. parse-vless-link.sh).
QUERY=""
if [[ "$BODY" == *"?"* ]]; then
    QUERY="${BODY#*\?}"
    BODY="${BODY%%\?*}"
fi
BODY="${BODY%/}"                    # хвостовой слэш перед '?'

if [[ "$BODY" != *"@"* ]]; then
    echo "ERROR: нет @ (формат hysteria2://PASSWORD@HOST:PORT)" >&2
    exit 1
fi
# Пароль может содержать '@' — адрес берём после ПОСЛЕДНЕГО '@'.
PASSWORD="${BODY%@*}"
PASSWORD="$(printf '%b' "${PASSWORD//%/\\x}")"
HOSTPORT="${BODY##*@}"

if [[ "$HOSTPORT" =~ ^\[(.*)\]:([0-9]+)$ ]] || [[ "$HOSTPORT" =~ ^([^:]+):([0-9]+)$ ]]; then
    HOST="${BASH_REMATCH[1]}"
    PORT="${BASH_REMATCH[2]}"
else
    echo "ERROR: невалидный host:port в '$HOSTPORT'" >&2
    exit 1
fi

extract_qparam() {
    local pattern="(^|&)${1}=([^&]*)"
    if [[ "$QUERY" =~ $pattern ]]; then
        local raw="${BASH_REMATCH[2]}"
        printf '%b' "${raw//%/\\x}"
    else
        printf '%s' "${2:-}"
    fi
}

# Секреты провайдера (base64-подобные) могут начинаться с «/» — под Git Bash нативный jq
# получил бы их переписанными. Локальных путей в вызове нет. msys-path-conversion.md
MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' jq -n \
    --arg password "$PASSWORD" \
    --arg host "$HOST" \
    --arg port "$PORT" \
    --arg tag "$TAG" \
    --arg sni "$(extract_qparam sni)" \
    --arg alpn "$(extract_qparam alpn)" \
    --arg insecure "$(extract_qparam insecure 0)" \
    --arg obfs "$(extract_qparam obfs)" \
    --arg obfs_password "$(extract_qparam obfs-password)" \
    --arg pin "$(extract_qparam pinSHA256)" \
    '{
        protocol: "hysteria2",
        password: $password,
        host: $host,
        port: ($port | tonumber),
        tag: $tag,
        security: "tls",
        type: "udp",
        sni: $sni,
        alpn: $alpn,
        insecure: $insecure,
        obfs: $obfs,
        obfs_password: $obfs_password,
        pin_sha256: $pin
    }'
