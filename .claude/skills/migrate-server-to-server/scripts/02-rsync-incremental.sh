#!/usr/bin/env bash
# 02-rsync-incremental.sh — инкрементальный rsync Docker-volumes между серверами.
#
# Стратегия 3 шагов:
#   День 1: первый полный rsync (старые сервисы ещё работают, ~много данных)
#   День 2: второй rsync (только delta, обычно секунды-минуты)
#   День 3: cutover — stop старых → финальный delta → start новых → DNS switch
#
# Использование:
#   bash 02-rsync-incremental.sh user@old.vps.com user@new.vps.com [день1|день2|cutover]
#
# Скрипт идемпотентен — каждый запуск даёт текущий delta, можно прогонять
# несколько раз подряд без вреда.

set -euo pipefail

OLD_SERVER="${1:-}"
NEW_SERVER="${2:-}"
PHASE="${3:-день1}"

if [ -z "$OLD_SERVER" ] || [ -z "$NEW_SERVER" ]; then
    echo "Использование: $0 user@old.vps.com user@new.vps.com [день1|день2|cutover]"
    exit 2
fi

TS=$(date +%Y%m%d-%H%M%S)
LINK_DEST=""
if [ "$PHASE" != "день1" ]; then
    # Для день2/cutover используем предыдущий снапшот для hardlink dedupe
    PREV=$(ssh "$NEW_SERVER" "ls -d /var/lib/docker/volumes.snapshot-* 2>/dev/null | tail -1" || true)
    if [ -n "$PREV" ]; then
        LINK_DEST="--link-dest=$PREV"
    fi
fi

echo "=== Rsync ($PHASE): $OLD_SERVER → $NEW_SERVER ==="

case "$PHASE" in
    день1)
        echo "[Полный rsync — может занять часы для больших volumes]"
        rsync -avz --progress \
            --rsync-path="sudo rsync" \
            "$OLD_SERVER":/var/lib/docker/volumes/ \
            "$NEW_SERVER":/var/lib/docker/volumes/
        ;;
    день2)
        echo "[Delta rsync — обычно секунды-минуты]"
        rsync -avz --progress --delete $LINK_DEST \
            --rsync-path="sudo rsync" \
            "$OLD_SERVER":/var/lib/docker/volumes/ \
            "$NEW_SERVER":/var/lib/docker/volumes/
        ;;
    cutover)
        echo "[Финальный rsync с предварительным stop сервисов на старом]"
        echo "ВНИМАНИЕ: этот шаг останавливает сервисы на старом сервере."
        echo "Подтверди что готов к downtime, нажми Enter..."
        read -r

        # Stop сервисов на старом — НЕ down, чтобы был быстрый откат
        ssh "$OLD_SERVER" "
            for compose in /opt/*/docker-compose.yml; do
                cd \$(dirname \$compose) && docker compose stop || true
            done
        "

        # Финальный delta
        rsync -avz --progress --delete $LINK_DEST \
            --rsync-path="sudo rsync" \
            "$OLD_SERVER":/var/lib/docker/volumes/ \
            "$NEW_SERVER":/var/lib/docker/volumes/

        echo ""
        echo "=== Финальный rsync завершён ==="
        echo "Следующий шаг — bash 03-cutover.sh $NEW_SERVER"
        ;;
    *)
        echo "Неизвестная фаза: $PHASE"
        echo "Допустимо: день1 / день2 / cutover"
        exit 2
        ;;
esac

echo "=== Готово ($PHASE) ==="