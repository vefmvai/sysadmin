#!/bin/bash
# export-servers.sh — из НОРМАЛИЗОВАННОГО JSON-массива серверов сделать
# результат «под ключ»:
#   (а) человеко-читаемый .txt: сводка + параметры по странам + готовые
#       vless://-ссылки (которые можно скормить любому клиенту/панели);
#   (б) сохранить JSON в $INFRA/inventory/shared/vpn-subscriptions/<provider>.json
#       (постоянное хранилище серверов оператора — переживает сессию).
#
# vless://-ссылки собираются из нормализованных полей (тип транспорта и security
# определяют набор query-параметров). Это даёт оператору переносимый артефакт:
# одну ссылку = один сервер, готов к импорту.
#
# Использование:
#   NORMALIZED_JSON=/tmp/servers.json \
#   PROVIDER_SLUG=panterra \
#   INFRA_DIR=/path/to/infra \
#   [TXT_PATH=/custom/path.txt] \
#   ./export-servers.sh
#
#   # либо вход через stdin:
#   cat /tmp/servers.json | PROVIDER_SLUG=panterra INFRA_DIR=... ./export-servers.sh
#
# Переменные:
#   NORMALIZED_JSON — файл с массивом (или stdin).
#   PROVIDER_SLUG   — короткое имя провайдера (default: subscription).
#   INFRA_DIR       — папка infra. Если НЕ задана — JSON и .txt кладутся рядом
#                     (./<provider>.json, ./<provider>-servers.txt) + WARN.
#   TXT_PATH        — путь к .txt (default:
#                     $INFRA/inventory/shared/vpn-subscriptions/<provider>-servers.txt).
#
# Выход (stdout): путь сохранённого .txt-файла (одна строка).
# Диагностика (stderr): пути, сводка по странам.
# Возвращаемый код:
#   0 — успех
#   1 — нет данных / 0 серверов
#   2 — ошибка параметров

set -euo pipefail

PROVIDER_SLUG="${PROVIDER_SLUG:-subscription}"
PROVIDER_SLUG="$(echo "$PROVIDER_SLUG" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9_-' '-' | sed 's/^-*//; s/-*$//')"
[ -z "$PROVIDER_SLUG" ] && PROVIDER_SLUG="subscription"

# Вход: файл или stdin
if [ -n "${NORMALIZED_JSON:-}" ]; then
    [ -f "$NORMALIZED_JSON" ] || { echo "ERROR: NORMALIZED_JSON=$NORMALIZED_JSON не найден" >&2; exit 1; }
    INPUT="$(cat "$NORMALIZED_JSON")"
else
    INPUT="$(cat)"
fi

if [ -z "$INPUT" ] || ! echo "$INPUT" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "ERROR: на входе ожидался JSON-массив серверов (вывод parse-xray-json.sh / parse-subscription.sh)" >&2
    exit 1
fi

COUNT="$(echo "$INPUT" | jq 'length')"
if [ "$COUNT" -eq 0 ]; then
    echo "ERROR: 0 серверов — нечего экспортировать." >&2
    exit 1
fi

# --- urlencode (bash 3.2, без assoc-массивов) -------------------------------
# Кодирует ПОБАЙТНО — корректно для UTF-8 (эмодзи-флаги, кириллица в remarks).
# Тонкости:
#   • LC_ALL=C на всё тело функции → bash идёт по байтам, не по «широким» символам.
#   • printf "'$c" даёт код символа, но для байтов >127 он знаково расширяется
#     (даёт отрицательное / FFFFFF...). Маскируем `& 0xFF`, чтобы получить 0..255.
urlencode() {
    local s="$1" result="" i len c byte
    local LC_ALL=C LANG=C
    len=${#s}
    i=0
    while [ $i -lt $len ]; do
        c="${s:$i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) result="${result}${c}" ;;
            *)
                printf -v byte '%d' "'$c"
                byte=$(( byte & 0xFF ))
                result="${result}$(printf '%%%02X' "$byte")"
                ;;
        esac
        i=$((i + 1))
    done
    printf '%s' "$result"
}

