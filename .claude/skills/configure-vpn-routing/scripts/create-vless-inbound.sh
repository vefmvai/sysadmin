#!/bin/bash
# create-vless-inbound.sh — создать VLESS inbound в панели через REST API.
#
# Поддерживает три протокола:
#  - vless-tls     (VLESS + TLS, штатный для ru-server inbound — ADR-0045).
#  - vless-reality (для foreign-server inbound с маскировкой от DPI).
#  - vless-tcp     (VLESS БЕЗ TLS — только к частному адресу, по CONFIRM_PLAIN_VLESS=yes).
#
# Вход через ENV:
#   PANEL_DOMAIN, PANEL_PORT, WEB_BASE_PATH — параметры панели
#   ADMIN_LOGIN, PASSWORD_REF              — для login
#   INBOUND_REMARK         — человеко-читаемая метка (например, "vless-tls-main")
#   INBOUND_LISTEN_PORT    — порт inbound на сервере (обычно 443)
#   INBOUND_PROTOCOL       — vless-tls | vless-reality | vless-tcp (default: vless-tls)
#   INBOUND_FLOW           — пусто или xtls-rprx-vision
#   SERVER_ROLE            — ru-server | foreign-server | "" (для guard'а протокола)
#   CONFIRM_REALITY_ON_RU  — yes, чтобы осознанно создать Reality на ru-server
#   CONFIRM_PLAIN_VLESS    — yes, чтобы осознанно создать vless-tcp без TLS
#   TLS_SERVER_NAME        — для vless-tls: домен, на который подключаются клиенты
#                            (default: PANEL_DOMAIN)
#   TLS_CERT_FILE, TLS_KEY_FILE — для vless-tls: пути к сертификату и ключу на сервере
#                            (default: из настроек панели webCertFile/webKeyFile —
#                            их выставляет /setup-vpn-panel)
#   SSH_TARGET             — для генерации Reality keypair при vless-reality
#   REALITY_DEST           — для vless-reality (например, www.cloudflare.com)
#
# ВАЖНО (guard 2): vless-tcp без TLS к публичному адресу клиенты на Xray-core
#   26.7.11+ не собирают («vless without TLS or other encryption is prohibited…»),
#   а UUID клиента идёт по сети открытым текстом. Создаётся только по
#   CONFIRM_PLAIN_VLESS=yes — для частной сети (LAN, Tailscale). ADR-0045.
#
# ВАЖНО (guard): vless-reality на ru-server обычно избыточен. Маршрут «клиент в
#   РФ → сервер в РФ» не пересекает TSPU, маскировка чаще всего ни от чего не
#   защищает. Скрипт НЕ запрещает такой выбор, но требует осознанного
#   подтверждения (CONFIRM_REALITY_ON_RU=yes) — чтобы Reality не появился на
#   РФ-сервере СЛУЧАЙНО. Reality штатно нужен на foreign-server или как outbound.
#
# Выход (на stdout): JSON-объект созданного inbound + UUID первого клиента.
#   { "inbound_id": 1, "first_client_uuid": "...", "tag": "..." }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
LIB="${REPO_ROOT}/scripts/lib-api/3xui.sh"

# shellcheck source=/dev/null
source "$LIB"

PANEL_DOMAIN="${PANEL_DOMAIN:?PANEL_DOMAIN обязателен}"
PANEL_PORT="${PANEL_PORT:?PANEL_PORT обязателен}"
WEB_BASE_PATH="${WEB_BASE_PATH:?WEB_BASE_PATH обязателен}"
ADMIN_LOGIN="${ADMIN_LOGIN:?ADMIN_LOGIN обязателен}"
PASSWORD_REF="${PASSWORD_REF:?PASSWORD_REF обязателен (например, keychain:3xui-panel-XXX)}"
INBOUND_REMARK="${INBOUND_REMARK:-vless-main}"
INBOUND_LISTEN_PORT="${INBOUND_LISTEN_PORT:-443}"
INBOUND_PROTOCOL="${INBOUND_PROTOCOL:-vless-tls}"
INBOUND_FLOW="${INBOUND_FLOW:-}"
SERVER_ROLE="${SERVER_ROLE:-}"
CONFIRM_REALITY_ON_RU="${CONFIRM_REALITY_ON_RU:-}"
CONFIRM_PLAIN_VLESS="${CONFIRM_PLAIN_VLESS:-}"

