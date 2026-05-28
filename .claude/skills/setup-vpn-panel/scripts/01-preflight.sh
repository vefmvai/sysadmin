#!/usr/bin/env bash
# 01-preflight.sh — pre-check перед установкой 3X-UI.
#
# Что проверяет:
#  - SSH-доступность сервера
#  - ОС (Ubuntu 22.04+ / Debian 12+ / другие из install.sh)
#  - cloud-init завершён (если есть)
#  - 3X-UI ещё не установлен
#  - порт PANEL_PORT не занят
#  - 443 свободен (или нет — учитывается, но не блокирует)
#  - порт 80 — зависит от TLS_METHOD:
#      * *-webroot   → требует работающий nginx с server-блоком на 80
#      * *-standalone → требует свободный 80 (или останавливаемый nginx)
#      * acme-cloudflare → 80 безразличен
#  - jq установлен на сервере
#  - DNS: DOMAIN резолвится в IP сервера
#
# Вход через ENV:
#   SSH_TARGET (например, root@1.2.3.4 или alias из ~/.ssh/config)
#   DOMAIN (например, vpn.example.com)
#   PANEL_PORT (например, 48391)
#   TLS_METHOD (по умолчанию acme-webroot)
#
# Выход:
#   0 — всё ок, можно ставить
#   1 — есть блокирующая проблема, STOP
#   2 — ошибка вызова (неверные параметры)

set -uo pipefail

SSH_TARGET="${SSH_TARGET:?SSH_TARGET обязателен}"
DOMAIN="${DOMAIN:?DOMAIN обязателен}"
PANEL_PORT="${PANEL_PORT:?PANEL_PORT обязателен}"
TLS_METHOD="${TLS_METHOD:-acme-webroot}"

# Алиас обратной совместимости
if [ "$TLS_METHOD" = "certbot" ]; then
    TLS_METHOD="certbot-standalone"
fi

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

echo "----- NGINX -----"
if systemctl is-active --quiet nginx 2>/dev/null; then
    echo "NGINX_RUNNING"
    # Есть ли server-блок с listen 80 в активных сайтах?
    if find /etc/nginx/sites-enabled/ -type l -o -type f 2>/dev/null | \
        xargs -r grep -l 'listen.*80' 2>/dev/null | grep -q .; then
        echo "NGINX_HAS_80_VHOST"
    else
        echo "NGINX_NO_80_VHOST"
    fi
    # Есть ли пользовательские сайты (не дефолтный)?
    if find /etc/nginx/sites-enabled/ -type l -o -type f 2>/dev/null | \
        xargs -r grep -l 'listen.*80' 2>/dev/null | grep -qv '/default$'; then
        echo "NGINX_HAS_USER_SITES"
    fi
elif command -v nginx >/dev/null 2>&1; then
    echo "NGINX_INSTALLED_NOT_RUNNING"
else
    echo "NGINX_ABSENT"
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

# Порт 443 — предупреждение, не блок (foreign-server может его требовать,
# но это решается позже в configure-vpn-routing)
if echo "$REMOTE_OUTPUT" | grep -q "PORT_BUSY:443"; then
    WARNINGS+=("Порт 443 занят. Если LOCATION=foreign-server и планируется Reality на 443 — решить позже в /configure-vpn-routing.")
fi

if echo "$REMOTE_OUTPUT" | grep -q "PORT_BUSY:${PANEL_PORT}"; then
    PROBLEMS+=("Порт PANEL_PORT=$PANEL_PORT занят на сервере")
fi

# ─── Условный анализ порта 80 + nginx по TLS_METHOD ───────────────────────────
NGINX_RUNNING=0
NGINX_HAS_80_VHOST=0
PORT_80_BUSY=0
echo "$REMOTE_OUTPUT" | grep -q "NGINX_RUNNING" && NGINX_RUNNING=1
echo "$REMOTE_OUTPUT" | grep -q "NGINX_HAS_80_VHOST" && NGINX_HAS_80_VHOST=1
echo "$REMOTE_OUTPUT" | grep -q "PORT_BUSY:80" && PORT_80_BUSY=1

case "$TLS_METHOD" in
    acme-webroot|certbot-webroot)
        # Webroot требует работающий nginx с server-блоком на 80
        if [ "$NGINX_RUNNING" = "0" ]; then
            PROBLEMS+=("TLS_METHOD=$TLS_METHOD требует работающий nginx, но nginx не запущен. Установи и запусти nginx (если планируются сайты) или переключи TLS_METHOD на acme-standalone (если nginx не нужен).")
        elif [ "$NGINX_HAS_80_VHOST" = "0" ]; then
            WARNINGS+=("Nginx запущен, но нет server-блока с listen 80. Скилл добавит дефолтный, чтобы webroot заработал.")
        fi
        # Порт 80 ДОЛЖЕН быть занят nginx — это норма, не проблема
        ;;

    acme-standalone|certbot-standalone)
        # Standalone требует свободный 80 (либо останавливаемый nginx)
        if [ "$PORT_80_BUSY" = "1" ] && [ "$NGINX_RUNNING" = "0" ]; then
            # 80 занят чем-то, что НЕ nginx — это блок
            PROBLEMS+=("TLS_METHOD=$TLS_METHOD требует свободный 80, но он занят (и nginx не запущен — значит, что-то другое). Освободи или переключи метод.")
        elif [ "$NGINX_HAS_80_VHOST" = "1" ]; then
            # Nginx работает с сайтами — standalone их положит. Серьёзное предупреждение.
            WARNINGS+=("На сервере работает nginx с сайтами на :80. TLS_METHOD=$TLS_METHOD остановит nginx на 30-60 сек при выпуске И при каждом renew (раз в 60 дней). РЕКОМЕНДУЮ переключить на ${TLS_METHOD%-standalone}-webroot — не моргает, см. references/tls-method-choice.md.")
        fi
        ;;

    acme-cloudflare)
        # 80 безразличен, главное — CF-ключи
        : # отдельно проверяется наличие CLOUDFLARE_EMAIL/KEY в скилле
        ;;
esac

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
