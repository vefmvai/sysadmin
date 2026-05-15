#!/bin/bash
# parse-subscription.sh — скачать subscription URL и разобрать содержимое.
#
# Subscription URL — это HTTP(S)-endpoint, который возвращает один из форматов:
#  1. base64-encoded список vless://-ссылок (одна на строку).
#  2. Plain text список vless://-ссылок.
#  3. Sing-box JSON (если subscription отдаёт через User-Agent negotiation
#     для sing-box-клиентов) — НЕ обрабатывается этим скриптом, нужен
#     отдельный конвертер.
#  4. Clash YAML — НЕ обрабатывается этим скриптом.
#
# Скрипт извлекает только vless://-ссылки (см. parse-vless-link.sh для парсинга
# каждой).
#
# Использование:
#   SUBSCRIPTION_URL='https://sub.provider.com/abc123' ./parse-subscription.sh
#
# Выход (на stdout): JSON-массив объектов vless с полями из parse-vless-link.sh
# Возвращаемый код:
#   0 — успех (хотя бы одна ссылка распознана)
#   1 — ошибка (нет ссылок, невалидный формат, network error)
#   2 — ошибка параметров

set -euo pipefail

SUBSCRIPTION_URL="${SUBSCRIPTION_URL:?SUBSCRIPTION_URL обязателен}"

# User-Agent для имитации одного из xray-клиентов (для тех subscription endpoint,
# которые отдают формат по UA — мы хотим xray-формат, не sing-box JSON).
USER_AGENT="${USER_AGENT:-v2rayN/6.42 (Windows; X64)}"

# Скачиваем
RESPONSE="$(curl -sS \
    --max-time 30 \
    -A "$USER_AGENT" \
    "$SUBSCRIPTION_URL" 2>&1)" || {
    echo "ERROR: не удалось скачать $SUBSCRIPTION_URL" >&2
    echo "  curl: $RESPONSE" >&2
    exit 1
}

if [ -z "$RESPONSE" ]; then
    echo "ERROR: пустой ответ от $SUBSCRIPTION_URL" >&2
    exit 1
fi

# Пробуем base64-decode. Не все провайдеры используют base64.
DECODED=""
# Эвристика: base64 не содержит '://' и состоит из A-Za-z0-9+/= и whitespace
if echo "$RESPONSE" | grep -qv '://' && echo "$RESPONSE" | grep -qE '^[A-Za-z0-9+/=[:space:]]+$'; then
    DECODED="$(echo "$RESPONSE" | base64 -d 2>/dev/null || echo "$RESPONSE" | tr -d '\n\r' | base64 -d 2>/dev/null || echo "")"
fi

# Если base64 не распознался — используем как plain text
if [ -z "$DECODED" ] || ! echo "$DECODED" | grep -q '://'; then
    DECODED="$RESPONSE"
fi

# Извлекаем все vless://-ссылки (по одной на строку)
LINKS="$(echo "$DECODED" | grep -oE 'vless://[^[:space:]]+' || true)"

if [ -z "$LINKS" ]; then
    echo "ERROR: не найдено vless://-ссылок в подписке" >&2
    echo "  (возможно, провайдер отдаёт sing-box JSON или Clash YAML — нужен другой User-Agent)" >&2
    echo "  Содержимое subscription (первые 200 байт):" >&2
    echo "  $(echo "$DECODED" | head -c 200)" >&2
    exit 1
fi

# Получаем количество ссылок
LINK_COUNT="$(echo "$LINKS" | wc -l | tr -d ' ')"
echo "[parse-sub] Найдено $LINK_COUNT vless://-ссылок в подписке" >&2

# Путь к parse-vless-link.sh — рядом
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSE_LINK="${SCRIPT_DIR}/parse-vless-link.sh"

if [ ! -x "$PARSE_LINK" ]; then
    echo "ERROR: не найден parse-vless-link.sh рядом ($PARSE_LINK)" >&2
    exit 1
fi

# Парсим каждую ссылку и собираем в JSON-массив
echo "$LINKS" | while IFS= read -r link; do
    [ -z "$link" ] && continue
    "$PARSE_LINK" "$link" 2>/dev/null || {
        echo "WARN: пропускаю невалидную ссылку: $link" >&2
        continue
    }
done | jq -s '.'  # -s = slurp: соединяет JSON-объекты в массив

exit 0
