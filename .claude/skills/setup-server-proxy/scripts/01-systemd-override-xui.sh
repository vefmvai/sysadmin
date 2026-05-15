#!/bin/bash
# 01-systemd-override-xui.sh — drop-in override для x-ui.service.
#
# КРИТИЧЕСКИЙ ШАГ. Делается ПЕРВЫМ, до записи /etc/environment.
# Без этого override панель и Xray уходят в петлю при попытке
# использовать собственный mixed inbound как HTTPS_PROXY (см. 3x-ui-panel.md §7.7).
#
# Drop-in override очищает прокси-переменные только для юнита x-ui,
# оставляя /etc/environment глобальным для пользовательских сессий
# и программ.
#
# Вход через ENV:
#   SSH_TARGET — SSH-цель

set -euo pipefail

SSH_TARGET="${SSH_TARGET:?SSH_TARGET обязателен}"

echo "[xui-override] Создаю drop-in override для x-ui.service на $SSH_TARGET..."

ssh "$SSH_TARGET" bash <<'REMOTE_EOF'
set -e

OVERRIDE_DIR="/etc/systemd/system/x-ui.service.d"
OVERRIDE_FILE="$OVERRIDE_DIR/override.conf"

# Проверка, что x-ui.service существует
if ! systemctl list-unit-files | grep -q '^x-ui\.service'; then
    echo "ERROR: x-ui.service не найден — панель 3X-UI не установлена?" >&2
    exit 1
fi

mkdir -p "$OVERRIDE_DIR"

# Идемпотентно: переписываем override.conf
cat > "$OVERRIDE_FILE" <<'OVERRIDE_CONTENT'
# Drop-in override для x-ui.service — защита от self-loop через
# /etc/environment HTTP_PROXY/HTTPS_PROXY.
#
# Без этого override установка серверного прокси (mixed inbound на 127.0.0.1:1080)
# приводит к падению панели: Go-процессы x-ui и xray уважают HTTP_PROXY из
# /etc/environment, что создаёт петлю x-ui → http_proxy → 127.0.0.1:1080
# (тот же x-ui) → ... → INVALIDARGUMENT.
#
# Управляется скиллом /setup-server-proxy (sysadmin). Не править вручную.

[Service]
Environment="HTTP_PROXY="
Environment="HTTPS_PROXY="
Environment="NO_PROXY=*"
OVERRIDE_CONTENT

chmod 644 "$OVERRIDE_FILE"

# Применяем
systemctl daemon-reload
systemctl restart x-ui

# Проверяем, что x-ui всё ещё активен
sleep 3
if ! systemctl is-active --quiet x-ui; then
    echo "ERROR: x-ui не стартует после override" >&2
    journalctl -u x-ui --no-pager -n 20 >&2
    exit 1
fi

echo "[xui-override] OK: override применён, x-ui активен"
ls -la "$OVERRIDE_FILE"
REMOTE_EOF

echo "[xui-override] Готово."
exit 0
