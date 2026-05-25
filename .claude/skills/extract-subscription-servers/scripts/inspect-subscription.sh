#!/bin/bash
# inspect-subscription.sh — РАЗВЕДКА подписки по HTTP-заголовкам (READ-ONLY).
#
# ЗАЧЕМ: прежде чем тащить сервера, нужно понять, ЧТО за подписка перед нами:
#   • Живая ли она (оплачена / не истёк срок / есть трафик)?
#   • Прячет ли провайдер сервера за HWID-замком (панель Remnawave: Panterra,
#     NurVPN)?
#   • В каком состоянии HWID-механизм (наше устройство уже зарегистрировано? нет
#     слотов? мы прислали не-Happ клиента)?
#   • Как называется профиль, нет ли сообщения от провайдера (announce — там
#     часто инструкция / ссылка на бота)?
#
# Это «сердце под ключ»: по JSON-вердикту скилл понимает, ЧТО сказать новичку
# человеческим языком и какой шаг делать дальше — без технических развилок
# перед пользователем.
#
# Заголовки ответа Remnawave (читаем через curl -sI / -D-):
#   x-hwid-active: true            — HWID-механизм включён.
#   x-hwid-limit:  true            — лимит устройств включён.
#   x-hwid-not-supported: true     — прислан НЕ-Happ клиент → заглушка.
#   x-hwid-max-devices-reached: true — слотов нет / HWID не в списке → заглушка.
#   subscription-userinfo: upload=..;download=..;total=..;expire=<unixts>
#   profile-title: base64:...      — название (декодируем).
#   announce: base64:...           — сообщение провайдера (декодируем).
#
# Использование:
#   SUBSCRIPTION_URL='https://sub.example/abc' ./inspect-subscription.sh
#   # с Happ-профилем + HWID (для проверки уже зарегистрированного устройства):
#   SUBSCRIPTION_URL='...' HWID='0123...' ./inspect-subscription.sh
#
# Переменные:
#   SUBSCRIPTION_URL — обязательна.
#   HWID             — если задан → шлём Happ-профиль заголовков с X-Hwid.
#   USER_AGENT, DEVICE_OS, DEVICE_MODEL, DEVICE_OS_VER, DEVICE_LOCALE — как в
#                      parse-subscription.sh (служебные значения запроса).
#
# Выход (stdout): JSON-вердикт:
#   {
#     "kind": "plain" | "hwid_locked",
#     "alive": true | false | null,
#     "hwid_state": "ok" | "not_supported" | "max_devices_reached" | "unknown",
#     "profile_title": "...",
#     "expire_date": "YYYY-MM-DD" | null,
#     "expire_unix": <int> | null,
#     "traffic_used_gb": <float> | null,
#     "traffic_total_gb": <float> | null,
#     "announce": "..." | null,
#     "http_status": <int>
#   }
# Диагностика — stderr. Возвращаемый код:
#   0 — разведка прошла (вердикт на stdout)
#   1 — сеть/HTTP-ошибка (не достучались)
#   2 — ошибка параметров

set -euo pipefail

SUBSCRIPTION_URL="${SUBSCRIPTION_URL:?SUBSCRIPTION_URL обязателен}"
HWID="${HWID:-}"

DEVICE_OS="${DEVICE_OS:-macOS}"
DEVICE_MODEL="${DEVICE_MODEL:-MacBookPro}"
DEVICE_OS_VER="${DEVICE_OS_VER:-14}"
DEVICE_LOCALE="${DEVICE_LOCALE:-ru}"

# Скачиваем ТОЛЬКО заголовки + статус. С HWID — Happ-профиль (чтобы увидеть
# реальное состояние замка для нашего устройства); без HWID — нейтральный
# запрос (увидим, активен ли вообще HWID-механизм).
HEADERS_FILE="$(mktemp)"
trap 'rm -f "$HEADERS_FILE"' EXIT

