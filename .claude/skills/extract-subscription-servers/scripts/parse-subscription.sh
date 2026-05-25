#!/bin/bash
# parse-subscription.sh — скачать subscription URL, ОПРЕДЕЛИТЬ ФОРМАТ и разобрать
# в единый НОРМАЛИЗОВАННЫЙ JSON-массив серверов.
#
# В отличие от старой версии (только vless://-списки), этот скрипт распознаёт
# ЧЕТЫРЕ формата тела ответа и сам выбирает парсер:
#   1. base64-encoded список vless://-ссылок   → parse-vless-link.sh
#   2. plain-text список vless://-ссылок        → parse-vless-link.sh
#   3. Xray-JSON массив профилей (Panterra/Remnawave!) → parse-xray-json.sh
#   4. sing-box JSON                             → parse-xray-json.sh
# Именно формат 3 старый скрипт не понимал — отсюда ложный «0 серверов» на
# подписках Panterra (они отдают массив Xray-профилей, а не vless://-строки).
#
# HWID-locked (Panterra / NurVPN / Happ-подобные): реальный список отдаётся
# ТОЛЬКО зарегистрированному устройству по X-Hwid + набору Happ-заголовков.
# Незнакомый/чужой HWID → заглушка (0.0.0.0 / «App not supported» / нулевые UUID).
#
# Стратегия клиента (канон ADR-0010): Happ — основной при HWID-locked, v2rayN —
# фолбэк/дефолт для обычных подписок.
#
# Использование:
#   SUBSCRIPTION_URL='https://sub.provider.com/abc123' ./parse-subscription.sh
#   SUBSCRIPTION_URL='...' HWID='0123456789abcdef' ./parse-subscription.sh
#
# Переменные окружения:
#   SUBSCRIPTION_URL — обязательна.
#   HWID             — hardware ID для X-Hwid (включает Happ-профиль заголовков).
#   SUB_CLIENT       — happ | v2rayn (форсирует профиль; по умолчанию авто).
#   USER_AGENT       — ручной override User-Agent (выше SUB_CLIENT).
#   DEVICE_OS,DEVICE_MODEL,DEVICE_OS_VER,DEVICE_LOCALE — поля Happ-профиля.
#
# Выход (stdout): НОРМАЛИЗОВАННЫЙ JSON-массив серверов (поля как у
#   parse-xray-json.sh / parse-vless-link.sh: tag,host,port,uuid,flow,network,
#   security,sni,pbk,sid,spx,fp,path,host_header,service_name,alpn).
# Возвращаемый код:
#   0 — успех (хотя бы один реальный сервер)
#   1 — ошибка (нет серверов, невалидный формат, network error)
#   2 — ошибка параметров
#   3 — HWID-ЗАГЛУШКА: подписка живая, но список скрыт за HWID-замком

set -euo pipefail

SUBSCRIPTION_URL="${SUBSCRIPTION_URL:?SUBSCRIPTION_URL обязателен}"
HWID="${HWID:-}"
SUB_CLIENT="${SUB_CLIENT:-}"

DEVICE_OS="${DEVICE_OS:-macOS}"
DEVICE_MODEL="${DEVICE_MODEL:-MacBookPro}"
DEVICE_OS_VER="${DEVICE_OS_VER:-14}"
DEVICE_LOCALE="${DEVICE_LOCALE:-ru}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSE_LINK="${SCRIPT_DIR}/parse-vless-link.sh"
PARSE_XRAY="${SCRIPT_DIR}/parse-xray-json.sh"

# Выбор начального профиля заголовков.
if [ "$SUB_CLIENT" = "happ" ] || { [ -z "$SUB_CLIENT" ] && [ -n "$HWID" ]; }; then
    PROFILE="happ"
else
    PROFILE="v2rayn"
fi
[ "$SUB_CLIENT" = "v2rayn" ] && PROFILE="v2rayn"

# fetch_sub <profile> — скачивает тело подписки нужным профилем на stdout.
fetch_sub() {
    local profile="$1"
    if [ "$profile" = "happ" ]; then
        local ua="${USER_AGENT:-Happ/4.9.0}"
        curl -sS --max-time 30 \
            -A "$ua" \
            -H "X-Device-Os: $DEVICE_OS" \
            -H "X-Device-Locale: $DEVICE_LOCALE" \
            -H "X-Device-Model: $DEVICE_MODEL" \
            -H "X-Ver-Os: $DEVICE_OS_VER" \
            -H "Connection: close" \
            ${HWID:+-H "X-Hwid: $HWID"} \
            "$SUBSCRIPTION_URL"
    else
        local ua="${USER_AGENT:-v2rayN/6.42 (Windows; X64)}"
        curl -sS --max-time 30 -A "$ua" "$SUBSCRIPTION_URL"
    fi
}

