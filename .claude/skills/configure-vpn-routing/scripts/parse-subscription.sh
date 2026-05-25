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
#  5. HWID-locked (Panterra / NurVPN / Happ-подобные): реальный список отдаётся
#     ТОЛЬКО зарегистрированному устройству по заголовку X-Hwid + набору Happ.
#     Незнакомый HWID → ЗАГЛУШКА (0.0.0.0 / «App not supported» / список из
#     UUID 00000000-...). См. ADR-0010 и references/subscription-formats.md «Формат 5».
#
# Скрипт извлекает только vless://-ссылки (см. parse-vless-link.sh для парсинга
# каждой).
#
# Стратегия клиента (канон ADR-0010): Happ — основной при HWID-locked, v2rayN —
# фолбэк/дефолт для обычных подписок.
#   - Если задан HWID (или SUB_CLIENT=happ) → шлём Happ-профиль заголовков сразу.
#   - Иначе шлём v2rayN. Если пришла HWID-заглушка И задан HWID → авто-ретрай с Happ.
#
# Использование:
#   # Обычная подписка (xray-формат):
#   SUBSCRIPTION_URL='https://sub.provider.com/abc123' ./parse-subscription.sh
#
#   # HWID-locked подписка (HWID берётся через resolve-hwid.sh):
#   SUBSCRIPTION_URL='...' HWID='0123456789abcdef' ./parse-subscription.sh
#
# Переменные окружения:
#   SUBSCRIPTION_URL — обязательна.
#   HWID             — hardware ID для X-Hwid (включает Happ-профиль заголовков).
#   SUB_CLIENT       — happ | v2rayn (форсирует профиль; по умолчанию авто).
#   USER_AGENT       — ручной override User-Agent (выше SUB_CLIENT).
#   DEVICE_OS,DEVICE_MODEL,DEVICE_OS_VER,DEVICE_LOCALE — поля Happ-профиля
#                      (дефолты: macOS / MacBookPro / 14 / ru).
#
# Выход (на stdout): JSON-массив объектов vless с полями из parse-vless-link.sh
# Возвращаемый код:
#   0 — успех (хотя бы одна РЕАЛЬНАЯ ссылка распознана)
#   1 — ошибка (нет ссылок, невалидный формат, network error)
#   2 — ошибка параметров
#   3 — HWID-ЗАГЛУШКА: подписка живая, но список скрыт за HWID-замком
#       (нужен правильный HWID + свободный слот — см. ADR-0010)

set -euo pipefail

SUBSCRIPTION_URL="${SUBSCRIPTION_URL:?SUBSCRIPTION_URL обязателен}"

HWID="${HWID:-}"
SUB_CLIENT="${SUB_CLIENT:-}"

# Поля Happ-профиля (НЕ выдумываем устройство оператора — это служебные значения
# запроса, имитирующие фирменное приложение; правило №1 их не касается).
DEVICE_OS="${DEVICE_OS:-macOS}"
DEVICE_MODEL="${DEVICE_MODEL:-MacBookPro}"
DEVICE_OS_VER="${DEVICE_OS_VER:-14}"
DEVICE_LOCALE="${DEVICE_LOCALE:-ru}"

# Выбор начального профиля заголовков.
#   - SUB_CLIENT=happ или задан HWID → Happ (основной для HWID-locked).
#   - иначе → v2rayN (дефолт для обычных подписок, отдаёт xray-формат).
if [ "$SUB_CLIENT" = "happ" ] || { [ -z "$SUB_CLIENT" ] && [ -n "$HWID" ]; }; then
    PROFILE="happ"
else
    PROFILE="v2rayn"
fi
[ "$SUB_CLIENT" = "v2rayn" ] && PROFILE="v2rayn"

