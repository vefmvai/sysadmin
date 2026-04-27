#!/usr/bin/env bash
# .claude/skills/cleanup-existing-server/scripts/rename-container-aliases.sh
#
# Two-stage переименование контейнера через aliases
# (паттерн ADR 0011 проекта-носителя или эквивалентное решение).
# Минимизирует простой клиентов: alias добавляется до переименования, старый
# alias оставляем переходным окном пока клиенты не переключатся.
#
# Использование:
#   bash rename-container-aliases.sh <SSH_HOST> <COMPOSE_DIR> <OLD_NAME> <NEW_NAME> <STAGE>
#
# Параметры:
#   SSH_HOST    — <user>@<ip> / SSH-алиас сервера / `local` (выполнить здесь же)
#   COMPOSE_DIR — путь к директории с docker-compose.yml на сервере
#   OLD_NAME    — текущее container_name (например, <project>-postgres-1)
#   NEW_NAME    — целевое имя (например, postgres)
#   STAGE       — 1 | 2 | 3 (см. описание стадий)
#
# Стадии:
#   1 — добавить alias NEW_NAME к контейнеру (без рестарта; Stage 1, ~2 сек)
#   2 — переименовать container_name + service key, оставить старый alias
#       (рестарт контейнера, Stage 2, ~10 сек простоя)
#   3 — убрать старый alias OLD_NAME (Stage 3, когда клиенты переключатся —
#       обычно через 24-72 часа после Stage 2)

set -euo pipefail

if [ $# -lt 5 ]; then
    echo "Использование: $0 <SSH_HOST> <COMPOSE_DIR> <OLD_NAME> <NEW_NAME> <STAGE>"
    echo "Подробности — в шапке скрипта"
    exit 1
fi

SSH_HOST="$1"
COMPOSE_DIR="$2"
OLD_NAME="$3"
NEW_NAME="$4"
STAGE="$5"

if [ "$SSH_HOST" = "local" ]; then
    run_cmd() { eval "$1"; }
else
    run_cmd() { ssh -o ConnectTimeout=10 "$SSH_HOST" "$1"; }
fi

echo "======================================================"
echo "rename-container-aliases.sh — Stage $STAGE"
echo "  SSH:         $SSH_HOST"
echo "  compose dir: $COMPOSE_DIR"
echo "  old name:    $OLD_NAME"
echo "  new name:    $NEW_NAME"
echo "======================================================"

# === Pre-check: контейнер существует ===
if ! run_cmd "docker ps --format '{{.Names}}' | grep -qE '^${OLD_NAME}\$'"; then
    echo "ОШИБКА: контейнер $OLD_NAME не найден на $SSH_HOST"
    exit 1
fi

# === Pre-check: compose-файл существует ===
if ! run_cmd "test -f $COMPOSE_DIR/docker-compose.yml"; then
    echo "ОШИБКА: $COMPOSE_DIR/docker-compose.yml отсутствует на $SSH_HOST"
    exit 1
fi

case "$STAGE" in
    1)
        echo ""
        echo "Stage 1: добавить alias $NEW_NAME к $OLD_NAME"
        echo "  Что делается: docker network connect --alias $NEW_NAME"
        echo "  Простой:      ~2 сек на сеть"
        echo "  Откат:        docker network disconnect"
        echo ""
        # Найти все сети, к которым подключён контейнер
        NETWORKS=$(run_cmd "docker inspect $OLD_NAME --format '{{range \$k,\$v := .NetworkSettings.Networks}}{{\$k}} {{end}}'")
        for net in $NETWORKS; do
            echo "  - сеть $net: переподключаю с alias $NEW_NAME..."
            # docker network connect не позволяет добавить alias к существующему,
            # поэтому disconnect + connect с обоими aliases
            run_cmd "docker network disconnect $net $OLD_NAME && docker network connect --alias $OLD_NAME --alias $NEW_NAME $net $OLD_NAME"
        done
        echo ""
        echo "Stage 1 готов. Проверь: docker exec <client> getent hosts $NEW_NAME"
        ;;

    2)
        echo ""
        echo "Stage 2: переименовать container_name + service key"
        echo "  Что делается: правка docker-compose.yml + recreate"
        echo "  Простой:      ~10 сек"
        echo "  Откат:        вернуть прежнее имя в compose, recreate"
        echo ""
        echo "ВАЖНО: эта стадия требует РУЧНОЙ правки docker-compose.yml"
        echo "       автоматически НЕ выполняется — слишком много вариантов формата."
        echo ""
        echo "Алгоритм правки:"
        echo "  1. В $COMPOSE_DIR/docker-compose.yml:"
        echo "     - service key:    $OLD_NAME -> $NEW_NAME (если совпадает)"
        echo "     - container_name: $OLD_NAME -> $NEW_NAME"
        echo "     - aliases:        оставить и $OLD_NAME (старый), и $NEW_NAME"
        echo "  2. ssh $SSH_HOST 'cd $COMPOSE_DIR && docker compose up -d --no-deps $NEW_NAME'"
        echo "  3. Проверка: docker ps --format '{{.Names}}' | grep $NEW_NAME"
        echo ""
        echo "После завершения проверки — запусти Stage 3 (через 24-72 часа)."
        ;;

    3)
        echo ""
        echo "Stage 3: убрать старый alias $OLD_NAME"
        echo "  Что делается: правка aliases в docker-compose.yml"
        echo "  Простой:      ~10 сек (recreate)"
        echo "  Откат:        вернуть alias обратно"
        echo ""
        echo "ВАЖНО: убедись, что НИ ОДИН клиент больше не использует старый alias."
        echo "       Проверь: grep -r '$OLD_NAME' /opt/*/.env"
        echo ""
        echo "После очистки aliases:"
        echo "  ssh $SSH_HOST 'cd $COMPOSE_DIR && docker compose up -d --no-deps $NEW_NAME'"
        ;;

    *)
        echo "ОШИБКА: STAGE должен быть 1, 2 или 3 (получено: $STAGE)"
        exit 1
        ;;
esac

echo ""
echo "======================================================"
echo "Stage $STAGE отчёт сформирован."
echo "Зафиксируй результат в incidents/YYYY-MM-DD-cleanup-rename-${NEW_NAME}.md"
echo "======================================================"