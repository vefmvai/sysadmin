#!/usr/bin/env bash
# .claude/skills/cleanup-existing-server/scripts/cleanup-categories.sh
#
# Анализатор snapshot inventory-scan: формирует список кандидатов по 5 категориям
# чистки. Read-only — НЕ применяет изменения, только показывает что бы он сделал.
#
# Использование:
#   bash cleanup-categories.sh [SNAPSHOT_DIR] [CATEGORIES]
#
# Примеры:
#   bash cleanup-categories.sh                                    # сегодняшний snapshot, all
#   bash cleanup-categories.sh inventory/hosts/prod-X/snapshots/2026-04-25
#   bash cleanup-categories.sh "" names,permissions               # только две категории
#
# Категории:
#   names           — контейнеры с автогенерируемыми именами
#   permissions     — .env с mode 0644 (должно 0600)
#   drift           — sites-available vs sites-enabled расхождения
#   dead-configs    — nginx server-блоки без живого DNS
#   memory-limits   — контейнеры без mem_limit
#   all             — все 5

set -euo pipefail

SNAPSHOT_DIR="${1:-}"
CATEGORIES="${2:-all}"

# === Найти свежий snapshot, если не указан ===
if [ -z "$SNAPSHOT_DIR" ]; then
    SNAPSHOT_DIR=$(find inventory/hosts/*/snapshots/ -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
        | sort | tail -1)
    if [ -z "$SNAPSHOT_DIR" ]; then
        echo "ОШИБКА: snapshot не найден. Запусти сначала inventory-scan."
        exit 1
    fi
    echo "Использую свежий snapshot: $SNAPSHOT_DIR"
fi

# === Проверка возраста snapshot ===
SNAP_AGE_H=$(( ($(date +%s) - $(date -r "$SNAPSHOT_DIR" +%s 2>/dev/null || echo 0)) / 3600 ))
if [ "$SNAP_AGE_H" -gt 24 ]; then
    echo "ПРЕДУПРЕЖДЕНИЕ: snapshot старше 24 часов (возраст ${SNAP_AGE_H}ч)."
    echo "Рекомендую запустить inventory-scan заново перед cleanup."
fi

echo "======================================================"
echo "cleanup-categories.sh — анализ кандидатов"
echo "Snapshot:   $SNAPSHOT_DIR"
echo "Категории:  $CATEGORIES"
echo "======================================================"
echo ""

run_category() {
    local cat="$1"
    if [ "$CATEGORIES" = "all" ] || echo ",$CATEGORIES," | grep -q ",$cat,"; then
        return 0
    fi
    return 1
}

# === Категория: names ===
if run_category "names"; then
    echo "--- NAMES: контейнеры с автогенерируемыми именами ---"
    if [ -f "$SNAPSHOT_DIR/containers.txt" ]; then
        # Имена вида project-service-N (где N = число) — кандидаты
        grep -E '^\S+-\S+-[0-9]+\s' "$SNAPSHOT_DIR/containers.txt" \
            | awk '{print "  -", $1}' \
            || echo "  кандидатов не найдено"
    else
        echo "  ? уточнить — containers.txt отсутствует в snapshot"
    fi
    echo ""
fi

# === Категория: permissions ===
if run_category "permissions"; then
    echo "--- PERMISSIONS: .env с mode 0644 (должно 0600) ---"
    if [ -f "$SNAPSHOT_DIR/host-env-redacted.txt" ]; then
        # Парсим строки вида "644 user:group N bytes modified ..."
        grep -B1 -E '^644\s' "$SNAPSHOT_DIR/host-env-redacted.txt" \
            | grep -E '^=== ' \
            | sed 's/^=== \(.*\) ===$/  - \1 (mode 0644)/' \
            || echo "  кандидатов не найдено"
    else
        echo "  ? уточнить — host-env-redacted.txt отсутствует в snapshot"
    fi
    echo ""
fi

# === Категория: drift ===
if run_category "drift"; then
    echo "--- DRIFT: sites-available vs sites-enabled расхождения ---"
    if [ -f "$SNAPSHOT_DIR/nginx-sites.txt" ]; then
        # Эта проверка лучше работает через прямой осмотр сервера,
        # snapshot даёт только nginx -T (effective config).
        echo "  Полная диагностика — на сервере:"
        echo "    diff <(ls /etc/nginx/sites-enabled/) <(ls /etc/nginx/sites-available/)"
        echo "    for f in /etc/nginx/sites-enabled/*; do"
        echo "      [ -L \"\$f\" ] || echo \"  - \$f не является симлинком (drift)\""
        echo "    done"
    else
        echo "  ? уточнить — nginx-sites.txt отсутствует"
    fi
    echo ""
fi

# === Категория: dead-configs ===
if run_category "dead-configs"; then
    echo "--- DEAD-CONFIGS: nginx server-блоки без живого DNS ---"
    if [ -f "$SNAPSHOT_DIR/nginx-sites.txt" ]; then
        # Все server_name из эффективной конфигурации
        SERVER_NAMES=$(grep -E '^\s*server_name\s' "$SNAPSHOT_DIR/nginx-sites.txt" 2>/dev/null \
            | awk '{for (i=2; i<=NF; i++) print $i}' \
            | tr -d ';' | sort -u)
        if [ -n "$SERVER_NAMES" ]; then
            echo "  Найдено server_name: $(echo "$SERVER_NAMES" | wc -l) штук"
            echo "  Сверка с DNS — ручная или через scripts/check-dns.sh:"
            echo "$SERVER_NAMES" | head -20 | sed 's/^/    /'
        else
            echo "  server_name директивы не найдены"
        fi
    else
        echo "  ? уточнить — nginx-sites.txt отсутствует"
    fi
    echo ""
fi

# === Категория: memory-limits ===
if run_category "memory-limits"; then
    echo "--- MEMORY-LIMITS: контейнеры без mem_limit ---"
    if [ -f "$SNAPSHOT_DIR/containers-inspect.json" ]; then
        # HostConfig.Memory == 0 значит нет лимита
        if command -v jq >/dev/null 2>&1; then
            jq -r '.[] | select(.HostConfig.Memory == 0) | "  - \(.Name)"' \
                "$SNAPSHOT_DIR/containers-inspect.json" 2>/dev/null \
                | sed 's|/||' \
                | head -30 \
                || echo "  кандидатов не найдено"
        else
            echo "  ? уточнить — jq не установлен, парсинг пропущен"
        fi
    else
        echo "  ? уточнить — containers-inspect.json отсутствует"
    fi
    echo ""
fi

echo "======================================================"
echo "Готово. Это read-only анализ — изменений на сервере НЕ внесено."
echo "Следующий шаг: брифинг 6 пунктов на каждую категорию + подтверждение."
echo "======================================================"