if [ -n "$HWID" ]; then
    UA="${USER_AGENT:-Happ/4.9.0}"
    HTTP_STATUS="$(curl -sS --max-time 30 -o /dev/null -D "$HEADERS_FILE" -w '%{http_code}' \
        -A "$UA" \
        -H "X-Device-Os: $DEVICE_OS" \
        -H "X-Device-Locale: $DEVICE_LOCALE" \
        -H "X-Device-Model: $DEVICE_MODEL" \
        -H "X-Ver-Os: $DEVICE_OS_VER" \
        -H "Connection: close" \
        -H "X-Hwid: $HWID" \
        "$SUBSCRIPTION_URL" 2>/dev/null)" || {
        echo "ERROR: не удалось достучаться до $SUBSCRIPTION_URL" >&2
        exit 1
    }
else
    UA="${USER_AGENT:-Happ/4.9.0}"
    HTTP_STATUS="$(curl -sS --max-time 30 -o /dev/null -D "$HEADERS_FILE" -w '%{http_code}' \
        -A "$UA" \
        -H "X-Device-Os: $DEVICE_OS" \
        -H "X-Device-Locale: $DEVICE_LOCALE" \
        -H "X-Device-Model: $DEVICE_MODEL" \
        -H "X-Ver-Os: $DEVICE_OS_VER" \
        -H "Connection: close" \
        "$SUBSCRIPTION_URL" 2>/dev/null)" || {
        echo "ERROR: не удалось достучаться до $SUBSCRIPTION_URL" >&2
        exit 1
    }
fi

# header_value <name> — извлечь значение заголовка (case-insensitive, последнее
# вхождение — на случай редиректов).
header_value() {
    local name="$1"
    grep -i "^${name}:" "$HEADERS_FILE" 2>/dev/null \
        | tail -n1 \
        | sed -E "s/^[^:]+:[[:space:]]*//" \
        | tr -d '\r'
}

# header_flag <name> — true, если заголовок присутствует и равен "true".
header_flag() {
    local v
    v="$(header_value "$1" | tr '[:upper:]' '[:lower:]')"
    [ "$v" = "true" ]
}

# b64dec — декодировать "base64:XXXX" или просто base64. Возвращает текст.
b64dec() {
    local raw="$1"
    raw="${raw#base64:}"
    [ -z "$raw" ] && { printf ''; return; }
    printf '%s' "$raw" | base64 -d 2>/dev/null || printf '%s' "$raw" | tr -d '\n\r' | base64 -d 2>/dev/null || printf ''
}

# --- Разбор заголовков ------------------------------------------------------
HWID_ACTIVE="false"; header_flag "x-hwid-active" && HWID_ACTIVE="true"
HWID_LIMIT="false";  header_flag "x-hwid-limit" && HWID_LIMIT="true"
NOT_SUPPORTED="false"; header_flag "x-hwid-not-supported" && NOT_SUPPORTED="true"
MAX_REACHED="false"; header_flag "x-hwid-max-devices-reached" && MAX_REACHED="true"

PROFILE_TITLE="$(b64dec "$(header_value 'profile-title')")"
ANNOUNCE="$(b64dec "$(header_value 'announce')")"
USERINFO="$(header_value 'subscription-userinfo')"

# kind: hwid_locked, если любой x-hwid-* флаг активен.
if [ "$HWID_ACTIVE" = "true" ] || [ "$HWID_LIMIT" = "true" ] || \
   [ "$NOT_SUPPORTED" = "true" ] || [ "$MAX_REACHED" = "true" ]; then
    KIND="hwid_locked"
else
    KIND="plain"
fi

# hwid_state: приоритет not_supported > max_devices_reached > ok > unknown.
if [ "$NOT_SUPPORTED" = "true" ]; then
    HWID_STATE="not_supported"
elif [ "$MAX_REACHED" = "true" ]; then
    HWID_STATE="max_devices_reached"
elif [ "$KIND" = "hwid_locked" ]; then
    # Замок активен, но заглушек нет → наше устройство принято (ok).
    HWID_STATE="ok"
else
    HWID_STATE="unknown"
fi

