#!/usr/bin/env bash
# 03-fail2ban.sh — ставит fail2ban и настраивает jail для sshd.
# Идемпотентный — повторный запуск не дублирует jail.
#
# Запуск (через sudo):
#   SSH_PORT=22 sudo -E bash 03-fail2ban.sh

set -euo pipefail

: "${SSH_PORT:=22}"

echo "[03-fail2ban] SSH_PORT=$SSH_PORT"

# --- 1. Установка fail2ban ---
if ! command -v fail2ban-client &>/dev/null; then
    echo "[03] Устанавливаю fail2ban"
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban
else
    echo "[03] fail2ban уже установлен"
fi

# --- 2. Создать /etc/fail2ban/jail.local (если нет) ---
JAIL_LOCAL="/etc/fail2ban/jail.local"

cat > "$JAIL_LOCAL" <<EOF
# jail.local — переопределения для дефолтного jail.conf.
# Изменения здесь не затираются обновлениями пакета fail2ban.

[DEFAULT]
# Глобальные настройки бана
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

# Локальные сети, которые НЕ банятся
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port    = ${SSH_PORT}
filter  = sshd
logpath = %(sshd_log)s
backend = %(sshd_backend)s
maxretry = 5
bantime  = 1h
EOF

echo "[03] Создан/обновлён $JAIL_LOCAL"

# --- 3. Запустить и enable ---
systemctl enable fail2ban
systemctl restart fail2ban

# Подождать пока fail2ban поднимется (до 5 секунд)
for _ in 1 2 3 4 5; do
    if fail2ban-client ping &>/dev/null; then
        break
    fi
    sleep 1
done

# --- 4. Verify ---
echo ""
echo "[03] Статус fail2ban-client:"
fail2ban-client status
echo ""
echo "[03] Статус jail sshd:"
fail2ban-client status sshd || {
    echo "[03] ВНИМАНИЕ: jail sshd не запустился — проверь /var/log/fail2ban.log"
    exit 1
}
echo ""
echo "[03] OK — fail2ban активен, jail sshd слушает порт ${SSH_PORT}."