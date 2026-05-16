#!/usr/bin/env bash
# check-knowledge-freshness.sh — проверка свежести knowledge-файлов по их frontmatter.
#
# Используется:
#  - Лениво из персоны §4.2: перед любой VPN-задачей агент вызывает этот скрипт
#    с домен=vpn, чтобы понять — есть ли просроченные файлы.
#  - Из скилла /refresh-vpn-knowledge: получить точный список файлов для обновления.
#
# Формат frontmatter в knowledge-файлах:
#
#   ---
#   knowledge_domain: vpn        # или: server-ops, security, и т.д.
#   last_researched: 2026-05-15  # дата последнего активного исследования
#   ttl_days: 30                 # сколько дней актуальность сохраняется
#   sources_checked:             # URL'ы, которые были проверены
#     - https://...
#   ---
#
# Использование:
#
#   check-knowledge-freshness.sh                        # все домены, все файлы
#   check-knowledge-freshness.sh vpn                    # только домен vpn
#   check-knowledge-freshness.sh vpn --json             # вывод в JSON для парсера
#   check-knowledge-freshness.sh vpn --stale-only       # только просроченные
#
# Exit codes:
#   0 — все файлы свежие (нет просроченных в указанном домене).
#   1 — есть просроченные файлы (вывод в stdout: список путей).
#   2 — ошибка (нет knowledge-папки, нет fronтmatter, и т.п.).

set -u

DOMAIN_FILTER="${1:-}"
OUTPUT_FORMAT="human"     # human | json
STALE_ONLY="false"

# Парсинг аргументов
shift_count=0
for arg in "$@"; do
    case "$arg" in
        --json) OUTPUT_FORMAT="json" ;;
        --stale-only) STALE_ONLY="true" ;;
        --domain=*) DOMAIN_FILTER="${arg#--domain=}" ;;
    esac
done

# Локализация: SYSADMIN_ROOT (определяем сами, не полагаемся на helper find-config)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SYSADMIN_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
KNOWLEDGE_ROOT="$SYSADMIN_ROOT/.claude/knowledge"

if [ ! -d "$KNOWLEDGE_ROOT" ]; then
    echo "ERROR: $KNOWLEDGE_ROOT не существует" >&2
    exit 2
fi

# Кросс-платформенный парсер даты ISO-8601 → epoch
parse_date_to_epoch() {
    local date_str="$1"
    # GNU date (Linux)
    date -u -d "$date_str" +%s 2>/dev/null && return 0
    # BSD date (macOS)
    date -u -j -f "%Y-%m-%d" "$date_str" +%s 2>/dev/null && return 0
    # Не удалось
    echo "0"
    return 1
}

NOW_EPOCH=$(date -u +%s)
RESULTS_HUMAN=""
RESULTS_JSON="["
FIRST_JSON=true
STALE_COUNT=0
TOTAL_COUNT=0
ERROR_COUNT=0

# Идём по всем markdown-файлам в knowledge/
while IFS= read -r -d '' file; do
    # Проверка: есть ли frontmatter?
    if ! head -1 "$file" | grep -q "^---$"; then
        continue   # файл без frontmatter — это не tracked knowledge, пропускаем тихо
    fi

    # Извлекаем frontmatter (между первыми двумя ---)
    fm=$(awk '/^---$/{c++; next} c==1{print} c==2{exit}' "$file")

    # Парсим поля
    domain=$(echo "$fm" | grep -E '^knowledge_domain:' | sed -E 's/^knowledge_domain:[[:space:]]*//')
    last_researched=$(echo "$fm" | grep -E '^last_researched:' | sed -E 's/^last_researched:[[:space:]]*//')
    ttl_days=$(echo "$fm" | grep -E '^ttl_days:' | sed -E 's/^ttl_days:[[:space:]]*//')

    # Если нет ни одного из обязательных полей — это не tracked knowledge
    if [ -z "$domain" ] && [ -z "$last_researched" ] && [ -z "$ttl_days" ]; then
        continue
    fi

    # Применяем domain-фильтр
    if [ -n "$DOMAIN_FILTER" ] && [ "$domain" != "$DOMAIN_FILTER" ]; then
        continue
    fi

    TOTAL_COUNT=$((TOTAL_COUNT + 1))

    # Валидация обязательных полей
    if [ -z "$domain" ] || [ -z "$last_researched" ] || [ -z "$ttl_days" ]; then
        ERROR_COUNT=$((ERROR_COUNT + 1))
        echo "WARN: $file имеет неполный frontmatter (нет одного из: knowledge_domain/last_researched/ttl_days)" >&2
        continue
    fi

    # Вычисляем возраст
    last_epoch=$(parse_date_to_epoch "$last_researched")
    if [ "$last_epoch" = "0" ]; then
        ERROR_COUNT=$((ERROR_COUNT + 1))
        echo "WARN: $file: некорректная дата last_researched=$last_researched" >&2
        continue
    fi
    age_days=$(( (NOW_EPOCH - last_epoch) / 86400 ))

    # Свежий или просроченный?
    is_stale="false"
    if [ "$age_days" -gt "$ttl_days" ]; then
        is_stale="true"
        STALE_COUNT=$((STALE_COUNT + 1))
    fi

    # Skip если просили только stale
    if [ "$STALE_ONLY" = "true" ] && [ "$is_stale" = "false" ]; then
        continue
    fi

    # Накапливаем результат
    rel_path="${file#$SYSADMIN_ROOT/}"

    if [ "$OUTPUT_FORMAT" = "json" ]; then
        if [ "$FIRST_JSON" = "true" ]; then
            FIRST_JSON=false
        else
            RESULTS_JSON+=","
        fi
        RESULTS_JSON+="{\"file\":\"$rel_path\",\"domain\":\"$domain\",\"last_researched\":\"$last_researched\",\"ttl_days\":$ttl_days,\"age_days\":$age_days,\"is_stale\":$is_stale}"
    else
        if [ "$is_stale" = "true" ]; then
            RESULTS_HUMAN+="⚠️  $rel_path — last_researched: $last_researched (возраст $age_days дней, TTL $ttl_days)"$'\n'
        else
            RESULTS_HUMAN+="✅ $rel_path — last_researched: $last_researched (возраст $age_days дней, TTL $ttl_days)"$'\n'
        fi
    fi
done < <(find "$KNOWLEDGE_ROOT" -name "*.md" -type f -print0)

RESULTS_JSON+="]"

# Вывод
if [ "$OUTPUT_FORMAT" = "json" ]; then
    echo "$RESULTS_JSON"
else
    if [ -z "$RESULTS_HUMAN" ]; then
        if [ -n "$DOMAIN_FILTER" ]; then
            echo "Нет tracked knowledge-файлов в домене '$DOMAIN_FILTER'."
        else
            echo "Нет tracked knowledge-файлов с frontmatter (knowledge_domain/last_researched/ttl_days)."
        fi
    else
        echo "$RESULTS_HUMAN"
        echo "Итого: $TOTAL_COUNT файлов, $STALE_COUNT просроченных, $ERROR_COUNT с ошибками."
    fi
fi

# Exit code
[ "$ERROR_COUNT" -gt 0 ] && exit 2
[ "$STALE_COUNT" -gt 0 ] && exit 1
exit 0
