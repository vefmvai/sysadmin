#!/usr/bin/env bash
# 03-configure-tls.sh — выпуск Let's Encrypt сертификата и привязка к панели.
#
# Поддерживаемые методы (выбор через TLS_METHOD):
#   acme-standalone  — встроенный acme в 3X-UI через standalone HTTP-01 (порт 80).
#                      Рекомендуется когда панель ставится на чистый сервер
#                      без других сервисов на 80.
#   acme-cloudflare  — встроенный acme в 3X-UI через Cloudflare DNS-01.
#                      Требует CLOUDFLARE_EMAIL и CLOUDFLARE_API_KEY.
#                      Не освобождает порт 80, безопаснее для серверов с
#                      существующими сервисами.
#   certbot          — внешний certbot --standalone, потом
#                      ручная привязка к панели через `x-ui setting -getCert`.
#
# Вход через ENV:
#   SSH_TARGET            — SSH-цель
#   DOMAIN                — домен (A-запись резолвится в IP сервера)
#   ADMIN_EMAIL           — email для Let's Encrypt уведомлений (рекомендуется)
#   TLS_METHOD            — acme-standalone | acme-cloudflare | certbot
#   CLOUDFLARE_EMAIL      — только для acme-cloudflare
#   CLOUDFLARE_API_KEY    — только для acme-cloudflare (Global API Key, не Token)
#
# Выход:
#   0 — сертификат выпущен и привязан
#   1 — ошибка выпуска или привязки
#   2 — ошибка параметров

set -euo pipefail

SSH_TARGET="${SSH_TARGET:?SSH_TARGET обязателен}"
DOMAIN="${DOMAIN:?DOMAIN обязателен}"
TLS_METHOD="${TLS_METHOD:-acme-standalone}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@${DOMAIN}}"

CERT_DIR="/root/cert/${DOMAIN}"
CERT_FILE="${CERT_DIR}/fullchain.pem"
KEY_FILE="${CERT_DIR}/privkey.pem"

case "$TLS_METHOD" in
    acme-standalone)
        echo "[tls] Выпуск через встроенный acme (standalone HTTP-01)..."
        echo "[tls] Это требует свободного порта 80 (временно)."

        # Открываем 80 в UFW (если активен)
        ssh "$SSH_TARGET" "command -v ufw >/dev/null && ufw status | grep -q active && ufw allow 80/tcp || true"

        # Запуск через CLI 3X-UI (если в текущей версии есть подкоманда),
        # либо через прямой вызов acme.sh
        # shellcheck disable=SC2087  # нужна client-side подстановка $DOMAIN, $ADMIN_EMAIL
        ssh "$SSH_TARGET" bash <<REMOTE_EOF
set -e
mkdir -p ${CERT_DIR}

# Проверка наличия acme.sh
if [ ! -f /root/.acme.sh/acme.sh ]; then
    echo "[tls] acme.sh не найден, ставим..."
    curl -s https://get.acme.sh | sh -s email=${ADMIN_EMAIL}
fi

ACME=/root/.acme.sh/acme.sh

# Регистрируем аккаунт ZeroSSL или LE по дефолту (acme.sh с 3.0 — ZeroSSL by default)
\$ACME --set-default-ca --server letsencrypt 2>/dev/null || true

# Останавливаем nginx/apache если работают на 80
if systemctl is-active --quiet nginx 2>/dev/null; then
    systemctl stop nginx
    NGINX_STOPPED=1
fi
if systemctl is-active --quiet apache2 2>/dev/null; then
    systemctl stop apache2
    APACHE_STOPPED=1
fi

# Выпуск сертификата standalone
\$ACME --issue --standalone -d ${DOMAIN} --keylength ec-256

# Привязка к нашим путям
\$ACME --install-cert -d ${DOMAIN} --ecc \\
    --fullchain-file ${CERT_FILE} \\
    --key-file ${KEY_FILE} \\
    --reloadcmd "systemctl restart x-ui"

# Восстанавливаем сервисы
if [ "\${NGINX_STOPPED:-0}" = "1" ]; then systemctl start nginx; fi
if [ "\${APACHE_STOPPED:-0}" = "1" ]; then systemctl start apache2; fi

echo "[tls] Сертификат выпущен: ${CERT_FILE}"
ls -la ${CERT_DIR}
REMOTE_EOF
        ;;

    acme-cloudflare)
        echo "[tls] Выпуск через acme + Cloudflare DNS-01..."
        if [ -z "${CLOUDFLARE_EMAIL:-}" ] || [ -z "${CLOUDFLARE_API_KEY:-}" ]; then
            echo "ERROR: для acme-cloudflare нужны CLOUDFLARE_EMAIL и CLOUDFLARE_API_KEY" >&2
            exit 2
        fi

        # shellcheck disable=SC2087  # client-side expansion намеренная
        ssh "$SSH_TARGET" bash <<REMOTE_EOF
set -e
export CF_Email='${CLOUDFLARE_EMAIL}'
export CF_Key='${CLOUDFLARE_API_KEY}'
mkdir -p ${CERT_DIR}

if [ ! -f /root/.acme.sh/acme.sh ]; then
    curl -s https://get.acme.sh | sh -s email=${ADMIN_EMAIL}
fi