# --- build_vless <server-json> — собрать vless://-ссылку из нормализованного объекта.
# Набор query-параметров зависит от security/network (как в generate-vless-link.sh).
build_vless() {
    local obj="$1"
    local uuid host port flow network security sni pbk sid spx fp path hosth svc alpn remark
    uuid="$(echo "$obj" | jq -r '.uuid // ""')"
    host="$(echo "$obj" | jq -r '.host // ""')"
    port="$(echo "$obj" | jq -r '.port // 443')"
    flow="$(echo "$obj" | jq -r '.flow // ""')"
    network="$(echo "$obj" | jq -r '.network // "tcp"')"
    security="$(echo "$obj" | jq -r '.security // "none"')"
    sni="$(echo "$obj" | jq -r '.sni // ""')"
    pbk="$(echo "$obj" | jq -r '.pbk // ""')"
    sid="$(echo "$obj" | jq -r '.sid // ""')"
    spx="$(echo "$obj" | jq -r '.spx // ""')"
    fp="$(echo "$obj" | jq -r '.fp // ""')"
    path="$(echo "$obj" | jq -r '.path // ""')"
    hosth="$(echo "$obj" | jq -r '.host_header // ""')"
    svc="$(echo "$obj" | jq -r '.service_name // ""')"
    alpn="$(echo "$obj" | jq -r '.alpn // ""')"
    remark="$(echo "$obj" | jq -r '.remark // .tag // ""')"

    # Без host/uuid ссылку не собрать — вернём пусто (caller пропустит).
    if [ -z "$host" ] || [ -z "$uuid" ]; then
        return 1
    fi

    local q="type=${network}&security=${security}"
    [ -n "$flow" ] && q="${q}&flow=${flow}"

    case "$security" in
        reality)
            [ -n "$sni" ] && q="${q}&sni=$(urlencode "$sni")"
            [ -n "$pbk" ] && q="${q}&pbk=$(urlencode "$pbk")"
            [ -n "$fp" ]  && q="${q}&fp=${fp}"
            [ -n "$sid" ] && q="${q}&sid=${sid}"
            [ -n "$spx" ] && q="${q}&spx=$(urlencode "$spx")"
            ;;
        tls)
            [ -n "$sni" ]  && q="${q}&sni=$(urlencode "$sni")"
            [ -n "$fp" ]   && q="${q}&fp=${fp}"
            [ -n "$alpn" ] && q="${q}&alpn=$(urlencode "$alpn")"
            ;;
    esac

    # Транспорт-специфичные поля
    case "$network" in
        xhttp|ws|http)
            [ -n "$path" ]  && q="${q}&path=$(urlencode "$path")"
            [ -n "$hosth" ] && q="${q}&host=$(urlencode "$hosth")"
            ;;
        grpc)
            [ -n "$svc" ] && q="${q}&serviceName=$(urlencode "$svc")"
            ;;
    esac

    printf 'vless://%s@%s:%s?%s#%s' "$uuid" "$host" "$port" "$q" "$(urlencode "$remark")"
}

# --- Куда сохраняем ---------------------------------------------------------
if [ -n "${INFRA_DIR:-}" ]; then
    DEST_DIR="${INFRA_DIR%/}/inventory/shared/vpn-subscriptions"
else
    echo "WARN: INFRA_DIR не задан — сохраняю рядом (./). Для постоянного хранения" >&2
    echo "      укажи infrastructure.root_path в sysadmin-config.json." >&2
    DEST_DIR="."
fi
mkdir -p "$DEST_DIR"

JSON_FILE="${DEST_DIR}/${PROVIDER_SLUG}.json"
TXT_FILE="${TXT_PATH:-${DEST_DIR}/${PROVIDER_SLUG}-servers.txt}"

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# (б) Сохраняем JSON с метаданными.
echo "$INPUT" | jq --arg provider "$PROVIDER_SLUG" --arg saved_at "$NOW" '{
    provider: $provider,
    saved_at: $saved_at,
    server_count: length,
    servers: .
}' > "$JSON_FILE"

# (а) Человеко-читаемый .txt.
{
    echo "VPN-сервера из подписки: ${PROVIDER_SLUG}"
    echo "Извлечено: ${NOW}"
    echo "Всего серверов: ${COUNT}"
    echo ""
    echo "Сводка по странам:"
    echo "$INPUT" | jq -r 'group_by(.country)[] | "  \(.[0].country): \(length) серв."'
    echo ""
    echo "ВНИМАНИЕ: ссылки ниже содержат рабочий UUID — это ключ доступа."
    echo "Не публикуй их и не пересылай в открытые чаты."
    echo ""
    echo "================================================================"

    # По странам — заголовок + сервера с параметрами и ссылкой.
    for c in $(echo "$INPUT" | jq -r '[.[].country] | unique | .[]'); do
        echo ""
        echo "### Страна: ${c}"
        echo ""
        # Каждый сервер этой страны
        echo "$INPUT" | jq -c --arg c "$c" '.[] | select(.country == $c)' | while IFS= read -r obj; do
            tag="$(echo "$obj" | jq -r '.tag // "?"')"
            remark="$(echo "$obj" | jq -r '.remark // ""')"
            host="$(echo "$obj" | jq -r '.host // "?"')"
            port="$(echo "$obj" | jq -r '.port // "?"')"
            network="$(echo "$obj" | jq -r '.network // "?"')"
            security="$(echo "$obj" | jq -r '.security // "?"')"
            echo "  • [$tag] ${remark}"
            echo "      адрес:     ${host}:${port}"
            echo "      транспорт: ${network} / ${security}"
            link="$(build_vless "$obj" 2>/dev/null || true)"
            if [ -n "$link" ]; then
                echo "      ссылка:    ${link}"
            else
                echo "      ссылка:    (не удалось собрать — нет host/uuid)"
            fi
            echo ""
        done
    done
} > "$TXT_FILE"

# Сводка в stderr
echo "[export] JSON сохранён → $JSON_FILE" >&2
echo "[export] .txt сохранён → $TXT_FILE" >&2
echo "[export] Сводка по странам:" >&2
echo "$INPUT" | jq -r 'group_by(.country)[] | "  \(.[0].country): \(length)"' >&2

# stdout — путь к .txt (для финального отчёта скилла)
printf '%s\n' "$TXT_FILE"
exit 0
