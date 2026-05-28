#!/usr/bin/env bash
# 03-configure-tls.sh — выпуск Let's Encrypt сертификата и привязка к панели.
#
# Поддерживаемые методы (выбор через TLS_METHOD):
#   acme-webroot       — ДЕФОЛТ. acme.sh через работающий nginx (HTTP-01 webroot).
#                        Не моргает nginx ни при выпуске, ни при renew.
#                        Требует уже работающий nginx с server-блоком на 80.
#   certbot-webroot    — то же на certbot вместо acme.sh.
#   acme-standalone    — FALLBACK для VPS-без-nginx. acme.sh --standalone (HTTP-01).
#                        Останавливает nginx/apache на 80 на ~30-60 сек.
#                        Брать только если nginx нет и не планируется.
#   certbot-standalone — то же на certbot. Алиас `certbot` для совместимости.
#   acme-cloudflare    — DNS-01 через Cloudflare API. ВАЖНО: для РФ-операторов
#                        НЕ рекомендуется (Cloudflare блокируется в РФ).
#                        Требует CLOUDFLARE_EMAIL и CLOUDFLARE_API_KEY (Global Key).
#
# Полное обоснование выбора: references/tls-method-choice.md.
#
# Вход через ENV:
#   SSH_TARGET            — SSH-цель
#   DOMAIN                — домен (A-запись резолвится в IP сервера)
#   ADMIN_EMAIL           — email для Let's Encrypt уведомлений (рекомендуется)
#   TLS_METHOD            — см. выше
#   WEBROOT_PATH          — только для *-webroot. По умолчанию /var/www/letsencrypt
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
TLS_METHOD="${TLS_METHOD:-acme-webroot}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@${DOMAIN}}"
WEBROOT_PATH="${WEBROOT_PATH:-/var/www/letsencrypt}"

CERT_DIR="/root/cert/${DOMAIN}"
CERT_FILE="${CERT_DIR}/fullchain.pem"
KEY_FILE="${CERT_DIR}/privkey.pem"

# Алиас обратной совместимости: certbot → certbot-standalone
if [ "$TLS_METHOD" = "certbot" ]; then
    echo "[tls] WARN: TLS_METHOD=certbot — это алиас для certbot-standalone." >&2
    echo "[tls] WARN: На сервере с nginx предпочтительнее certbot-webroot (без моргания)." >&2
    TLS_METHOD="certbot-standalone"
fi

case "$TLS_METHOD" in
    acme-webroot)
        echo "[tls] Выпуск через acme.sh + webroot (через работающий nginx)..."
        echo "[tls] Nginx не моргает. Webroot: ${WEBROOT_PATH}"

        # shellcheck disable=SC2087  # client-side expansion намеренная
        ssh "$SSH_TARGET" bash <<REMOTE_EOF
set -e

# Проверка: nginx должен быть установлен и запущен
if ! systemctl is-active --quiet nginx 2>/dev/null; then
    echo "ERROR: nginx не запущен — webroot-метод не сработает." >&2
    echo "       Установи и запусти nginx, либо переключи TLS_METHOD на acme-standalone." >&2
    exit 1
fi

# Создаём webroot-папку
mkdir -p "${WEBROOT_PATH}/.well-known/acme-challenge"
chown -R www-data:www-data "${WEBROOT_PATH}" 2>/dev/null || true

# Добавляем location в дефолтный server-блок nginx (если его ещё нет).
# Кладём в conf.d/00-letsencrypt-acme.conf — это «фрагмент», подключаемый
# в любой server-блок через include. Чтобы не лезть в существующие vhost'ы.
SNIPPET=/etc/nginx/snippets/letsencrypt-acme.conf
mkdir -p /etc/nginx/snippets
cat > \$SNIPPET <<'NGINX_SNIPPET'
# Подключается через include snippets/letsencrypt-acme.conf;
# в каждом server-блоке :80, чтобы ACME HTTP-01 проходил без останова nginx.
location ^~ /.well-known/acme-challenge/ {
    root ${WEBROOT_PATH};
    default_type "text/plain";
    try_files \$uri =404;
}
NGINX_SNIPPET

# Если есть дефолтный server-блок без include — добавляем
DEFAULT_CONF=/etc/nginx/sites-enabled/default
if [ -f "\$DEFAULT_CONF" ] && ! grep -q "letsencrypt-acme" "\$DEFAULT_CONF"; then
    # Вставляем include после первой строки 'listen 80;' первого server-блока
    sed -i '0,/listen 80/{s|listen 80.*|&\n    include snippets/letsencrypt-acme.conf;|}' "\$DEFAULT_CONF"
