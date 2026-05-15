#!/usr/bin/env bash
# 04-ufw-setup.sh — настройка UFW: открыть PANEL_PORT, опционально 443
# (для VLESS inbound в `LOCATION=foreign-server` сценарии).
#
# Логика:
#  - Открыть PANEL_PORT/tcp (всегда).
#  - При LOCATION=foreign-server открыть 443/tcp (для VLESS+Reality inbound).
#  - Закрыть 80, если был временно открыт под acme HTTP-01 (acme-standalone).
#    Если TLS_METHOD=acme-cloudflare — 80 не трогаем (он мог быть нужен для других целей).
#
# Вход через ENV:
#   SSH_TARGET             — SSH-цель
#   PANEL_PORT             — порт панели
#   LOCATION               — ru-server | foreign-server
#   TLS_METHOD             — acme-standalone | acme-cloudflare | certbot
#
# Выход:
#   0 — UFW настроен
#   1 — ошибка

set -euo pipefail

SSH_TARGET="${SSH_TARGET:?SSH_TARGET обязателен}"
PANEL_PORT="${PANEL_PORT:?PANEL_PORT обязателен}"
LOCATION="${LOCATION:-ru-server}"
TLS_METHOD="${TLS_METHOD:-acme-standalone}"

echo "[ufw] Настройка UFW на $SSH_TARGET..."

# shellcheck disable=SC2087  # client-side expansion намеренная
ssh "$SSH_TARGET" bash <<REMOTE_EOF
set -e

if ! command -v ufw >/dev/null 2>&1; then
    echo "[ufw] UFW не установлен, пропускаю настройку (firewall настраивается отдельно)"
    exit 0
fi

# Открываем порт панели
ufw allow ${PANEL_PORT}/tcp comment '3x-ui panel'

# Условно открываем 443 для VLESS inbound (только foreign-server)
if [ "${LOCATION}" = "foreign-server" ]; then
    ufw allow 443/tcp comment 'vless reality inbound'
fi

# 80 — закрываем, если выпуск через standalone HTTP-01 закончен,
# 80 не нужен для регулярной работы панели (acme renew также делает временное открытие)
if [ "${TLS_METHOD}" = "acme-standalone" ] || [ "${TLS_METHOD}" = "certbot" ]; then
    # Удаляем правило, если оно было
    ufw delete allow 80/tcp 2>/dev/null || true
fi

ufw reload
ufw status verbose
REMOTE_EOF

echo "[ufw] Готово."
exit 0
