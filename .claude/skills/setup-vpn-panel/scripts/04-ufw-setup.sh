#!/usr/bin/env bash
# 04-ufw-setup.sh — настройка UFW: открыть PANEL_PORT, опционально 443
# (для VLESS inbound в `LOCATION=foreign-server` сценарии).
#
# Логика порта 80:
#  - При TLS_METHOD ∈ acme-webroot / certbot-webroot → ОСТАВЛЯЕМ 80 ОТКРЫТЫМ
#    (нужен для ACME-челленджа при renew и редиректа http→https на сайтах).
#  - При TLS_METHOD ∈ acme-standalone / certbot-standalone → закрываем 80
#    ТОЛЬКО ЕСЛИ на сервере нет работающего nginx (определяем по
#    systemctl is-active nginx + наличию vhost'ов на :80). Иначе оставляем.
#  - При TLS_METHOD=acme-cloudflare → 80 не трогаем (статус-кво).
#
# NEVER молча закрывать 80, если на сервере есть nginx с сайтами — это
# сломает их автопродление сертификатов и редирект http→https.
# Эталон: _reference/web-and-vpn-coexistence.md §2.4.
#
# Вход через ENV:
#   SSH_TARGET             — SSH-цель
#   PANEL_PORT             — порт панели
#   LOCATION               — ru-server | foreign-server
#   TLS_METHOD             — acme-webroot | certbot-webroot | acme-standalone |
#                             certbot-standalone | acme-cloudflare
#
# Выход:
#   0 — UFW настроен
#   1 — ошибка

set -euo pipefail

SSH_TARGET="${SSH_TARGET:?SSH_TARGET обязателен}"
PANEL_PORT="${PANEL_PORT:?PANEL_PORT обязателен}"
LOCATION="${LOCATION:-ru-server}"
TLS_METHOD="${TLS_METHOD:-acme-webroot}"

# Алиас обратной совместимости
if [ "$TLS_METHOD" = "certbot" ]; then
    TLS_METHOD="certbot-standalone"
fi

echo "[ufw] Настройка UFW на $SSH_TARGET (TLS_METHOD=${TLS_METHOD})..."

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

# ─── Порт 80: условная логика по методу TLS ────────────────────────────────
case "${TLS_METHOD}" in
    acme-webroot|certbot-webroot)
        # Webroot-методы используют 80 при каждом renew + он нужен для редиректа.
        # ОСТАВЛЯЕМ открытым.
        ufw allow 80/tcp comment 'acme http-01 + http→https redirect'
        echo "[ufw] Порт 80 оставлен открытым (нужен для ACME renew и редиректа)."
        ;;

    acme-standalone|certbot-standalone)
        # Standalone-методы открывают 80 только на время выпуска.
        # После выпуска можно закрыть — НО только если на сервере нет nginx с сайтами.
        NGINX_RUNNING=0
        NGINX_HAS_SITES=0
        if systemctl is-active --quiet nginx 2>/dev/null; then
            NGINX_RUNNING=1
            # Есть ли в sites-enabled хотя бы один файл с 'listen 80', не считая дефолтного?
            if find /etc/nginx/sites-enabled/ -type l -o -type f 2>/dev/null | \
                xargs -r grep -l 'listen.*80' 2>/dev/null | grep -qv '/default\$'; then
                NGINX_HAS_SITES=1
            fi
        fi

        if [ "\$NGINX_RUNNING" = "1" ] && [ "\$NGINX_HAS_SITES" = "1" ]; then
            ufw allow 80/tcp comment 'nginx sites (http→https redirect + acme)'
            echo "[ufw] На сервере есть nginx с сайтами на :80 — порт 80 оставлен открытым."
            echo "[ufw] NEVER закрывать 80, если есть сайты (сломается автопродление и редирект)."
        else
            ufw delete allow 80/tcp 2>/dev/null || true
            echo "[ufw] Nginx нет / сайтов нет — порт 80 закрыт."
        fi
        ;;

    acme-cloudflare)
        # DNS-01 — 80 не нужен для выпуска. Статус-кво (не открываем, не закрываем).
        echo "[ufw] TLS_METHOD=acme-cloudflare — порт 80 не трогаю (статус-кво)."
        ;;

    *)
        echo "[ufw] WARN: TLS_METHOD='${TLS_METHOD}' не распознан, порт 80 не трогаю." >&2
        ;;
esac

ufw reload
ufw status verbose
REMOTE_EOF

echo "[ufw] Готово."
exit 0
