#!/usr/bin/env bash
# 02-ufw-setup.sh — ставит и настраивает UFW: deny incoming + allow outgoing,
# открывает SSH, 80, 443. Идемпотентный.
#
# Запуск (через sudo):
#   SSH_PORT=22 sudo -E bash 02-ufw-setup.sh

set -euo pipefail

: "${SSH_PORT:=22}"

echo "[02-ufw] SSH_PORT=$SSH_PORT"

# --- 1. Установка ufw (если нет) ---
if ! command -v ufw &>/dev/null; then
    echo "[02] Устанавливаю ufw"
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y ufw
else
    echo "[02] ufw уже установлен"
fi

# --- 2. Default policies ---
ufw --force default deny incoming
ufw --force default allow outgoing

# --- 3. Открыть SSH-порт ---
# `ufw allow`, НЕ `ufw limit`. Защиту от brute-force держит fail2ban (шаг 03,
# jail sshd, maxretry=5) — он умнее: банит по НЕУДАЧНЫМ логинам из auth.log, а не
# по частоте новых TCP-коннектов. `ufw limit` (6+ коннектов/30 сек → блок 30 сек)
# режет ЛЕГИТИМНУЮ работу: пачки SSH-подключений при автоматизации/деплое/миграции
# ловят самобан (боевая находка 2026-07-09 — прямой Mac→сервер рвался
# `Connection closed`/`timed out`, хотя fail2ban был чист). Дублировать оба слоя
# нет смысла: fail2ban покрывает brute-force, UFW-лимит только мешает.
ufw allow "${SSH_PORT}/tcp" comment 'SSH (brute-force защита — fail2ban, шаг 03)'

# --- 4. HTTP/HTTPS ---
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'

# --- 5. Активировать (если не активно) ---
if ufw status | grep -q "Status: inactive"; then
    echo "[02] Активирую ufw"
    ufw --force enable
else
    echo "[02] ufw уже активен — перезагружаю правила"
    ufw --force reload
fi

# --- 6. Verify ---
echo ""
echo "[02] Текущие правила UFW:"
ufw status verbose
echo ""
echo "[02] OK — UFW активен, SSH/${SSH_PORT}, 80, 443 открыты, остальное закрыто."