# fetch_sub <profile> — скачивает подписку нужным профилем заголовков на stdout.
fetch_sub() {
    local profile="$1"
    if [ "$profile" = "happ" ]; then
        local ua="${USER_AGENT:-Happ/4.9.0}"
        # Полный набор заголовков Happ (см. reference_happ_subscription_extraction).
        # X-Hwid — ключевой: без него (или с незнакомым) сервер отдаёт заглушку.
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
# Признаки (любой → заглушка): маркер «App not supported»/«не поддерживается»,
# адрес 0.0.0.0 в строках, или vless-ссылки ТОЛЬКО с нулевыми UUID 00000000-0000.
is_stub_response() {
    local decoded="$1"
    if echo "$decoded" | grep -qiE 'app not supported|приложение не поддержив|device limit|лимит устройств'; then
        return 0
    fi
    if echo "$decoded" | grep -qE '(^|@)0\.0\.0\.0(:|$)'; then
        return 0
    fi
    # Все найденные vless — с нулевым UUID = заглушка (реальных серверов нет).
    local total real
    total="$(echo "$decoded" | grep -cE 'vless://' || true)"
    real="$(echo "$decoded" | grep -E 'vless://' | grep -cvE 'vless://0{8}-0{4}-0{4}-0{4}-0{12}' || true)"
    if [ "$total" -gt 0 ] && [ "$real" -eq 0 ]; then
        return 0
    fi
    return 1
}

# decode_response — base64-decode при необходимости, иначе plain.
decode_response() {
    local raw="$1" decoded=""
    if echo "$raw" | grep -qv '://' && echo "$raw" | grep -qE '^[A-Za-z0-9+/=[:space:]]+$'; then
        decoded="$(echo "$raw" | base64 -d 2>/dev/null || echo "$raw" | tr -d '\n\r' | base64 -d 2>/dev/null || echo "")"
    fi
    if [ -z "$decoded" ] || ! echo "$decoded" | grep -q '://'; then
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

# Если заглушка и мы ещё не пробовали Happ, но HWID есть — авто-ретрай Happ-профилем.
if is_stub_response "$DECODED" && [ "$PROFILE" != "happ" ] && [ -n "$HWID" ]; then
    echo "[parse-sub] Похоже на HWID-заглушку. Повторяю запрос Happ-профилем с X-Hwid…" >&2
    RESPONSE="$(fetch_sub happ 2>&1)" || true
    DECODED="$(decode_response "$RESPONSE")"
    PROFILE="happ"
fi

# Если после всех попыток это заглушка — диагностируем (exit 3), НЕ глухой fail.
if is_stub_response "$DECODED"; then
    {
        echo "STUB: подписка живая, но реальный список серверов СКРЫТ за HWID-замком."
        echo "  Провайдер (Panterra / NurVPN / Happ-подобный) отдаёт реальные сервера"
        echo "  ТОЛЬКО зарегистрированному устройству по заголовку X-Hwid."
        echo "  Сейчас ответ — заглушка (0.0.0.0 / «App not supported» / нулевые UUID)."
        echo "  Содержимое (первые 200 байт): $(echo "$DECODED" | head -c 200)"
        echo ""
        echo "  ЧТО ДЕЛАТЬ (см. ADR-0010):"
        echo "  1. Проверь в личном кабинете провайдера — есть ли СВОБОДНЫЙ слот устройства."
        echo "     Если все слоты заняты — освободи один (удали старое устройство)."
        echo "  2. Передай скилл HWID: либо из установленного Happ (resolve-hwid.sh MODE=happ),"
        echo "     либо стабильный сгенерированный (resolve-hwid.sh MODE=generate) — он займёт"
        echo "     1 освобождённый слот при первом запросе."
        echo "  3. Перезапусти: HWID=<hwid> ./parse-subscription.sh"
    } >&2
    exit 3
fi

# Извлекаем все vless://-ссылки (по одной на строку), исключая нулевые UUID-заглушки.
LINKS="$(echo "$DECODED" | grep -oE 'vless://[^[:space:]]+' \
        | grep -vE 'vless://0{8}-0{4}-0{4}-0{4}-0{12}' || true)"

if [ -z "$LINKS" ]; then
    echo "ERROR: не найдено vless://-ссылок в подписке" >&2
    echo "  (возможно, провайдер отдаёт sing-box JSON или Clash YAML — нужен другой User-Agent;" >&2
    echo "   либо HWID-locked без HWID — задай HWID=... , см. references/subscription-formats.md)" >&2
    echo "  Содержимое subscription (первые 200 байт):" >&2
    echo "  $(echo "$DECODED" | head -c 200)" >&2
    exit 1
fi

# Получаем количество ссылок
LINK_COUNT="$(echo "$LINKS" | wc -l | tr -d ' ')"
echo "[parse-sub] Найдено $LINK_COUNT vless://-ссылок в подписке (профиль: $PROFILE)" >&2

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