# --- Guard 2: VLESS без TLS не создаётся без подтверждения (ADR-0045) ------
# Запрет ядра действует на КЛИЕНТЕ и не виден на сервере: серверное ядро обычно
# старше и такой вход принимает. Поэтому стоп здесь, до входа в панель.
# exit 3 = «нужно подтверждение», не «ошибка».
if [ "$INBOUND_PROTOCOL" = "vless-tcp" ] && [ "$CONFIRM_PLAIN_VLESS" != "yes" ]; then
    cat >&2 <<'ERR'
СТОП (нужно подтверждение): vless-tcp — вход VLESS БЕЗ TLS.

  Клиенты на Xray-core 26.7.11+ такую ссылку к публичному адресу не собирают:
  «vless without TLS or other encryption is prohibited unless the server address
  is a private IP or domain». Флага отключения нет. Без TLS UUID клиента к тому же
  идёт по сети открытым текстом. Штатный вариант — INBOUND_PROTOCOL=vless-tls
  (сертификат домена панели).

  Осмысленно только для частного адреса (локальная сеть, Tailscale) — там запрет
  ядра не действует. Тогда повтори запуск с CONFIRM_PLAIN_VLESS=yes.
  См. knowledge/networking/_reference/vpn-protocols.md §6.8, ADR-0045.
ERR
    exit 3
fi

# --- Guard: Reality на РФ-сервере по умолчанию не создаётся -----------------
# Вход клиентов на РФ-сервер не пересекает TSPU — маскировка (Reality/Vision)
# обычно избыточна (заработал бы даже WireGuard). Это НЕ запрет: оператор может
# осознанно захотеть Reality на РФ-inbound (эксперимент, учебная цель, нетипичный
# кейс). Guard ловит только СЛУЧАЙНУЮ подстановку. Чтобы создать осознанно —
# агент сначала объясняет (роль ментора, см. SKILL.md Шаг 4), затем передаёт
# CONFIRM_REALITY_ON_RU=yes. exit 3 = «нужно подтверждение», не «ошибка».
if [ "$INBOUND_PROTOCOL" = "vless-reality" ] && [ "$SERVER_ROLE" = "ru-server" ] \
   && [ "$CONFIRM_REALITY_ON_RU" != "yes" ]; then
    cat >&2 <<'ERR'
СТОП (нужно подтверждение): vless-reality на ru-server — нетипичный выбор.

  Вход «клиент в РФ → сервер в РФ» НЕ пересекает TSPU. Маскировка под Reality
  здесь обычно ничего не даёт: маскировать нечего и не от кого. Штатный вариант —
  INBOUND_PROTOCOL=vless-tls (TLS — шифрование, не маскировка).

  Это не запрет. Если оператор осознанно хочет Reality на РФ-сервере (эксперимент,
  обучение, нестандартный кейс) — объясни ему «зачем обычно не нужно» и спроси
  «точно этого хочешь?». При подтверждении — повтори запуск с CONFIRM_REALITY_ON_RU=yes.

  Если же это на самом деле загр.сервер — роль указана неверно, передай
  SERVER_ROLE=foreign-server. См. knowledge/networking/_reference/vpn-consultation-flow.md §4.
ERR
    exit 3
fi

if [ "$INBOUND_PROTOCOL" = "vless-reality" ] && [ "$SERVER_ROLE" = "ru-server" ]; then
    echo "[inbound] ⚠️  Создаю Reality-inbound на РФ-сервере по явному подтверждению оператора (CONFIRM_REALITY_ON_RU=yes). Нетипичный выбор — это норм, если так задумано." >&2