ACME=/root/.acme.sh/acme.sh
\$ACME --set-default-ca --server letsencrypt 2>/dev/null || true
\$ACME --issue --dns dns_cf -d ${DOMAIN} --keylength ec-256
\$ACME --install-cert -d ${DOMAIN} --ecc \\
    --fullchain-file ${CERT_FILE} \\
    --key-file ${KEY_FILE} \\
    --reloadcmd "systemctl restart x-ui"

echo "[tls] Сертификат выпущен через DNS-01: ${CERT_FILE}"
REMOTE_EOF
        ;;

    certbot)
        echo "[tls] Выпуск через certbot --standalone..."

        # shellcheck disable=SC2087  # client-side expansion намеренная
        ssh "$SSH_TARGET" bash <<REMOTE_EOF
set -e

# Установка certbot если нет
if ! command -v certbot >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y certbot
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y certbot
    elif command -v yum >/dev/null 2>&1; then
        yum install -y certbot
    else
        echo "ERROR: не знаю как поставить certbot на этой ОС" >&2
        exit 1
    fi
fi

# Открываем 80
if command -v ufw >/dev/null && ufw status | grep -q active; then ufw allow 80/tcp; fi

# Останавливаем сервисы на 80
if systemctl is-active --quiet nginx 2>/dev/null; then systemctl stop nginx; fi

certbot certonly --standalone -d ${DOMAIN} --email ${ADMIN_EMAIL} --agree-tos --no-eff-email -n

mkdir -p ${CERT_DIR}
cp /etc/letsencrypt/live/${DOMAIN}/fullchain.pem ${CERT_FILE}
cp /etc/letsencrypt/live/${DOMAIN}/privkey.pem ${KEY_FILE}
chmod 600 ${KEY_FILE}

echo "[tls] Сертификат выпущен через certbot: ${CERT_FILE}"
REMOTE_EOF
        ;;

    *)
        echo "ERROR: TLS_METHOD='$TLS_METHOD' не поддерживается. Допустимо: acme-standalone, acme-cloudflare, certbot" >&2
        exit 2
        ;;
esac

# ─── Привязка сертификата к панели через CLI ──────────────────────────────────
echo "[tls] Привязка сертификата к панели..."

# 3X-UI хранит пути cert/key в settings таблицы x-ui.db
# Подставляем через 'x-ui setting' (если есть такой флаг) или прямой UPDATE.
# В текущих версиях нет CLI-флага для webCertFile, делаем через sqlite.

# shellcheck disable=SC2087  # client-side expansion (нужны переменные $CERT_FILE, $KEY_FILE)
ssh "$SSH_TARGET" bash <<REMOTE_EOF
set -e
DB=/etc/x-ui/x-ui.db
BACKUP="\$DB.backup.\$(date +%Y%m%d-%H%M%S)"

cp "\$DB" "\$BACKUP"
echo "[tls] Бэкап БД: \$BACKUP"

# Останавливаем панель перед правкой SQLite (см. 3x-ui-panel.md §3.2)
systemctl stop x-ui

sqlite3 "\$DB" <<SQL
INSERT INTO settings (key, value) VALUES ('webCertFile', '${CERT_FILE}')
ON CONFLICT(key) DO UPDATE SET value = '${CERT_FILE}';
INSERT INTO settings (key, value) VALUES ('webKeyFile', '${KEY_FILE}')
ON CONFLICT(key) DO UPDATE SET value = '${KEY_FILE}';
INSERT INTO settings (key, value) VALUES ('webDomain', '${DOMAIN}')
ON CONFLICT(key) DO UPDATE SET value = '${DOMAIN}';
SQL

systemctl start x-ui
sleep 3

if systemctl is-active --quiet x-ui; then
    echo "[tls] x-ui перезапущен и работает"
else
    echo "ERROR: x-ui не стартует после привязки cert. Откатываю..." >&2
    systemctl stop x-ui
    cp "\$BACKUP" "\$DB"
    systemctl start x-ui
    exit 1
fi
REMOTE_EOF

# ─── Smoke check: HTTPS отвечает ──────────────────────────────────────────────
echo "[tls] Smoke check: панель отвечает по HTTPS..."

# Извлекаем PANEL_PORT и WEB_BASE_PATH через CLI на сервере
PANEL_INFO="$(ssh "$SSH_TARGET" "/usr/local/x-ui/x-ui setting -show true" 2>&1)"
APPLIED_PORT="$(echo "$PANEL_INFO" | grep -iE "(panel|port)" | grep -oE '[0-9]{4,5}' | head -n1)"
APPLIED_PATH_FULL="$(echo "$PANEL_INFO" | grep -iE "(webBasePath|panel.*Path|base.*path)" | head -n1)"
APPLIED_PATH="$(echo "$APPLIED_PATH_FULL" | grep -oE '/[a-zA-Z0-9_-]+/' | head -n1)"

if [ -n "$APPLIED_PORT" ] && [ -n "$APPLIED_PATH" ]; then
    URL="https://${DOMAIN}:${APPLIED_PORT}${APPLIED_PATH}"
    echo "[tls] Проверяю $URL..."

    if curl -sI --max-time 15 "$URL" | head -n1 | grep -qE "HTTP/[12](\\.[01])? 200"; then
        echo "[tls] ✓ Панель отвечает 200 OK"
    else
        echo "[tls] ⚠ Панель не отвечает 200. Проверь руками: curl -vI '$URL'"
    fi
else
    echo "[tls] ⚠ Не удалось извлечь port/webBasePath для smoke-check. Полный вывод:"
    echo "$PANEL_INFO"
fi

echo "[tls] Готово."
exit 0
