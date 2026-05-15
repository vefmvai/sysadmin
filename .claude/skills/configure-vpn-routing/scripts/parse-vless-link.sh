#!/bin/bash
# parse-vless-link.sh — разбор vless://-URI на компоненты для создания outbound в 3X-UI.
#
# Формат URI (по спецификации Xray VLESS share-link):
#   vless://<UUID>@<HOST>:<PORT>?<QUERY>#<TAG>
#
# Query-параметры (наиболее частые):
#   type      — transport (tcp, ws, grpc, http, h2)
#   security  — none, tls, reality
#   sni       — server name indication
#   alpn      — h2,http/1.1 (comma-separated)
#   fp        — fingerprint TLS (chrome, firefox, safari, ios, android, ...)
#   pbk       — Reality public key (X25519)
#   sid       — Reality short id
#   spx       — Reality spider-x (path)
#   flow      — xtls-rprx-vision (или пусто)
#   path      — для ws/h2/http transport
#   host      — для ws/h2/http (HTTP Host header)
#   serviceName — для gRPC
#
# Использование:
#   echo 'vless://uuid@host:443?security=reality&...' | ./parse-vless-link.sh
#   ./parse-vless-link.sh 'vless://...'
#
# Выход (на stdout): JSON с разобранными полями.
#   { "uuid": "...", "host": "...", "port": "...", "tag": "...",
#     "security": "...", "type": "...", "sni": "...", "fp": "...",
#     "pbk": "...", "sid": "...", "spx": "...", "flow": "...",
#     "path": "...", "host_header": "...", "alpn": "..." }
#
# Возвращаемый код:
#   0 — успешно разобрано
#   1 — невалидная ссылка
#   2 — ошибка параметров

set -euo pipefail

# Читаем ссылку из аргумента или stdin
if [ "$#" -ge 1 ]; then
    VLESS_URL="$1"
else
    VLESS_URL="$(cat)"
fi

# Триминг whitespace
VLESS_URL="$(echo "$VLESS_URL" | tr -d '[:space:]')"

if [ -z "$VLESS_URL" ]; then
    echo "ERROR: пустая ссылка" >&2
    exit 2
fi

if ! [[ "$VLESS_URL" =~ ^vless:// ]]; then
    echo "ERROR: ссылка должна начинаться с 'vless://': $VLESS_URL" >&2
    exit 1
fi

# Снимаем префикс
URL_BODY="${VLESS_URL#vless://}"

# Отделяем tag (#fragment)
if [[ "$URL_BODY" == *"#"* ]]; then
    TAG_ENCODED="${URL_BODY##*#}"
    URL_BODY="${URL_BODY%#*}"
    # URL-decode tag (заменяем %XX на байты)
    TAG="$(printf '%b' "${TAG_ENCODED//%/\\x}")"
else
    TAG=""
fi

# Отделяем query (?key=val&...).
# Внимание: '?' в parameter expansion — это glob-pattern (один любой символ),
# нельзя писать `#*?` — нужна экранировка `#*\?`.
if [[ "$URL_BODY" == *"?"* ]]; then
    QUERY="${URL_BODY#*\?}"
    URL_BODY="${URL_BODY%%\?*}"
else
    QUERY=""
fi

# Отделяем uuid@host:port
if [[ "$URL_BODY" == *"@"* ]]; then
    UUID="${URL_BODY%%@*}"
    HOSTPORT="${URL_BODY#*@}"
else
    echo "ERROR: нет @ в '$URL_BODY' (формат vless://UUID@HOST:PORT)" >&2
    exit 1
fi

# Разделяем host:port (учёт IPv6 в []:port)
if [[ "$HOSTPORT" =~ ^\[(.*)\]:([0-9]+)$ ]]; then
    HOST="${BASH_REMATCH[1]}"
    PORT="${BASH_REMATCH[2]}"
elif [[ "$HOSTPORT" =~ ^([^:]+):([0-9]+)$ ]]; then
    HOST="${BASH_REMATCH[1]}"
    PORT="${BASH_REMATCH[2]}"
else
    echo "ERROR: невалидный host:port в '$HOSTPORT'" >&2
    exit 1
fi

# Валидация UUID v4 (опционально — VLESS принимает любую строку <30 байт,
# но 99% случаев — UUID v4)
if ! [[ "$UUID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
    # Не fail, только warning в stderr — UUID может быть кастомным
    echo "WARN: UUID не похож на стандартный v4: $UUID" >&2
fi

# Парсинг query без assoc-array (для совместимости с bash 3.2 на macOS).
# extract_qparam <key> <default> — извлекает значение query-параметра.
extract_qparam() {
    local key="$1"
    local default="${2:-}"
    local pattern="(^|&)${key}=([^&]*)"
    if [[ "$QUERY" =~ $pattern ]]; then
        # URL-decode значение (заменяем %XX на байты)
        local raw="${BASH_REMATCH[2]}"
        printf '%b' "${raw//%/\\x}"
    else
        printf '%s' "$default"
    fi
}

SECURITY="$(extract_qparam security none)"
TRANSPORT_TYPE="$(extract_qparam type tcp)"
SNI="$(extract_qparam sni)"
FP="$(extract_qparam fp)"
ALPN="$(extract_qparam alpn)"
PBK="$(extract_qparam pbk)"
SID="$(extract_qparam sid)"
SPX="$(extract_qparam spx)"
FLOW="$(extract_qparam flow)"
PATH_PARAM="$(extract_qparam path)"
HOST_HEADER="$(extract_qparam host)"
SERVICE_NAME="$(extract_qparam serviceName)"

# Эмитим JSON через jq для корректной escape
jq -n \
    --arg uuid "$UUID" \
    --arg host "$HOST" \
    --arg port "$PORT" \
    --arg tag "$TAG" \
    --arg security "$SECURITY" \
    --arg type "$TRANSPORT_TYPE" \
    --arg sni "$SNI" \
    --arg fp "$FP" \
    --arg alpn "$ALPN" \
    --arg pbk "$PBK" \
    --arg sid "$SID" \
    --arg spx "$SPX" \
    --arg flow "$FLOW" \
    --arg path "$PATH_PARAM" \
    --arg host_header "$HOST_HEADER" \
    --arg service_name "$SERVICE_NAME" \
    '{
        uuid: $uuid,
        host: $host,
        port: ($port | tonumber),
        tag: $tag,
        security: $security,
        type: $type,
        sni: $sni,
        fp: $fp,
        alpn: $alpn,
        pbk: $pbk,
        sid: $sid,
        spx: $spx,
        flow: $flow,
        path: $path,
        host_header: $host_header,
        service_name: $service_name
    }'

exit 0