# subscription-userinfo: upload=..;download=..;total=..;expire=<unixts>
EXPIRE_UNIX=""; EXPIRE_DATE=""; USED_GB=""; TOTAL_GB=""; ALIVE="null"
if [ -n "$USERINFO" ]; then
    get_ui() { echo "$USERINFO" | tr ';' '\n' | grep -iE "(^|[[:space:]])$1=" | head -n1 | sed -E "s/.*$1=//" | tr -d ' \r'; }
    UP="$(get_ui upload)"; DOWN="$(get_ui download)"; TOTAL="$(get_ui total)"; EXP="$(get_ui expire)"

    # Расход = upload + download (байты → ГБ).
    # LC_ALL=C — иначе awk в локали ru_RU.UTF-8 печатает "15,00" (запятая),
    # и jq не парсит это как число. Точка обязательна. LC_NUMERIC недостаточно —
    # его перебивает LC_ALL из окружения, поэтому фиксируем именно LC_ALL.
    if [ -n "$UP" ] || [ -n "$DOWN" ]; then
        USED_GB="$(LC_ALL=C awk -v u="${UP:-0}" -v d="${DOWN:-0}" 'BEGIN{printf "%.2f", (u+d)/1073741824}')"
    fi
    if [ -n "$TOTAL" ] && [ "$TOTAL" != "0" ]; then
        TOTAL_GB="$(LC_ALL=C awk -v t="$TOTAL" 'BEGIN{printf "%.2f", t/1073741824}')"
    fi
    # Срок (Unix timestamp → дата). expire=0 у некоторых = «без срока».
    if [ -n "$EXP" ] && [ "$EXP" != "0" ]; then
        EXPIRE_UNIX="$EXP"
        EXPIRE_DATE="$(date -u -r "$EXP" +%Y-%m-%d 2>/dev/null || date -u -d "@$EXP" +%Y-%m-%d 2>/dev/null || echo "")"
        # Жива ли: срок в будущем?
        NOW_TS="$(date -u +%s)"
        if [ "$EXP" -gt "$NOW_TS" ] 2>/dev/null; then ALIVE="true"; else ALIVE="false"; fi
    else
        # Есть userinfo, но без срока → считаем живой (бессрочная/безлимит).
        ALIVE="true"
    fi
fi

# --- Диагностика в stderr (человеко-читаемо для отчёта агента) --------------
{
    echo "[inspect] HTTP-статус: $HTTP_STATUS"
    echo "[inspect] kind=$KIND, hwid_state=$HWID_STATE, alive=$ALIVE"
    [ -n "$PROFILE_TITLE" ] && echo "[inspect] Название: $PROFILE_TITLE"
    [ -n "$EXPIRE_DATE" ]   && echo "[inspect] Срок до: $EXPIRE_DATE"
    [ -n "$USED_GB" ]       && echo "[inspect] Потрачено: ${USED_GB} ГБ${TOTAL_GB:+ из ${TOTAL_GB} ГБ}"
    [ -n "$ANNOUNCE" ]      && echo "[inspect] Сообщение провайдера: $ANNOUNCE"
} >&2

# --- JSON-вердикт на stdout -------------------------------------------------
jq -n \
    --arg kind "$KIND" \
    --arg hwid_state "$HWID_STATE" \
    --arg profile_title "$PROFILE_TITLE" \
    --arg announce "$ANNOUNCE" \
    --arg expire_date "$EXPIRE_DATE" \
    --arg expire_unix "$EXPIRE_UNIX" \
    --arg used_gb "$USED_GB" \
    --arg total_gb "$TOTAL_GB" \
    --arg alive "$ALIVE" \
    --arg http_status "$HTTP_STATUS" \
    '{
        kind: $kind,
        alive: (if $alive == "true" then true elif $alive == "false" then false else null end),
        hwid_state: $hwid_state,
        profile_title: (if $profile_title == "" then null else $profile_title end),
        expire_date: (if $expire_date == "" then null else $expire_date end),
        expire_unix: (if $expire_unix == "" then null else ($expire_unix | tonumber) end),
        traffic_used_gb: (if $used_gb == "" then null else ($used_gb | tonumber) end),
        traffic_total_gb: (if $total_gb == "" then null else ($total_gb | tonumber) end),
        announce: (if $announce == "" then null else $announce end),
        http_status: ($http_status | tonumber)
    }'

exit 0
