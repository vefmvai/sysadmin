#!/usr/bin/env bash
# configure-beszel-pair.sh — первичная настройка Beszel hub + сопряжение с agent
#
# Использование:
#   BESZEL_USER_EMAIL=admin@local BESZEL_USER_PASS=... \
#   ./configure-beszel-pair.sh
#
# Принципы:
# - Beszel hub при первом старте требует UI для создания учётки. Скрипт обходит это,
#   вставляя bcrypt-хэш напрямую в SQLite-базу (data.db).
# - SSH-ключ для пары hub→agent генерируется ssh-keygen и подставляется в .env beszel-agent.
#
# Структура данных Beszel (упрощённо):
#   data.db: таблица users (id, email, password_hash, role, ...)
#                    user_settings (id, user_id, notificationURLs, ...)

set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/monitoring}"
BESZEL_DATA="${INSTALL_DIR}/beszel_data"
BESZEL_AGENT_DATA="${INSTALL_DIR}/beszel_agent_data"
BESZEL_USER_EMAIL="${BESZEL_USER_EMAIL:?Set BESZEL_USER_EMAIL}"
BESZEL_USER_PASS="${BESZEL_USER_PASS:?Set BESZEL_USER_PASS}"

# 1. Проверяем, что hub запущен и data.db существует
if [ ! -f "$BESZEL_DATA/data.db" ]; then
    echo "ERROR: $BESZEL_DATA/data.db не найден. Сначала подними hub: docker compose -f beszel.yml up -d" >&2
    exit 1
fi

# 2. Генерируем bcrypt-хэш пароля
# Используем htpasswd -nbB (bcrypt) — формат вывода `user:hash`
BCRYPT_HASH=$(htpasswd -nbB "$BESZEL_USER_EMAIL" "$BESZEL_USER_PASS" | cut -d: -f2-)
if [ -z "$BCRYPT_HASH" ]; then
    echo "ERROR: htpasswd не сгенерировал хэш (поставь apache2-utils)" >&2
    exit 1
fi

# 3. Останавливаем hub перед UPDATE в SQLite (избегаем write-conflict)
docker compose -f "$INSTALL_DIR/beszel.yml" stop beszel

# 4. UPDATE первичной учётки в SQLite
# Если пользователь уже существует — обновляем хэш; иначе вставляем
sqlite3 "$BESZEL_DATA/data.db" <<SQL
INSERT INTO users (email, password, role, created, updated)
VALUES ('$BESZEL_USER_EMAIL', '$BCRYPT_HASH', 'admin', strftime('%s', 'now'), strftime('%s', 'now'))
ON CONFLICT(email) DO UPDATE SET password = '$BCRYPT_HASH', updated = strftime('%s', 'now');
SQL

echo "OK: первичная учётка $BESZEL_USER_EMAIL установлена в SQLite"

# 5. Запускаем hub обратно
docker compose -f "$INSTALL_DIR/beszel.yml" start beszel

# 6. Генерируем SSH-ключ для пары hub→agent (если ещё нет)
KEY_FILE="$BESZEL_AGENT_DATA/agent.key"
mkdir -p "$BESZEL_AGENT_DATA"
if [ ! -f "$KEY_FILE" ]; then
    ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "beszel-agent@$(hostname)"
    chmod 600 "$KEY_FILE"
    echo "OK: SSH-ключ сгенерирован: $KEY_FILE"
else
    echo "INFO: SSH-ключ уже существует: $KEY_FILE"
fi

PUBLIC_KEY=$(cat "${KEY_FILE}.pub")

# 7. Записываем PUBLIC_KEY в .env beszel-agent (для подстановки в KEY=...)
ENV_FILE="$INSTALL_DIR/.env"
if grep -q '^BESZEL_KEY=' "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^BESZEL_KEY=.*|BESZEL_KEY=\"$PUBLIC_KEY\"|" "$ENV_FILE"
else
    echo "BESZEL_KEY=\"$PUBLIC_KEY\"" >> "$ENV_FILE"
fi
echo "OK: BESZEL_KEY записан в $ENV_FILE"

# 8. Перезапускаем agent с новым ключом
docker compose -f "$INSTALL_DIR/beszel.yml" up -d beszel-agent

echo ""
echo "=== Сопряжение завершено ==="
echo "Hub:    http://localhost:8090/"
echo "Agent:  слушает на 127.0.0.1:45876"
echo "PUBLIC KEY (зарегистрировать в Hub UI → System → Add Agent):"
echo "  $PUBLIC_KEY"
echo ""
echo "Если автоматическая регистрация через API не сработала — добавь agent в Hub UI:"
echo "  Settings → Systems → Add System → public key выше → host=localhost → port=45876"