# is_stub_response — true, если ответ выглядит как HWID-заглушка.
is_stub_response() {
    local decoded="$1"
    # Если это валидный JSON-массив с реальными серверами — НЕ заглушка
    # (заглушки приходят строками, не структурой профилей).
    if echo "$decoded" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
        return 1
    fi
    if echo "$decoded" | grep -qiE 'app not supported|приложение не поддержив|device limit|лимит устройств'; then
        return 0
    fi
    if echo "$decoded" | grep -qE '(^|@)0\.0\.0\.0(:|$)'; then
        return 0
    fi
    local total real
    total="$(echo "$decoded" | grep -cE 'vless://' || true)"
    real="$(echo "$decoded" | grep -E 'vless://' | grep -cvE 'vless://0{8}-0{4}-0{4}-0{4}-0{12}' || true)"
    if [ "$total" -gt 0 ] && [ "$real" -eq 0 ]; then
        return 0
    fi
    return 1
}

# decode_response — base64-decode при необходимости, иначе оставить как есть.
# JSON-тело (Xray/sing-box) НЕ трогаем — оно не base64.
decode_response() {
    local raw="$1" decoded=""
    # Если уже JSON — не декодируем.
    if echo "$raw" | jq empty >/dev/null 2>&1; then
        printf '%s' "$raw"
        return
    fi
    # Похоже на base64 (нет ://, только base64-алфавит) → декодируем.
    if echo "$raw" | grep -qv '://' && echo "$raw" | grep -qE '^[A-Za-z0-9+/=[:space:]]+$'; then
        decoded="$(echo "$raw" | base64 -d 2>/dev/null || echo "$raw" | tr -d '\n\r' | base64 -d 2>/dev/null || echo "")"
    fi
    if [ -z "$decoded" ] || { ! echo "$decoded" | grep -q '://' && ! echo "$decoded" | jq empty >/dev/null 2>&1; }; then
        decoded="$raw"
    fi
    printf '%s' "$decoded"
}

# --- Запрос (с фолбэком профиля при HWID-заглушке) -------------------------
echo "[parse-sub] Профиль заголовков: $PROFILE${HWID:+ (X-Hwid задан)}" >&2

RESPONSE="$(fetch_sub "$PROFILE" 2>&1)" || {
    echo "ERROR: не удалось скачать $SUBSCRIPTION_URL" >&2
    echo "  curl: $RESPONSE" >&2
    exit 1
}
if [ -z "$RESPONSE" ]; then
    echo "ERROR: пустой ответ от $SUBSCRIPTION_URL" >&2
    exit 1
fi

DECODED="$(decode_response "$RESPONSE")"

# Авто-ретрай Happ-профилем при заглушке (если ещё не пробовали и HWID есть).
if is_stub_response "$DECODED" && [ "$PROFILE" != "happ" ] && [ -n "$HWID" ]; then
    echo "[parse-sub] Похоже на HWID-заглушку. Повторяю запрос Happ-профилем с X-Hwid…" >&2
    RESPONSE="$(fetch_sub happ 2>&1)" || true
    DECODED="$(decode_response "$RESPONSE")"
    PROFILE="happ"
fi

# Если после всех попыток это заглушка — diagnostics (exit 3), НЕ глухой fail.
if is_stub_response "$DECODED"; then
    {
        echo "STUB: подписка живая, но реальный список серверов СКРЫТ за HWID-замком."
        echo "  Провайдер (Panterra / NurVPN / Happ-подобный) отдаёт реальные сервера"
        echo "  ТОЛЬКО зарегистрированному устройству по X-Hwid."
        echo "  Сейчас ответ — заглушка (0.0.0.0 / «App not supported» / нулевые UUID)."
        echo "  Содержимое (первые 200 байт): $(echo "$DECODED" | head -c 200)"
        echo ""
        echo "  ЧТО ДЕЛАТЬ (см. references/hwid-mechanism.md):"
        echo "  1. Проверь в приложении/боте провайдера — есть ли СВОБОДНЫЙ слот устройства."
        echo "     Все слоты заняты → освободи один (удали старое устройство)."
        echo "  2. Добудь HWID: resolve-hwid.sh (путь A из установленного Happ — слот не тратим,"
        echo "     путь B — стабильный сгенерированный, займёт 1 свободный слот)."
        echo "  3. Перезапусти: HWID=<hwid> ./parse-subscription.sh"
    } >&2
    exit 3
fi

