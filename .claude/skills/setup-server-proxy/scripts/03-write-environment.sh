#!/bin/bash
# 03-write-environment.sh — записать прокси-переменные в /etc/environment.
#
# ВАЖНО: запускается ПОСЛЕ 01-systemd-override-xui.sh. Иначе панель падает
# в петлю (см. 3x-ui-panel.md §7.7).
#
# socks5h:// (с буквой h) — обязательно. Без 'h' DNS-резолвинг идёт на клиенте,
# что даёт DNS-leak и Anthropic API возвращает 403 (см. vpn-protocols.md §5.2).
#
# Вход через ENV:
#   SSH_TARGET — SSH-цель
#   PROXY_PORT (default: 1080)

set -euo pipefail

SSH_TARGET="${SSH_TARGET:?SSH_TARGET обязателен}"
PROXY_PORT="${PROXY_PORT:-1080}"

# Защита: проверяем, что override уже на месте
OVERRIDE_CHECK="$(ssh "$SSH_TARGET" "test -f /etc/systemd/system/x-ui.service.d/override.conf && echo PRESENT || echo MISSING")"

if [ "$OVERRIDE_CHECK" = "MISSING" ]; then
    echo "ERROR: drop-in override для x-ui НЕ найден" >&2
    echo "ERROR: запусти сначала 01-systemd-override-xui.sh — иначе панель упадёт" >&2
    exit 1
fi

echo "[env] Записываю /etc/environment на $SSH_TARGET..."

# shellcheck disable=SC2087  # PROXY_PORT передаём через client-side substitution
ssh "$SSH_TARGET" bash <<REMOTE_EOF
set -e

ENV_FILE="/etc/environment"
BACKUP="\$ENV_FILE.backup.\$(date +%Y%m%d-%H%M%S)"

cp "\$ENV_FILE" "\$BACKUP"
echo "[env] Бэкап: \$BACKUP"

# Сначала удаляем существующие proxy-строки (idempotent)
sed -i '/^http_proxy=/d; /^https_proxy=/d; /^no_proxy=/d; /^HTTP_PROXY=/d; /^HTTPS_PROXY=/d; /^NO_PROXY=/d' "\$ENV_FILE"

# Добавляем свежие (lowercase И UPPERCASE — разные программы по-разному ищут)
cat >> "\$ENV_FILE" <<ENV_VARS

# proxy-переменные — управляются скиллом /setup-server-proxy (sysadmin).
# 'h' в socks5h — обязательно (DNS-резолвинг на прокси, защита от DNS-leak).
# Не редактировать вручную — изменения через скилл.
http_proxy=socks5h://127.0.0.1:${PROXY_PORT}
https_proxy=socks5h://127.0.0.1:${PROXY_PORT}
no_proxy=localhost,127.0.0.1,::1,.local
HTTP_PROXY=socks5h://127.0.0.1:${PROXY_PORT}
HTTPS_PROXY=socks5h://127.0.0.1:${PROXY_PORT}
NO_PROXY=localhost,127.0.0.1,::1,.local
ENV_VARS

echo "[env] /etc/environment обновлён:"
cat "\$ENV_FILE"
REMOTE_EOF

echo "[env] Готово."
echo "[env] ВАЖНО: переменные применяются при следующем login. Текущая SSH-сессия их не подхватит."
echo "[env] Для применения в текущей сессии — exit + новый ssh, или 'source /etc/environment'."
exit 0