fi

# Проверяем конфиг и перезагружаем
nginx -t
systemctl reload nginx

# Ставим acme.sh если ещё нет
if [ ! -f /root/.acme.sh/acme.sh ]; then
    echo "[tls] acme.sh не найден, ставим..."
    curl -s https://get.acme.sh | sh -s email=${ADMIN_EMAIL}
fi

ACME=/root/.acme.sh/acme.sh
\$ACME --set-default-ca --server letsencrypt 2>/dev/null || true

mkdir -p ${CERT_DIR}

# Выпуск через webroot — без остановки nginx
\$ACME --issue -d ${DOMAIN} -w ${WEBROOT_PATH} --keylength ec-256

# Привязка к нашим путям + deploy-hook для рестарта 3X-UI
\$ACME --install-cert -d ${DOMAIN} --ecc \\
    --fullchain-file ${CERT_FILE} \\
    --key-file ${KEY_FILE} \\
    --reloadcmd "systemctl restart x-ui"

echo "[tls] Сертификат выпущен через webroot: ${CERT_FILE}"
ls -la ${CERT_DIR}
REMOTE_EOF
        ;;

    certbot-webroot)
        echo "[tls] Выпуск через certbot + webroot (через работающий nginx)..."
        echo "[tls] Nginx не моргает. Webroot: ${WEBROOT_PATH}"

        # shellcheck disable=SC2087  # client-side expansion намеренная
        ssh "$SSH_TARGET" bash <<REMOTE_EOF
set -e

# Проверка: nginx должен быть установлен и запущен
if ! systemctl is-active --quiet nginx 2>/dev/null; then
    echo "ERROR: nginx не запущен — webroot-метод не сработает." >&2
    echo "       Установи и запусти nginx, либо переключи TLS_METHOD на certbot-standalone." >&2
    exit 1
fi

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

# Webroot-папка
mkdir -p "${WEBROOT_PATH}/.well-known/acme-challenge"
chown -R www-data:www-data "${WEBROOT_PATH}" 2>/dev/null || true

# Snippet для nginx (тот же, что и в acme-webroot)
SNIPPET=/etc/nginx/snippets/letsencrypt-acme.conf
mkdir -p /etc/nginx/snippets
cat > \$SNIPPET <<'NGINX_SNIPPET'
location ^~ /.well-known/acme-challenge/ {
    root ${WEBROOT_PATH};
    default_type "text/plain";
    try_files \$uri =404;
}
NGINX_SNIPPET

DEFAULT_CONF=/etc/nginx/sites-enabled/default
if [ -f "\$DEFAULT_CONF" ] && ! grep -q "letsencrypt-acme" "\$DEFAULT_CONF"; then
    sed -i '0,/listen 80/{s|listen 80.*|&\n    include snippets/letsencrypt-acme.conf;|}' "\$DEFAULT_CONF"
fi

nginx -t
systemctl reload nginx

mkdir -p ${CERT_DIR}

# Выпуск через webroot — без остановки nginx
certbot certonly --webroot -w ${WEBROOT_PATH} -d ${DOMAIN} \\
    --email ${ADMIN_EMAIL} --agree-tos --no-eff-email -n \\
    --deploy-hook "systemctl restart x-ui"

# Унификация путей: симлинки в /root/cert/\$DOMAIN/
ln -sf /etc/letsencrypt/live/${DOMAIN}/fullchain.pem ${CERT_FILE}
ln -sf /etc/letsencrypt/live/${DOMAIN}/privkey.pem ${KEY_FILE}

echo "[tls] Сертификат выпущен через certbot-webroot: ${CERT_FILE}"
echo "[tls] Симлинки на /etc/letsencrypt/live/${DOMAIN}/"
ls -la ${CERT_DIR}
REMOTE_EOF
        ;;

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

    certbot-standalone)
        echo "[tls] Выпуск через certbot --standalone (моргает nginx)..."

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
        echo "ERROR: TLS_METHOD='$TLS_METHOD' не поддерживается." >&2
        echo "       Допустимо: acme-webroot (дефолт) | certbot-webroot | acme-standalone | certbot-standalone | acme-cloudflare." >&2
        echo "       См. references/tls-method-choice.md для выбора." >&2
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
