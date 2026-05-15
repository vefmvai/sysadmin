#!/bin/bash
# 00-detect-existing.sh — детектор существующей установки серверного прокси.
#
# Запускается ПЕРВЫМ шагом /setup-server-proxy (до брифинга и установки).
# Защищает от двух сценариев:
#  1. Idempotent re-run — оператор случайно запустил скилл повторно.
#  2. Troubleshooting вместо установки — оператор пожаловался на «aiohttp не
#     работает через прокси» / «бот возвращает 403» и т.п., и Claude активировал
#     этот скилл. Если прокси уже настроен — реальная проблема в библиотеке
#     программы (см. references/python-libs-with-proxy.md), а не в прокси.
#
# Проверяет 4 индикатора установки:
#  A. /etc/systemd/system/x-ui.service.d/override.conf существует и содержит
#     HTTP_PROXY="" / HTTPS_PROXY="" / NO_PROXY="*".
#  B. /etc/environment содержит строки http_proxy=socks5h://... + https_proxy=socks5h://...
#  C. На панели есть mixed-inbound на 127.0.0.1 (через API).
#  D. curl -x socks5h://127.0.0.1:1080 https://www.google.com отвечает HTTP/2.
#
# Логика:
#  - Все 4 индикатора TRUE → прокси полностью настроен и работает.
#    Вывод: ALREADY_INSTALLED. Скилл должен показать troubleshooting-маршрут.
#  - 1-3 индикатора TRUE → частичная установка (или прерванная сессия).
#    Вывод: PARTIAL. Скилл должен спросить «продолжить установку с того места,
#    где остановились» или «откатить и переустановить заново».
#  - 0 индикаторов TRUE → чистая установка.
#    Вывод: NOT_INSTALLED. Скилл продолжает обычный flow.
#
# Вход через ENV:
#   SSH_TARGET — SSH-цель сервера
#   PROXY_PORT — порт прокси для проверки (default 1080)
#
# Выход (на stdout): JSON-объект состояния.
#   {
#     "status": "ALREADY_INSTALLED" | "PARTIAL" | "NOT_INSTALLED",
#     "indicators": {
#       "override_present": bool,
#       "environment_has_proxy": bool,
#       "mixed_inbound_exists": bool,
#       "proxy_works": bool
#     },
#     "recommendation": "skip" | "resume" | "rollback-and-reinstall" | "install"
#   }

set -uo pipefail

SSH_TARGET="${SSH_TARGET:?SSH_TARGET обязателен}"
PROXY_PORT="${PROXY_PORT:-1080}"

# Индикатор A: systemd-override на месте
A_override=false
override_check="$(ssh "$SSH_TARGET" "test -f /etc/systemd/system/x-ui.service.d/override.conf && grep -q 'HTTP_PROXY=\"\"' /etc/systemd/system/x-ui.service.d/override.conf && echo YES || echo NO" 2>/dev/null)"
[ "$override_check" = "YES" ] && A_override=true

# Индикатор B: /etc/environment содержит socks5h://
B_environment=false
env_check="$(ssh "$SSH_TARGET" "grep -qE '^https?_proxy=socks5h://' /etc/environment && echo YES || echo NO" 2>/dev/null)"
[ "$env_check" = "YES" ] && B_environment=true

# Индикатор C: mixed inbound на 127.0.0.1 в панели
# Проверка через файловую систему — ищем в SQLite-базе панели mixed-inbound на нужном порту
C_mixed_inbound=false
if [ -n "${PANEL_DOMAIN:-}" ] && [ -n "${ADMIN_LOGIN:-}" ] && [ -n "${PASSWORD_REF:-}" ]; then
    # Используем lib-api, если параметры panel переданы (вызывается изнутри скилла)
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/scripts/lib-api/3xui.sh" 2>/dev/null

    if api_login \
        --domain "$PANEL_DOMAIN" \
        --port "${PANEL_PORT:-443}" \
        --web-path "${WEB_BASE_PATH:-}" \
        --admin "$ADMIN_LOGIN" \
        --password-ref "$PASSWORD_REF" 2>/dev/null; then

        mixed_count="$(api_call GET "/panel/api/inbounds/list" 2>/dev/null \
            | jq --arg port "$PROXY_PORT" \
                '[.obj[] | select(.protocol == "mixed" and (.listen == "127.0.0.1" or .listen == "") and (.port | tostring) == $port)] | length' \
            2>/dev/null || echo 0)"
        [ "${mixed_count:-0}" -gt 0 ] && C_mixed_inbound=true
        api_logout 2>/dev/null || true
    fi
else
    # Fallback: прямая правка SQLite (read-only)
    # shellcheck disable=SC2029  # $PROXY_PORT — client-side expansion намеренно
    mixed_check="$(ssh "$SSH_TARGET" "sqlite3 /etc/x-ui/x-ui.db \"SELECT COUNT(*) FROM inbounds WHERE protocol='mixed' AND port=${PROXY_PORT}\" 2>/dev/null || echo 0" 2>/dev/null)"
    [ "${mixed_check:-0}" -gt 0 ] && C_mixed_inbound=true
fi

# Индикатор D: прокси реально работает (curl через socks5h)
D_proxy_works=false
# shellcheck disable=SC2029  # $PROXY_PORT — client-side expansion намеренно
proxy_check="$(ssh "$SSH_TARGET" "curl -sI --max-time 10 -x socks5h://127.0.0.1:${PROXY_PORT} https://www.google.com 2>/dev/null | head -n1 | grep -qE 'HTTP/[12]' && echo YES || echo NO" 2>/dev/null)"
[ "$proxy_check" = "YES" ] && D_proxy_works=true

# Подсчёт TRUE-индикаторов
true_count=0
for v in "$A_override" "$B_environment" "$C_mixed_inbound" "$D_proxy_works"; do
    [ "$v" = "true" ] && true_count=$((true_count + 1))
done

# Решение
if [ "$true_count" -eq 4 ]; then
    status="ALREADY_INSTALLED"
    recommendation="skip"
elif [ "$true_count" -ge 1 ]; then
    status="PARTIAL"
    # Если override и environment есть, но не работает curl — это troubleshooting
    if [ "$A_override" = "true" ] && [ "$B_environment" = "true" ] && [ "$D_proxy_works" = "false" ]; then
        recommendation="troubleshoot"
    else
        recommendation="resume"
    fi
else
    status="NOT_INSTALLED"
    recommendation="install"
fi

# Эмитим JSON
jq -n \
    --arg status "$status" \
    --arg rec "$recommendation" \
    --argjson a "$A_override" \
    --argjson b "$B_environment" \
    --argjson c "$C_mixed_inbound" \
    --argjson d "$D_proxy_works" \
    '{
        status: $status,
        recommendation: $rec,
        indicators: {
            override_present: $a,
            environment_has_proxy: $b,
            mixed_inbound_exists: $c,
            proxy_works: $d
        }
    }'

exit 0
