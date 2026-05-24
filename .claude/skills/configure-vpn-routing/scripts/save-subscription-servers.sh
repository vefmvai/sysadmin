#!/bin/bash
# save-subscription-servers.sh — сохранить извлечённые из подписки сервера в infra/
# и разметить их по странам (для диалога выбора выхода на Шаге 5b).
#
# ЗАЧЕМ: parse-subscription.sh отдаёт JSON-массив серверов на stdout (эфемерно).
# Этот скрипт кладёт их в постоянное хранилище оператора —
#   $INFRA/inventory/shared/vpn-subscriptions/<provider-slug>.json
# чтобы сервера остались в распоряжении агента между сессиями (требование
# оператора). Та же папка, что использует ручное извлечение HAPP/NurVPN-подписок.
#
# Дополнительно проставляет каждому серверу поле "country" (ISO-флаг + код),
# определённое из тега (#🇺🇸 USA-1) или, если тега нет, оставляет "country": "?"
# (страну НЕ выдумываем — правило №1 CLAUDE.md; определение по гео-IP делает
# вызывающий скилл при необходимости).
#
# Использование:
#   PARSED_JSON=/tmp/subs.json \
#   PROVIDER_SLUG=blanc \
#   INFRA_DIR=/path/to/infra \
#   ./save-subscription-servers.sh
#
#   # либо PARSED_JSON через stdin:
#   cat /tmp/subs.json | PROVIDER_SLUG=blanc INFRA_DIR=... ./save-subscription-servers.sh
#
# Выход (stdout): JSON-массив серверов С добавленным полем country (для дальнейшей
#                 группировки). Путь сохранённого файла — в stderr.
# Возвращаемый код:
#   0 — сохранено
#   1 — ошибка (нет INFRA_DIR, нет входных данных)
#   2 — ошибка параметров

set -euo pipefail

PROVIDER_SLUG="${PROVIDER_SLUG:-subscription}"
# Нормализуем slug (только a-z0-9-_)
PROVIDER_SLUG="$(echo "$PROVIDER_SLUG" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9_-' '-' | sed 's/^-*//; s/-*$//')"
[ -z "$PROVIDER_SLUG" ] && PROVIDER_SLUG="subscription"

# Входные данные: файл или stdin
if [ -n "${PARSED_JSON:-}" ]; then
    [ -f "$PARSED_JSON" ] || { echo "ERROR: PARSED_JSON=$PARSED_JSON не найден" >&2; exit 1; }
    INPUT="$(cat "$PARSED_JSON")"
else
    INPUT="$(cat)"
fi

if [ -z "$INPUT" ] || ! echo "$INPUT" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "ERROR: на входе ожидался JSON-массив серверов (вывод parse-subscription.sh)" >&2
    exit 1
fi

# Пустой массив — формально валиден, но сохранять/маршрутизировать нечего.
# Сигналим явно, чтобы вызывающий скилл не пошёл дальше с пустым выходом.
if [ "$(echo "$INPUT" | jq 'length')" -eq 0 ]; then
    echo "ERROR: в подписке 0 серверов — нечего сохранять и заводить в outbound." >&2
    echo "       Проверь подписную ссылку / User-Agent (см. references/subscription-formats.md)." >&2
    exit 1
fi

# INFRA_DIR обязателен — без него некуда сохранять
if [ -z "${INFRA_DIR:-}" ]; then
    echo "ERROR: INFRA_DIR не задан — некуда сохранять сервера." >&2
    echo "       Передай путь к папке infra (infrastructure.root_path из конфига)." >&2
    exit 1
fi

# Определение страны из тега. Поддерживаем:
#  1. Эмодзи-флаги (🇺🇸 🇳🇱 🇩🇪 ...) — конвертируем regional indicator → ISO-код.
#  2. Текстовые маркеры в теге (USA, US, Netherlands, NL, Germany, DE, ...).
# Если ничего не нашли — "?". Страну НЕ выдумываем.
#
# Эмодзи-флаг = два Unicode regional indicator symbol (U+1F1E6..U+1F1FF).
# Каждый = 'A'..'Z' + 0x1F1A5. jq умеет explode/implode по codepoints.
ENRICHED="$(echo "$INPUT" | jq '
    def flag_to_iso:
        # explode тега, ищем пару regional indicators (127462..127487)
        [ explode[] | select(. >= 127462 and . <= 127487) | (. - 127397) ]
        | if length >= 2 then ([.[0], .[1]] | implode) else "" end;
    def text_to_iso(tag):
        (tag | ascii_upcase) as $t
        | if   ($t | test("\\b(USA|UNITED STATES|US)\\b"))      then "US"
          elif ($t | test("\\b(NETHERLANDS|HOLLAND|NL)\\b"))    then "NL"
          elif ($t | test("\\b(GERMANY|DEUTSCHLAND|DE)\\b"))    then "DE"
          elif ($t | test("\\b(FINLAND|FI)\\b"))                then "FI"
          elif ($t | test("\\b(FRANCE|FR)\\b"))                 then "FR"
          elif ($t | test("\\b(UNITED KINGDOM|UK|GB)\\b"))      then "GB"
          elif ($t | test("\\b(SWEDEN|SE)\\b"))                 then "SE"
          elif ($t | test("\\b(JAPAN|JP)\\b"))                  then "JP"
          elif ($t | test("\\b(SINGAPORE|SG)\\b"))              then "SG"
          elif ($t | test("\\b(TURKEY|TR)\\b"))                 then "TR"
          elif ($t | test("\\b(POLAND|PL)\\b"))                 then "PL"
          elif ($t | test("\\b(KAZAKHSTAN|KZ)\\b"))             then "KZ"
          else "" end;
    map(
        (.tag // "") as $tag
        | ($tag | flag_to_iso) as $byflag
        | (if $byflag != "" then $byflag else text_to_iso($tag) end) as $iso
        | . + { country: (if $iso != "" then $iso else "?" end) }
    )
')"

# Куда сохраняем
DEST_DIR="${INFRA_DIR%/}/inventory/shared/vpn-subscriptions"
mkdir -p "$DEST_DIR"
DEST_FILE="${DEST_DIR}/${PROVIDER_SLUG}.json"

# Сохраняем с метаданными (когда, сколько, из какого провайдера).
# REDACTION: файл содержит реальные UUID/хосты — он живёт в приватной infra/,
# которая в .gitignore. В публичный sysadmin/ ничего не попадает.
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SERVER_COUNT="$(echo "$ENRICHED" | jq 'length')"

echo "$ENRICHED" | jq --arg provider "$PROVIDER_SLUG" --arg saved_at "$NOW" '{
    provider: $provider,
    saved_at: $saved_at,
    server_count: length,
    servers: .
}' > "$DEST_FILE"

# Сводка по странам — в stderr (для человеко-читаемого отчёта агента)
echo "[save-servers] Сохранено $SERVER_COUNT серверов → $DEST_FILE" >&2
echo "[save-servers] Сводка по странам:" >&2
echo "$ENRICHED" | jq -r 'group_by(.country) | .[] | "  \(.[0].country): \(length)"' >&2

# На stdout — обогащённый массив (с country) для дальнейшей группировки/фильтрации
echo "$ENRICHED"
exit 0
