#!/usr/bin/env bash
# rotate-db-password.sh — параметризованная ротация пароля БД (PG/MySQL/Redis).
#
# Использование (значения после `--` — ПРИМЕР, замените своими):
#   bash rotate-db-password.sh \
#       --type postgres \
#       --server <user>@<your-server> \
#       --container postgres \
#       --role myapp \
#       --env-files /opt/myapp/.env,/opt/shared-db/.env \
#       --consumer-dirs /opt/myapp,/opt/myapi \
#       --var-name POSTGRES_PASSWORD \
#       --secret-name postgres-myapp
#
# Логика:
#   1. Сгенерировать новый пароль
#   2. ALTER USER в БД
#   3. sed по всем .env файлам
#   4. docker compose restart всех потребителей
#   5. Verify: новый пароль работает, старый — нет

set -euo pipefail

TYPE=""
SERVER=""
CONTAINER=""
ROLE=""
ENV_FILES=""
CONSUMER_DIRS=""
VAR_NAME=""
SECRET_NAME=""
OLD=""

while [ $# -gt 0 ]; do
    case "$1" in
        --type) TYPE="$2"; shift 2 ;;
        --server) SERVER="$2"; shift 2 ;;
        --container) CONTAINER="$2"; shift 2 ;;
        --role) ROLE="$2"; shift 2 ;;
        --env-files) ENV_FILES="$2"; shift 2 ;;
        --consumer-dirs) CONSUMER_DIRS="$2"; shift 2 ;;
        --var-name) VAR_NAME="$2"; shift 2 ;;
        --secret-name) SECRET_NAME="$2"; shift 2 ;;
        --old) OLD="$2"; shift 2 ;;
        *) echo "Неизвестный аргумент: $1"; exit 2 ;;
    esac
done

for required in TYPE SERVER CONTAINER ROLE ENV_FILES CONSUMER_DIRS VAR_NAME SECRET_NAME; do
    if [ -z "${!required}" ]; then
        echo "Отсутствует --${required,,}"
        exit 2
    fi
done

# 1. Сгенерировать новый пароль
NEW=$(openssl rand -base64 32 | tr -d '+/=' | head -c 32)
echo "[1/5] Сгенерирован новый пароль (длина: ${#NEW})"

# 2. ALTER USER
echo "[2/5] ALTER USER на $SERVER ($CONTAINER)..."
case "$TYPE" in
    postgres)
        ssh "$SERVER" "docker exec $CONTAINER psql -U postgres \
            -c \"ALTER USER $ROLE WITH PASSWORD '$NEW'\""
        ;;
    mysql)
        ssh "$SERVER" "docker exec $CONTAINER mysql -u root \
            -e \"ALTER USER '$ROLE'@'%' IDENTIFIED BY '$NEW'; FLUSH PRIVILEGES;\""
        ;;
    redis)
        ssh "$SERVER" "docker exec $CONTAINER redis-cli CONFIG SET requirepass '$NEW'"
        ;;
    *)
        echo "Неизвестный тип: $TYPE (ожидаю postgres|mysql|redis)"
        exit 2
        ;;
esac

# 3. Обновить все .env файлы
echo "[3/5] Подменяем $VAR_NAME во всех .env..."
IFS=',' read -ra FILES <<< "$ENV_FILES"
for env_file in "${FILES[@]}"; do
    ssh "$SERVER" "sed -i.bak 's|^${VAR_NAME}=.*|${VAR_NAME}=${NEW}|' '$env_file'"
    echo "  ✓ $env_file"
done

# 4. Restart всех потребителей
echo "[4/5] Restart потребителей..."
IFS=',' read -ra DIRS <<< "$CONSUMER_DIRS"
for dir in "${DIRS[@]}"; do
    ssh "$SERVER" "cd '$dir' && docker compose restart"
    echo "  ✓ $dir restarted"
done

# Подождать прогрева (особенно важно для PG)
sleep 5

# 5. Verify
echo "[5/5] Verify..."
case "$TYPE" in
    postgres)
        if ssh "$SERVER" "PGPASSWORD='$NEW' psql -h 127.0.0.1 -U $ROLE -d $ROLE -c 'SELECT 1' >/dev/null 2>&1"; then
            echo "  ✓ Новый пароль работает"
        else
            echo "  ✗ Новый пароль НЕ работает — RUSH ROLLBACK"
            exit 3
        fi
        if [ -n "$OLD" ]; then
            if ssh "$SERVER" "PGPASSWORD='$OLD' psql -h 127.0.0.1 -U $ROLE -d $ROLE -c 'SELECT 1' >/dev/null 2>&1"; then
                echo "  ✗ Старый пароль ВСЁ ЕЩЁ работает — расследуй"
            else
                echo "  ✓ Старый пароль не работает"
            fi
        fi
        ;;
    *)
        echo "  (verify для $TYPE — реализуй вручную)"
        ;;
esac

echo ""
echo "=== Ротация завершена ==="
echo "Следующие шаги вручную:"
echo "  1. Сохрани новый пароль в менеджере паролей под ключом ${SECRET_NAME}"
echo "  2. Удали старый ${SECRET_NAME}-old после 24 часов наблюдения"
echo "  3. Обнови inventory/shared/access.md (последняя ротация = сегодня)"
echo "  4. Создай incidents/$(date +%Y-%m-%d)-rotate-${SECRET_NAME}.md"
echo ""
echo "Новый пароль (запиши в менеджер паролей и удали из истории терминала):"
echo "  $NEW"