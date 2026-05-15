#!/usr/bin/env bash
# 01-preflight.sh — pre-check перед установкой 3X-UI.
#
# Что проверяет:
#  - SSH-доступность сервера
#  - ОС (Ubuntu 22.04+ / Debian 12+ / другие из install.sh)
#  - cloud-init завершён (если есть)
#  - 3X-UI ещё не установлен
#  - порты 80 и 443 свободны (нужны для acme HTTP-01)
#  - порт PANEL_PORT не занят
#  - jq установлен на сервере
#  - DNS: DOMAIN резолвится в IP сервера
#
# Вход через ENV:
#   SSH_TARGET (например, root@1.2.3.4 или alias из ~/.ssh/config)
#   DOMAIN (например, vpn.example.com)
#   PANEL_PORT (например, 48391)
#
# Выход:
#   0 — всё ок, можно ставить
#   1 — есть блокирующая проблема, STOP
#   2 — ошибка вызова (неверные параметры)

set -uo pipefail

SSH_TARGET="${SSH_TARGET:?SSH_TARGET обязателен}"
DOMAIN="${DOMAIN:?DOMAIN обязателен}"
PANEL_PORT="${PANEL_PORT:?PANEL_PORT обязателен}"

PROBLEMS=()
WARNINGS=()

# ─── SSH-доступность ──────────────────────────────────────────────────────────
if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "$SSH_TARGET" "echo connected" >/dev/null 2>&1; then
    PROBLEMS+=("SSH-доступ к $SSH_TARGET не работает (timeout 10s, BatchMode=yes)")
fi

# Все следующие проверки идут одной SSH-сессией для скорости.
# PANEL_PORT передаём через окружение (env-passing работает только если на сервере
# AcceptEnv разрешает; чаще приходится передавать как аргумент скрипту).
REMOTE_OUTPUT="$(ssh "$SSH_TARGET" PANEL_PORT="$PANEL_PORT" bash <<'REMOTE_EOF'
set -u
echo "----- OS RELEASE -----"
. /etc/os-release 2>/dev/null && echo "ID=$ID VERSION_ID=${VERSION_ID:-?}" || echo "OS_UNKNOWN"

echo "----- CLOUD-INIT -----"
if command -v cloud-init >/dev/null 2>&1; then
    cloud-init status 2>/dev/null || echo "CLOUD_INIT_NOT_RUNNING"
else
    echo "CLOUD_INIT_ABSENT"
fi

echo "----- 3X-UI PRESENCE -----"
if [ -e /usr/local/x-ui/x-ui ] || systemctl list-unit-files 2>/dev/null | grep -q '^x-ui\.service'; then
    echo "ALREADY_INSTALLED"
else
    echo "NOT_INSTALLED"
fi

echo "----- PORTS -----"
if command -v ss >/dev/null 2>&1; then
    PORT_TOOL="ss -tlnH"
elif command -v netstat >/dev/null 2>&1; then
    PORT_TOOL="netstat -tlnp"
else
    PORT_TOOL=""
fi

if [ -n "$PORT_TOOL" ]; then
    for port in 80 443 "${PANEL_PORT}"; do
        if $PORT_TOOL 2>/dev/null | grep -qE "[:.]${port} "; then
            echo "PORT_BUSY:$port"
        else
            echo "PORT_FREE:$port"
        fi
    done
else
    echo "PORT_CHECK_UNAVAILABLE"
fi

echo "----- JQ -----"
if command -v jq >/dev/null 2>&1; then
    jq --version
else
    echo "JQ_MISSING"
fi
REMOTE_EOF
)"

# ─── Анализ результата ────────────────────────────────────────────────────────
if echo "$REMOTE_OUTPUT" | grep -q "ALREADY_INSTALLED"; then
    PROBLEMS+=("3X-UI уже установлен на $SSH_TARGET (см. /usr/local/x-ui/x-ui или systemctl)")
fi

OS_ID="$(echo "$REMOTE_OUTPUT" | grep "^ID=" | sed 's/ID=\([^ ]*\).*/\1/')"

case "$OS_ID" in
    ubuntu|debian|centos|fedora|rhel|almalinux|rocky|ol|arch|manjaro|parch|opensuse-tumbleweed|opensuse-leap|alpine)
        : # supported by official install.sh
        ;;
    *)
        WARNINGS+=("ОС '$OS_ID' не подтверждена в официальном install.sh, установка может упасть")
        ;;
esac

if echo "$REMOTE_OUTPUT" | grep -q "PORT_BUSY:80"; then
    PROBLEMS+=("Порт 80 занят на сервере (нужен для acme HTTP-01 challenge)")
fi
if echo "$REMOTE_OUTPUT" | grep -q "PORT_BUSY:443"; then
    PROBLEMS+=("Порт 443 занят на сервере (нужен для acme и опционально VLESS inbound)")
fi
if echo "$REMOTE_OUTPUT" | grep -q "PORT_BUSY:${PANEL_PORT}"; then
    PROBLEMS+=("Порт PANEL_PORT=$PANEL_PORT занят на сервере")
fi

if echo "$REMOTE_OUTPUT" | grep -q "JQ_MISSING"; then
    WARNINGS+=("jq не установлен на сервере — будет поставлен при установке")
fi

if echo "$REMOTE_OUTPUT" | grep -q "PORT_CHECK_UNAVAILABLE"; then
    WARNINGS+=("Не удалось проверить порты (нет ss/netstat) — установщик может упасть на конфликте")
fi

# ─── DNS-проверка ─────────────────────────────────────────────────────────────
if command -v dig >/dev/null 2>&1; then
    SERVER_IP="$(ssh "$SSH_TARGET" "curl -sS --max-time 5 ifconfig.me" 2>/dev/null || echo "UNKNOWN")"
    DOMAIN_IP="$(dig +short +time=5 "$DOMAIN" A | head -n1)"

    if [ "$DOMAIN_IP" != "$SERVER_IP" ] && [ "$SERVER_IP" != "UNKNOWN" ]; then
        PROBLEMS+=("DNS: домен $DOMAIN резолвится в $DOMAIN_IP, но IP сервера — $SERVER_IP. Создай A-запись или подожди распространения DNS.")
    fi
elif command -v host >/dev/null 2>&1; then
    if ! host "$DOMAIN" >/dev/null 2>&1; then
        PROBLEMS+=("DNS: домен $DOMAIN не резолвится (host)")
    fi
else
    WARNINGS+=("dig/host не найдены локально — пропустил DNS-проверку, проверь вручную")
fi

# ─── Отчёт ────────────────────────────────────────────────────────────────────
echo ""
echo "=== Pre-flight check для setup-vpn-panel ==="
echo "Сервер:  $SSH_TARGET"
echo "Домен:   $DOMAIN"
echo "Порт:    $PANEL_PORT"
echo ""

if [ "${#PROBLEMS[@]}" -eq 0 ]; then
    echo "✓ Все обязательные проверки прошли."
else
    echo "✗ Найдены блокирующие проблемы:"
    for p in "${PROBLEMS[@]}"; do
        echo "  - $p"
    done
fi

if [ "${#WARNINGS[@]}" -gt 0 ]; then
    echo ""
    echo "⚠ Предупреждения (не блокируют, но требуют внимания):"
    for w in "${WARNINGS[@]}"; do
        echo "  - $w"
    done
fi

echo ""

[ "${#PROBLEMS[@]}" -eq 0 ] && exit 0 || exit 1