fi
# ---------------------------------------------------------------------------

# Login
api_login \
    --domain "$PANEL_DOMAIN" \
    --port "$PANEL_PORT" \
    --web-path "$WEB_BASE_PATH" \
    --admin "$ADMIN_LOGIN" \
    --password-ref "$PASSWORD_REF"

# UUID первого клиента: на SPA его генерит ПАНЕЛЬ (клиента заводим отдельно после создания
# входа — он email-ключевая сущность), на legacy — генерим свой и встраиваем в settings.clients.
CLIENT_EMAIL="${CLIENT_EMAIL:-admin}"
if [ "$_3XUI_API_VARIANT" = "spa" ]; then
    CLIENT_UUID=""
else
    CLIENT_UUID="$(api_gen_uuid)"
fi

# Подготовка settings и streamSettings в зависимости от протокола
case "$INBOUND_PROTOCOL" in
    vless-tcp|vless-tls)
        SETTINGS_JSON="$(jq -nc \
            --arg uuid "$CLIENT_UUID" \
            --arg flow "$INBOUND_FLOW" \
            --arg email "$CLIENT_EMAIL" \
            '{
                clients: [{
                    id: $uuid,
                    flow: $flow,
                    email: $email,
                    limitIp: 0,
                    totalGB: 0,
                    expiryTime: 0,
                    enable: true,
                    tgId: "",
                    subId: "",
                    reset: 0
                }],
                decryption: "none",
                fallbacks: []
            }')"

        if [ "$INBOUND_PROTOCOL" = "vless-tcp" ]; then
            # Без TLS — сюда доходим только через guard 2 (CONFIRM_PLAIN_VLESS=yes).
            STREAM_SETTINGS_JSON='{"network":"tcp","security":"none","tcpSettings":{"header":{"type":"none"}}}'
        else
            # vless-tls: сертификат домена панели (ADR-0045). Пути берём из настроек
            # панели — их выставляет /setup-vpn-panel; при входе по API-токену
            # /panel/setting/all недоступен, тогда пути задаются явно.
            TLS_SERVER_NAME="${TLS_SERVER_NAME:-$PANEL_DOMAIN}"
            TLS_CERT_FILE="${TLS_CERT_FILE:-}"
            TLS_KEY_FILE="${TLS_KEY_FILE:-}"
            if [ -z "$TLS_CERT_FILE" ] || [ -z "$TLS_KEY_FILE" ]; then
                PANEL_SETTINGS="$(api_call POST "/panel/setting/all" 2>/dev/null)" || PANEL_SETTINGS=""
                if [ -z "$TLS_CERT_FILE" ]; then
                    TLS_CERT_FILE="$(echo "$PANEL_SETTINGS" | jq -r '.obj.webCertFile // empty' 2>/dev/null || true)"
                fi
                if [ -z "$TLS_KEY_FILE" ]; then
                    TLS_KEY_FILE="$(echo "$PANEL_SETTINGS" | jq -r '.obj.webKeyFile // empty' 2>/dev/null || true)"
                fi
            fi
            if [ -z "$TLS_CERT_FILE" ] || [ -z "$TLS_KEY_FILE" ]; then
                echo "ERROR: для vless-tls нет путей к сертификату: в настройках панели webCertFile/webKeyFile пусты (или недоступны)." >&2
                echo "       Задай TLS_CERT_FILE и TLS_KEY_FILE явно или выпусти сертификат через /setup-vpn-panel." >&2
                exit 2
            fi
            echo "[inbound] TLS: serverName=$TLS_SERVER_NAME cert=$TLS_CERT_FILE" >&2
            # Пути — на СЕРВЕРЕ, а jq запускается у оператора. Git Bash/MSYS на Windows
            # переписывает аргументы вида /root/... в C:/Program Files/Git/root/... при
            # вызове нативного jq (замер 2026-10-14) — в панель ушёл бы несуществующий
            # путь. MSYS_NO_PATHCONV (Git for Windows) и MSYS2_ARG_CONV_EXCL (MSYS2)
            # конверсию отключают; на Linux/macOS эти переменные ни на что не влияют.
            STREAM_SETTINGS_JSON="$(MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' jq -nc \
                --arg sni "$TLS_SERVER_NAME" \
                --arg cert "$TLS_CERT_FILE" \
                --arg key "$TLS_KEY_FILE" \
                '{
                    network: "tcp",
                    security: "tls",
                    tlsSettings: {
                        serverName: $sni,
                        minVersion: "1.2",
                        alpn: ["http/1.1"],
                        certificates: [{certificateFile: $cert, keyFile: $key}],
                        settings: {fingerprint: "chrome"}
                    },
                    tcpSettings: {acceptProxyProtocol: false, header: {type: "none"}}
                }')"
        fi
        ;;

    vless-reality)
        SSH_TARGET="${SSH_TARGET:?SSH_TARGET обязателен для vless-reality (для генерации ключей)}"
        REALITY_DEST="${REALITY_DEST:?REALITY_DEST обязателен для vless-reality}"

        # Генерация ключевой пары
        KEYPAIR_JSON="$(api_gen_reality_keypair "$SSH_TARGET")"
        PRIVATE_KEY="$(echo "$KEYPAIR_JSON" | jq -r '.private_key')"
        PUBLIC_KEY="$(echo "$KEYPAIR_JSON" | jq -r '.public_key')"

        # Короткий ID
        SHORT_ID="$(api_random_string 8 'a-f0-9' | tr '[:upper:]' '[:lower:]')"

        SETTINGS_JSON="$(jq -nc \
            --arg uuid "$CLIENT_UUID" \
            --arg flow "${INBOUND_FLOW:-xtls-rprx-vision}" \
            --arg email "$CLIENT_EMAIL" \
            '{
                clients: [{
                    id: $uuid,
                    flow: $flow,
                    email: $email,
                    limitIp: 0,
                    totalGB: 0,
                    expiryTime: 0,
                    enable: true,
                    tgId: "",
                    subId: "",
                    reset: 0
                }],
                decryption: "none",
                fallbacks: []
            }')"

        STREAM_SETTINGS_JSON="$(jq -nc \
            --arg dest "${REALITY_DEST}:443" \
            --arg sni "$REALITY_DEST" \
            --arg priv "$PRIVATE_KEY" \
            --arg pub "$PUBLIC_KEY" \
            --arg sid "$SHORT_ID" \
            '{
                network: "tcp",
                security: "reality",
                realitySettings: {
                    show: false,
                    xver: 0,
                    dest: $dest,
                    serverNames: [$sni],
                    privateKey: $priv,
                    shortIds: [$sid],
                    settings: {
                        publicKey: $pub,
                        fingerprint: "chrome",
                        serverName: $sni,
                        spiderX: "/"
                    }
                }
            }')"
        ;;

    *)
        echo "ERROR: INBOUND_PROTOCOL='$INBOUND_PROTOCOL' не поддерживается. Допустимо: vless-tls, vless-reality, vless-tcp" >&2
        exit 2
        ;;
