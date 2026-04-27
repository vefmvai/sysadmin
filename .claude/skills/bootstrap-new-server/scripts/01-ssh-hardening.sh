#!/usr/bin/env bash
# 01-ssh-hardening.sh — создаёт admin-пользователя, ставит SSH-ключ, отключает root-логин и пароли.
# Идемпотентный: можно запускать повторно — пользователь не дублируется, ключ добавляется только если его ещё нет.
#
# Запуск (на свежем сервере под root):
#   ADMIN_USER=deploy SSH_KEY_PUB="ssh-ed25519 AAA... user@host" SSH_PORT=22 bash 01-ssh-hardening.sh
#
# КРИТИЧНО: скрипт НЕ перезапускает sshd. Сначала проверь новый ключ из другого терминала,
# только потом сам сделай `systemctl restart sshd`.

set -euo pipefail

# --- Параметры (через env) ---
: "${ADMIN_USER:?ADMIN_USER required (имя пользователя для не-root доступа)}"
: "${SSH_KEY_PUB:?SSH_KEY_PUB required (содержимое публичного ключа: ssh-ed25519 AAA... comment)}"
: "${SSH_PORT:=22}"

echo "[01-ssh-hardening] ADMIN_USER=$ADMIN_USER  SSH_PORT=$SSH_PORT"

# --- 1. Создать пользователя если не существует ---
if ! id "$ADMIN_USER" &>/dev/null; then
    echo "[01] Создаю пользователя $ADMIN_USER"
    useradd -m -s /bin/bash "$ADMIN_USER"
    usermod -aG sudo "$ADMIN_USER"
    # Чтобы sudo не спрашивал пароль для admin (ОПЦИОНАЛЬНО — закомментировано по умолчанию):
    # echo "$ADMIN_USER ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/90-$ADMIN_USER
    # chmod 440 /etc/sudoers.d/90-$ADMIN_USER
else
    echo "[01] Пользователь $ADMIN_USER уже существует — пропускаю создание"
    # Убеждаемся, что в группе sudo
    usermod -aG sudo "$ADMIN_USER"
fi

# --- 2. Настроить SSH-ключ ---
SSH_DIR="/home/$ADMIN_USER/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

mkdir -p "$SSH_DIR"
touch "$AUTH_KEYS"

# Добавить ключ только если его ещё нет (по последним 32 символам — частичный отпечаток)
KEY_TAIL="${SSH_KEY_PUB: -32}"
if ! grep -qF "$KEY_TAIL" "$AUTH_KEYS" 2>/dev/null; then
    echo "$SSH_KEY_PUB" >> "$AUTH_KEYS"
    echo "[01] SSH-ключ добавлен в $AUTH_KEYS"
else
    echo "[01] SSH-ключ уже есть в $AUTH_KEYS — пропускаю"
fi

chmod 700 "$SSH_DIR"
chmod 600 "$AUTH_KEYS"
chown -R "$ADMIN_USER:$ADMIN_USER" "$SSH_DIR"

# --- 3. Настроить sshd_config (с бэкапом) ---
SSHD_CONFIG="/etc/ssh/sshd_config"

if [ ! -f "${SSHD_CONFIG}.orig" ]; then
    cp "$SSHD_CONFIG" "${SSHD_CONFIG}.orig"
    echo "[01] Бэкап ${SSHD_CONFIG}.orig создан"
fi

# Идемпотентная замена: убираем закомментированные и существующие строки, ставим нужное
sed -i \
    -e 's/^#\?PermitRootLogin.*/PermitRootLogin no/' \
    -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' \
    -e 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' \
    -e "s/^#\?Port .*/Port ${SSH_PORT}/" \
    "$SSHD_CONFIG"

# Если строки Port вообще не было — добавить
if ! grep -qE "^Port " "$SSHD_CONFIG"; then
    echo "Port ${SSH_PORT}" >> "$SSHD_CONFIG"
fi

# --- 4. Verify (НЕ перезагружаем sshd!) ---
sshd -t  # syntax check

cat <<EOF

[01] ============================================================
[01] SSH config обновлён, синтаксис валиден.
[01]
[01] ВНИМАНИЕ: НЕ перезагружай sshd, пока не проверишь новый ключ!
[01]
[01] В НОВОМ терминале выполни:
[01]   ssh -p ${SSH_PORT} ${ADMIN_USER}@<server-ip>
[01]
[01] Если зашло — ТОЛЬКО ПОТОМ выполни на сервере:
[01]   sudo systemctl restart sshd
[01]
[01] После рестарта проверь, что root больше не пускает:
[01]   ssh root@<server-ip>   # должен отвалиться с Permission denied
[01] ============================================================
EOF