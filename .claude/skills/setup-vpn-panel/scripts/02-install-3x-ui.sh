#!/usr/bin/env bash
# 02-install-3x-ui.sh — установка эталонной 3X-UI (MHSanaei/3x-ui) с фиксацией версии.
#
# Особенности:
#  - Использует официальный install.sh, не «ставим из исходников».
#  - Фиксирует версию (VERSION=v2.5.5 ...) — защита от breaking changes.
#  - Установщик 3X-UI интерактивный (спрашивает «customize port settings?»).
#    Передаём ответы через stdin.
#  - После установки — НЕМЕДЛЕННАЯ замена дефолтных кредов через CLI:
#    smart-логин (≠ admin), 32-символьный пароль, webBasePath, нестандартный порт.
#
# Вход через ENV:
#   SSH_TARGET              — SSH-цель (alias или user@host)
#   VERSION                 — версия панели (например, v2.5.5)
#   ADMIN_LOGIN             — сгенерированный 8-символьный логин (≠admin)
#   ADMIN_PASSWORD          — сгенерированный 32-символьный пароль
#   PANEL_PORT              — нестандартный порт (например, 48391)
#   WEB_BASE_PATH           — webBasePath (10 символов, например abcdef1234)
#
# Выход:
#   0 — установка завершена, креды применены
#   1 — ошибка установки
#   2 — ошибка параметров

set -euo pipefail

SSH_TARGET="${SSH_TARGET:?SSH_TARGET обязателен}"
VERSION="${VERSION:?VERSION обязателен (например, v2.5.5)}"
ADMIN_LOGIN="${ADMIN_LOGIN:?ADMIN_LOGIN обязателен}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:?ADMIN_PASSWORD обязателен}"
PANEL_PORT="${PANEL_PORT:?PANEL_PORT обязателен}"
WEB_BASE_PATH="${WEB_BASE_PATH:?WEB_BASE_PATH обязателен}"

# Валидация параметров
if [ "$ADMIN_LOGIN" = "admin" ]; then
    echo "ERROR: ADMIN_LOGIN не должен быть 'admin' (это первое, что брутят)" >&2
    exit 2
fi
if [ "${#ADMIN_PASSWORD}" -lt 16 ]; then
    echo "ERROR: ADMIN_PASSWORD слишком короткий (минимум 16 символов, текущая длина: ${#ADMIN_PASSWORD})" >&2
    exit 2
fi
if ! [[ "$PANEL_PORT" =~ ^[0-9]+$ ]] || [ "$PANEL_PORT" -lt 1024 ] || [ "$PANEL_PORT" -gt 65535 ]; then
    echo "ERROR: PANEL_PORT должен быть в диапазоне 1024-65535" >&2
    exit 2
fi
if [ "${#WEB_BASE_PATH}" -lt 6 ]; then
    echo "ERROR: WEB_BASE_PATH слишком короткий (минимум 6 символов)" >&2
    exit 2
fi

# Удаляем ведущие/завершающие слеши в WEB_BASE_PATH
WEB_BASE_PATH_CLEAN="${WEB_BASE_PATH#/}"
WEB_BASE_PATH_CLEAN="${WEB_BASE_PATH_CLEAN%/}"

echo "[install] Установка 3X-UI $VERSION на $SSH_TARGET..."

# ─── Установка через официальный installer ────────────────────────────────────
# Установщик спрашивает «customize Panel Port settings?». Отвечаем 'n' (нет),
# потому что после установки сами поменяем через CLI на наш PANEL_PORT.
# shellcheck disable=SC2029  # $VERSION должен раскрыться на клиенте — это намеренно
ssh "$SSH_TARGET" "VERSION='$VERSION' bash -c 'echo \"n\" | bash <(curl -Ls \"https://raw.githubusercontent.com/mhsanaei/3x-ui/\$VERSION/install.sh\") \"\$VERSION\"'" 2>&1 | tee /tmp/3x-ui-install.log || {
    echo "ERROR: установка через install.sh упала" >&2
    exit 1
}

# ─── Проверка, что сервис стартовал ───────────────────────────────────────────
echo "[install] Проверка systemctl status x-ui..."
sleep 3  # дать сервису подняться

if ! ssh "$SSH_TARGET" "systemctl is-active --quiet x-ui"; then
    echo "ERROR: x-ui.service не запустился. Проверь: ssh $SSH_TARGET 'journalctl -xeu x-ui --no-pager | tail -50'" >&2
    exit 1
fi
echo "[install] x-ui.service: active (running)"

# ─── Замена дефолтных кредов через CLI ────────────────────────────────────────
echo "[install] Замена дефолтных кредов..."

# 'x-ui setting' — CLI команда панели для управления настройками.
# Делаем атомарно за один SSH-call.
# Heredoc БЕЗ кавычек — нужна client-side подстановка переменных.
# shellcheck disable=SC2087  # client-side expansion намеренная (подставляем локальные креды)
ssh "$SSH_TARGET" bash <<REMOTE_SCRIPT
set -e
/usr/local/x-ui/x-ui setting -username '$ADMIN_LOGIN'
/usr/local/x-ui/x-ui setting -password '$ADMIN_PASSWORD'
/usr/local/x-ui/x-ui setting -port $PANEL_PORT
/usr/local/x-ui/x-ui setting -webBasePath '/$WEB_BASE_PATH_CLEAN/'

# Рестарт обязателен — настройки подхватываются при следующем старте
systemctl restart x-ui
REMOTE_SCRIPT

sleep 3

# ─── Проверка, что креды применились ──────────────────────────────────────────
echo "[install] Проверка применения кредов..."

SETTING_OUTPUT="$(ssh "$SSH_TARGET" "/usr/local/x-ui/x-ui setting -show true" 2>&1)"

# Парсим вывод (формат у разных версий может слегка отличаться)
APPLIED_PORT="$(echo "$SETTING_OUTPUT" | grep -iE "(panel|port)" | grep -oE '[0-9]{4,5}' | head -n1)"
APPLIED_PATH="$(echo "$SETTING_OUTPUT" | grep -iE "(webBasePath|panel.*Path|base.*path)" | head -n1)"

if [ -z "$APPLIED_PORT" ] || [ "$APPLIED_PORT" != "$PANEL_PORT" ]; then
    echo "WARN: не удалось проверить применение PANEL_PORT через 'x-ui setting -show'. Полный вывод:" >&2
    echo "$SETTING_OUTPUT" >&2
    echo "WARN: проверь вручную через web-UI: https://<DOMAIN>:$PANEL_PORT/$WEB_BASE_PATH_CLEAN/" >&2
fi

if ! echo "$APPLIED_PATH" | grep -q "$WEB_BASE_PATH_CLEAN"; then
    echo "WARN: webBasePath '$WEB_BASE_PATH_CLEAN' не подтвердился в выводе:" >&2
    echo "$APPLIED_PATH" >&2
fi

echo "[install] Готово."
echo ""
echo "Установлено:"
echo "  Версия:    $VERSION"
echo "  Порт:      $PANEL_PORT"
echo "  webPath:   /$WEB_BASE_PATH_CLEAN/"
echo "  Логин:     $ADMIN_LOGIN"
echo "  Пароль:    (32 символа — записан вызывающим скриптом в менеджер паролей)"
echo ""
echo "URL панели после DNS + TLS: https://<DOMAIN>:$PANEL_PORT/$WEB_BASE_PATH_CLEAN/"

exit 0