esac

# Sniffing для маршрутизации по доменам
SNIFFING_JSON='{"enabled":true,"destOverride":["http","tls","quic"]}'

# Финальный объект inbound для API
INBOUND_TAG="inbound-${INBOUND_LISTEN_PORT}"
INBOUND_JSON="$(jq -nc \
    --arg remark "$INBOUND_REMARK" \
    --argjson port "$INBOUND_LISTEN_PORT" \
    --arg protocol "vless" \
    --arg tag "$INBOUND_TAG" \
    --arg settings "$SETTINGS_JSON" \
    --arg stream "$STREAM_SETTINGS_JSON" \
    --arg sniffing "$SNIFFING_JSON" \
    '{
        remark: $remark,
        enable: true,
        expiryTime: 0,
        listen: "",
        port: $port,
        protocol: $protocol,
        settings: $settings,
        streamSettings: $stream,
        tag: $tag,
        sniffing: $sniffing
    }')"

echo "[inbound] Создаю inbound: remark=$INBOUND_REMARK port=$INBOUND_LISTEN_PORT protocol=$INBOUND_PROTOCOL (variant=${_3XUI_API_VARIANT:-?})" >&2

# На SPA клиент — отдельная email-ключевая сущность: в inbounds/add клиентов НЕ встраиваем
# (settings.clients=[]), первого заводим отдельно через api_add_client после создания входа.
CREATE_JSON="$INBOUND_JSON"
if [ "$_3XUI_API_VARIANT" = "spa" ]; then
    CREATE_JSON="$(echo "$INBOUND_JSON" | jq '.settings |= (fromjson | .clients=[] | tojson)')"