# --- Определяем ФОРМАТ и диспетчеризуем -------------------------------------
# Формат 3/4: тело — валидный JSON (массив Xray-профилей или sing-box объект).
if echo "$DECODED" | jq -e 'type == "array" or (type == "object" and has("outbounds"))' >/dev/null 2>&1; then
    echo "[parse-sub] Формат: Xray/sing-box JSON → parse-xray-json.sh" >&2
    if [ ! -x "$PARSE_XRAY" ]; then
        echo "ERROR: не найден parse-xray-json.sh рядом ($PARSE_XRAY)" >&2
        exit 1
    fi
    echo "$DECODED" | "$PARSE_XRAY"
    exit $?
fi

# Формат 1/2: тело — список vless://-ссылок (base64 уже раскодирован выше).
LINKS="$(echo "$DECODED" | grep -oE 'vless://[^[:space:]]+' \
        | grep -vE 'vless://0{8}-0{4}-0{4}-0{4}-0{12}' || true)"

if [ -z "$LINKS" ]; then
    echo "ERROR: не найдено ни vless://-ссылок, ни Xray/sing-box JSON в подписке." >&2
    echo "  (возможно, Clash YAML — нужен другой User-Agent; либо HWID-locked без HWID)" >&2
    echo "  Содержимое (первые 200 байт): $(echo "$DECODED" | head -c 200)" >&2
    exit 1
fi

LINK_COUNT="$(echo "$LINKS" | wc -l | tr -d ' ')"
echo "[parse-sub] Формат: список vless:// ($LINK_COUNT шт, профиль: $PROFILE)" >&2

if [ ! -x "$PARSE_LINK" ]; then
    echo "ERROR: не найден parse-vless-link.sh рядом ($PARSE_LINK)" >&2
    exit 1
fi

# Парсим каждую ссылку → объекты → массив.
# parse-vless-link.sh использует поле "type" для транспорта и не проставляет
# country/network/remark. Приводим к ЕДИНОЙ схеме с parse-xray-json.sh:
#   • network = type (транспорт);
#   • remark  = tag;
#   • country = определяем из тега (эмодзи-флаг / текст), как parse-xray-json;
#               не распознали → "?" (страну НЕ выдумываем — правило №1).
echo "$LINKS" | while IFS= read -r link; do
    [ -z "$link" ] && continue
    "$PARSE_LINK" "$link" 2>/dev/null || {
        echo "WARN: пропускаю невалидную ссылку: $link" >&2
        continue
    }
done | jq -s '
    def flag_to_iso($s):
        [ ($s // "") | explode[] | select(. >= 127462 and . <= 127487) | (. - 127397) ]
        | if length >= 2 then ([.[0], .[1]] | implode) else "" end;
    def text_to_iso($s):
        (($s // "") | ascii_upcase) as $t
        | if   ($t | test("\\b(USA|UNITED STATES|US|США)\\b")) then "US"
          elif ($t | test("\\b(NETHERLANDS|HOLLAND|NL|НИДЕРЛАНД)\\b")) then "NL"
          elif ($t | test("\\b(GERMANY|DEUTSCHLAND|DE|ГЕРМАНИ)\\b")) then "DE"
          elif ($t | test("\\b(FINLAND|FI|ФИНЛЯНД)\\b")) then "FI"
          elif ($t | test("\\b(FRANCE|FR|ФРАНЦ)\\b")) then "FR"
          elif ($t | test("\\b(UNITED KINGDOM|UK|GB|БРИТАН)\\b")) then "GB"
          elif ($t | test("\\b(SWEDEN|SE|ШВЕЦИ)\\b")) then "SE"
          elif ($t | test("\\b(JAPAN|JP|ЯПОНИ)\\b")) then "JP"
          elif ($t | test("\\b(SINGAPORE|SG|СИНГАПУР)\\b")) then "SG"
          elif ($t | test("\\b(TURKEY|TR|ТУРЦИ)\\b")) then "TR"
          elif ($t | test("\\b(POLAND|PL|ПОЛЬШ)\\b")) then "PL"
          elif ($t | test("\\b(LATVIA|LV|ЛАТВИ)\\b")) then "LV"
          elif ($t | test("\\b(KAZAKHSTAN|KZ|КАЗАХ)\\b")) then "KZ"
          elif ($t | test("\\b(RUSSIA|RU|РОССИ)\\b")) then "RU"
          else "" end;
    map(
        (.tag // "") as $tag
        | (flag_to_iso($tag)) as $byflag
        | (if $byflag != "" then $byflag else text_to_iso($tag) end) as $iso
        | . + {
            network: (.network // .type // "tcp"),
            remark: $tag,
            country: (if $iso != "" then $iso else "?" end)
          }
        | del(.type)
    )'

exit 0