fi

# Создание через variant-aware враппер (SPA form-тело / legacy JSON-тело)
RESULT="$(api_add_inbound "$CREATE_JSON")"

# ID и РЕАЛЬНЫЙ tag назначает панель (формат in-<port>-<network>) — берём из ответа, не выдумываем.
INBOUND_ID="$(echo "$RESULT" | jq -r '.obj.id // empty')"
REAL_TAG="$(echo "$RESULT" | jq -r '.obj.tag // empty')"
[ -n "$REAL_TAG" ] && [ "$REAL_TAG" != "null" ] && INBOUND_TAG="$REAL_TAG"

if [ -z "$INBOUND_ID" ]; then
    echo "ERROR: не удалось извлечь inbound_id из ответа" >&2
    echo "$RESULT" >&2
    exit 1
fi

# На SPA — заводим первого клиента отдельно и забираем реальный UUID (генерит панель).
if [ "$_3XUI_API_VARIANT" = "spa" ]; then
    CLIENT_FLOW_EFF="$INBOUND_FLOW"
    [ "$INBOUND_PROTOCOL" = "vless-reality" ] && [ -z "$CLIENT_FLOW_EFF" ] && CLIENT_FLOW_EFF="xtls-rprx-vision"
    if api_add_client "$INBOUND_ID" "$CLIENT_EMAIL" "$CLIENT_FLOW_EFF" >/dev/null 2>&1; then
        REAL_UUID="$(api_get_client_uuid "$INBOUND_ID" "$CLIENT_EMAIL")"
        [ -n "$REAL_UUID" ] && [ "$REAL_UUID" != "null" ] && CLIENT_UUID="$REAL_UUID"
    else
        echo "ERROR: вход создан (id=$INBOUND_ID), но первый клиент '$CLIENT_EMAIL' не добавился" >&2
        exit 1
    fi
fi

# Финальная проверка — читаем inbound обратно (variant-aware враппер)
VERIFY="$(api_get_inbound "$INBOUND_ID")"
if [ "$(echo "$VERIFY" | jq -r '.obj.port')" != "$INBOUND_LISTEN_PORT" ]; then
    echo "ERROR: верификация: порт не совпадает (ожидался $INBOUND_LISTEN_PORT)" >&2
    exit 1
fi

echo "[inbound] ✓ Inbound создан: id=$INBOUND_ID, tag=$INBOUND_TAG, первый клиент uuid=$CLIENT_UUID" >&2

# Перезапуск Xray
api_restart_xray >&2

# Возвращаем JSON для caller
jq -nc \
    --argjson inbound_id "$INBOUND_ID" \
    --arg uuid "$CLIENT_UUID" \
    --arg tag "$INBOUND_TAG" \
    --arg public_key "${PUBLIC_KEY:-}" \
    --arg short_id "${SHORT_ID:-}" \
    --arg sni "${REALITY_DEST:-}" \
    --arg flow "$INBOUND_FLOW" \
    '{
        inbound_id: $inbound_id,
        first_client_uuid: $uuid,
        tag: $tag,
        public_key: $public_key,
        short_id: $short_id,
        sni: $sni,
        flow: $flow
    }'

api_logout >&2
exit 0
