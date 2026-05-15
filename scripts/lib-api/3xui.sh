#!/usr/bin/env bash
# 3xui.sh — общий helper для REST API панели 3X-UI (MHSanaei/3x-ui).
#
# Используется скиллами VPN-блока: /setup-vpn-panel, /configure-vpn-routing,
# /setup-server-proxy, /generate-client-config.
#
# Контракт (см. .claude/knowledge/networking/3x-ui-api.md §3):
#
#   source "<path>/scripts/lib-api/3xui.sh"
#
#   api_login \
#       --domain "$PANEL_DOMAIN" \
#       --port "$PANEL_PORT" \
#       --web-path "$WEB_BASE_PATH" \
#       --admin "$ADMIN_LOGIN" \
#       --password-ref "keychain:3xui-panel-${SERVER_ALIAS}"
#
#   api_call GET "/panel/api/inbounds/list"
#   api_call POST "/panel/api/inbounds/add" --json-body "$INBOUND_JSON"
#   api_call DELETE "/panel/api/inbounds/del/3"
#
#   api_restart_xray
#   api_logout   # очистка cookie
#
# Окружение:
#   - curl 7.x+, jq 1.6+
#   - Опционально для resolve password из менеджера паролей:
#     security (macOS Keychain), pass (Unix), bw (Bitwarden CLI), op (1Password CLI)
#
# Возвращаемые коды:
#   0   — успех
#   1   — ошибка вызова (network, auth, parsing)
#   2   — ошибка валидации параметров

set -uo pipefail

# Защита от множественного source.
# При source-загрузке выходим через return; при ошибочном прямом запуске — через exit.
# shellcheck disable=SC2317  # 'exit 0' достижим только при прямом запуске (не source)
if [ "${_3XUI_LIB_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
_3XUI_LIB_LOADED=1

# ─── Внутренние переменные состояния ──────────────────────────────────────────
_3XUI_DOMAIN=""
_3XUI_PORT=""
_3XUI_WEB_PATH=""
_3XUI_BASE_URL=""
_3XUI_COOKIE_JAR=""
_3XUI_DEFAULT_TIMEOUT=10
_3XUI_DEFAULT_RETRIES=3
_3XUI_MASS_PAUSE_MS=150   # пауза между массовыми запросами

# ─── Утилиты ──────────────────────────────────────────────────────────────────
_3xui_die() {
    echo "[3xui-lib] ERROR: $*" >&2
    return 1
}

_3xui_log() {
    [ "${_3XUI_DEBUG:-0}" = "1" ] && echo "[3xui-lib] $*" >&2
    return 0
}

_3xui_require() {
    command -v "$1" >/dev/null 2>&1 || _3xui_die "Команда '$1' не найдена (нужен пакет)."
}

# Достать пароль по ссылке вида:
#   keychain:<имя записи>        — macOS Keychain через security(1)
#   pass:<путь>                  — Unix pass(1)
#   bw:<id или имя>              — Bitwarden CLI bw(1) (требует bw unlock и BW_SESSION)
#   op:<vault/item/field>        — 1Password CLI op(1) (требует op signin)
#   plain:<значение>             — литерал (для отладки, НЕ для продакшна)
#   env:<имя_переменной>         — взять из ENV (например, env:PANEL_PASSWORD)
_3xui_resolve_password() {
    local ref="$1"
    local scheme="${ref%%:*}"
    local value="${ref#*:}"

    case "$scheme" in
        keychain)
            _3xui_require security
            security find-generic-password -s "$value" -w 2>/dev/null
            ;;
        pass)
            _3xui_require pass
            pass show "$value" | head -n1
            ;;
        bw)
            _3xui_require bw
            bw get password "$value" 2>/dev/null
            ;;
        op)
            _3xui_require op
            op read "op://$value" 2>/dev/null
            ;;
        env)
            printf '%s' "${!value:-}"
            ;;
        plain)
            printf '%s' "$value"
            ;;
        *)
            _3xui_die "Неизвестная схема password-ref: '$scheme'. Поддерживается: keychain, pass, bw, op, env, plain."
            return 1
            ;;
    esac
}

# Соединить domain:port + webPath в полный base URL.
_3xui_build_base_url() {
    local domain="$1" port="$2" web_path="$3"
    # Очистка от ведущих/завершающих слешей в web_path
    web_path="${web_path#/}"
    web_path="${web_path%/}"
    if [ -z "$web_path" ]; then
        echo "https://${domain}:${port}"
    else
        echo "https://${domain}:${port}/${web_path}"
    fi
}

# Парсинг аргументов длинных опций.
_3xui_parse_args() {
    declare -gA _3XUI_ARGS=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --*)
                local key="${1#--}"
                local value="$2"
                _3XUI_ARGS["$key"]="$value"
                shift 2
                ;;
            *)
                _3xui_die "Неизвестный аргумент: $1"
                return 1
                ;;
        esac
    done
}

# ─── Публичный API ────────────────────────────────────────────────────────────

# api_login --domain X --port N --web-path P --admin U --password-ref REF
# Сохраняет сессию во внутреннюю cookie. Не выводит пароль.
api_login() {
    _3xui_require curl
    _3xui_require jq
    _3xui_parse_args "$@" || return 1

    local domain="${_3XUI_ARGS[domain]:-}"
    local port="${_3XUI_ARGS[port]:-}"
    local web_path="${_3XUI_ARGS[web-path]:-}"
    local admin="${_3XUI_ARGS[admin]:-}"
    local password_ref="${_3XUI_ARGS[password-ref]:-}"

    [ -z "$domain" ] && _3xui_die "--domain обязателен" && return 2
    [ -z "$port" ] && _3xui_die "--port обязателен" && return 2
    [ -z "$admin" ] && _3xui_die "--admin обязателен" && return 2
    [ -z "$password_ref" ] && _3xui_die "--password-ref обязателен" && return 2

    local password
    password="$(_3xui_resolve_password "$password_ref")"
    if [ -z "$password" ]; then
        _3xui_die "Не удалось получить пароль по ссылке '$password_ref'"
        return 1
    fi

    _3XUI_DOMAIN="$domain"
    _3XUI_PORT="$port"
    _3XUI_WEB_PATH="$web_path"
    _3XUI_BASE_URL="$(_3xui_build_base_url "$domain" "$port" "$web_path")"
    _3XUI_COOKIE_JAR="$(mktemp -t 3xui-cookie.XXXXXX)"

    # Cleanup при завершении (защита cookie с токеном)
    trap 'api_logout 2>/dev/null || true' EXIT INT TERM

    _3xui_log "Login → ${_3XUI_BASE_URL}/login (admin=$admin)"

    local response
    response="$(
        curl -sS \
            --max-time "$_3XUI_DEFAULT_TIMEOUT" \
            -c "$_3XUI_COOKIE_JAR" \
            -X POST "${_3XUI_BASE_URL}/login" \
            -d "username=${admin}&password=${password}" \
            2>&1
    )" || {
        _3xui_die "Login: curl failed: $response"
        return 1
    }

    local success
    success="$(echo "$response" | jq -r '.success // false' 2>/dev/null)"
    if [ "$success" != "true" ]; then
        local msg
        msg="$(echo "$response" | jq -r '.msg // "unknown error"' 2>/dev/null)"
        _3xui_die "Login failed: $msg"
        return 1
    fi

    _3xui_log "Login OK"
    return 0
}

# api_call METHOD ENDPOINT [--json-body JSON] [--form k=v]
# Возвращает тело ответа в stdout. Код 0 при success:true, 1 иначе.
api_call() {
    local method="$1"
    local endpoint="$2"
    shift 2

    [ -z "$_3XUI_COOKIE_JAR" ] && _3xui_die "Не залогинены (вызови api_login сначала)" && return 1
    [ ! -f "$_3XUI_COOKIE_JAR" ] && _3xui_die "Cookie jar не найден ($_3XUI_COOKIE_JAR)" && return 1

    local json_body=""
    local form_args=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --json-body) json_body="$2"; shift 2 ;;
            --form) form_args+=("-d" "$2"); shift 2 ;;
            *) _3xui_die "Неизвестный аргумент api_call: $1"; return 1 ;;
        esac
    done

    local url="${_3XUI_BASE_URL}${endpoint}"
    _3xui_log "$method $url"

    local attempt=0
    local max_attempts=$_3XUI_DEFAULT_RETRIES
    local delay=1
    local response=""
    local http_code=""

    while [ "$attempt" -lt "$max_attempts" ]; do
        attempt=$((attempt + 1))

        local curl_args=(
            -sS
            --max-time "$_3XUI_DEFAULT_TIMEOUT"
            -b "$_3XUI_COOKIE_JAR"
            -X "$method"
            -w "\n__HTTP_CODE__%{http_code}"
        )

        if [ -n "$json_body" ]; then
            curl_args+=(-H "Content-Type: application/json" --data-raw "$json_body")
        elif [ "${#form_args[@]}" -gt 0 ]; then
            curl_args+=("${form_args[@]}")
        fi

        curl_args+=("$url")

        response="$(curl "${curl_args[@]}" 2>&1)" || {
            _3xui_log "Attempt $attempt: curl failed, retrying in ${delay}s..."
            sleep "$delay"
            delay=$((delay * 2))
            continue
        }

        # Извлекаем HTTP-код
        http_code="$(echo "$response" | grep "__HTTP_CODE__" | sed 's/__HTTP_CODE__//')"
        response="$(echo "$response" | grep -v "__HTTP_CODE__")"

        if [ "$http_code" = "200" ]; then
            break
        elif [ "$http_code" -ge 500 ]; then
            _3xui_log "Attempt $attempt: HTTP $http_code, retrying in ${delay}s..."
            sleep "$delay"
            delay=$((delay * 2))
            continue
        else
            # 4xx — не повторяем
            break
        fi
    done

    if [ "$http_code" != "200" ]; then
        _3xui_die "HTTP $http_code: $response"
        return 1
    fi

    # Проверяем success: true в JSON
    local success
    success="$(echo "$response" | jq -r '.success // false' 2>/dev/null)"
    if [ "$success" != "true" ]; then
        local msg
        msg="$(echo "$response" | jq -r '.msg // "unknown error"' 2>/dev/null)"
        _3xui_die "API returned success=false: $msg"
        echo "$response"
        return 1
    fi

    echo "$response"

    # Пауза между массовыми запросами (защита от database lock)
    sleep "$(awk "BEGIN {printf \"%.3f\", $_3XUI_MASS_PAUSE_MS / 1000}")"
    return 0
}

# api_restart_xray — обязательный шаг после CRUD-операций
api_restart_xray() {
    _3xui_log "Restart Xray service"
    api_call POST "/panel/api/inbounds/restartXrayService"
}

# api_server_status — статус сервера/панели (для smoke-check)
api_server_status() {
    api_call POST "/panel/api/server/status"
}

# api_get_xray_config — текущий xray-конфиг (для редактирования outbounds/routing)
api_get_xray_config() {
    api_call GET "/panel/api/inbounds/getXrayConfig"
}

# api_update_xray_config "<json>" — обновить xray-конфиг (outbounds + routing)
api_update_xray_config() {
    local config_json="$1"
    api_call POST "/panel/api/inbounds/updateXrayConfig" --json-body "$config_json"
}

# api_list_inbounds — список inbound-ов
api_list_inbounds() {
    api_call GET "/panel/api/inbounds/list"
}

# api_logout — очистка cookie и состояния
api_logout() {
    if [ -n "$_3XUI_COOKIE_JAR" ] && [ -f "$_3XUI_COOKIE_JAR" ]; then
        # Best-effort: вызываем /logout если есть, потом удаляем cookie
        curl -sS --max-time 5 -b "$_3XUI_COOKIE_JAR" -X GET "${_3XUI_BASE_URL}/logout" >/dev/null 2>&1 || true
        rm -f "$_3XUI_COOKIE_JAR"
    fi
    _3XUI_COOKIE_JAR=""
    _3xui_log "Logout OK"
    trap - EXIT INT TERM
}

# ─── Проверка установки эталонной 3X-UI (защита от форков) ────────────────────
# Возвращает 0 если установлен MHSanaei/3x-ui, 1 иначе.
api_check_is_mhsanaei() {
    local ssh_target="$1"
    if [ -z "$ssh_target" ]; then
        _3xui_die "api_check_is_mhsanaei: нужен SSH-таргет"
        return 2
    fi

    # Проверяем через CLI 'x-ui --help' или содержимое x-ui.sh
    local check_output
    check_output="$(ssh "$ssh_target" "grep -l 'MHSanaei/3x-ui\\|mhsanaei' /usr/local/x-ui/x-ui.sh 2>/dev/null || echo 'NOT_FOUND'" 2>/dev/null)"

    if [ "$check_output" = "NOT_FOUND" ] || [ -z "$check_output" ]; then
        return 1
    fi
    return 0
}

# ─── Вспомогательные хелперы для скиллов ──────────────────────────────────────

# Генерация случайной строки заданной длины
api_random_string() {
    local length="${1:-32}"
    local charset="${2:-A-Za-z0-9}"
    LC_ALL=C tr -dc "$charset" </dev/urandom | head -c "$length"
    echo
}

# Генерация UUID v4 (для VLESS-клиентов)
api_gen_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        # Fallback через /proc/sys/kernel/random/uuid (Linux)
        if [ -r /proc/sys/kernel/random/uuid ]; then
            cat /proc/sys/kernel/random/uuid
        else
            _3xui_die "uuidgen не установлен и нет /proc/sys/kernel/random/uuid"
            return 1
        fi
    fi
}

# Генерация Reality keypair через xray-бинарь, развёрнутый рядом с 3X-UI
# Требует SSH-доступ к серверу с 3X-UI.
api_gen_reality_keypair() {
    local ssh_target="$1"
    if [ -z "$ssh_target" ]; then
        _3xui_die "api_gen_reality_keypair: нужен SSH-таргет"
        return 2
    fi

    local output
    output="$(ssh "$ssh_target" "/usr/local/x-ui/bin/xray-linux-amd64 x25519" 2>&1)" || {
        _3xui_die "Не удалось сгенерировать Reality keypair: $output"
        return 1
    }

    # Output:
    # Private key: <key>
    # Public key:  <key>
    local private_key public_key
    private_key="$(echo "$output" | awk '/[Pp]rivate [Kk]ey/ {print $NF}')"
    public_key="$(echo "$output" | awk '/[Pp]ublic [Kk]ey/ {print $NF}')"

    if [ -z "$private_key" ] || [ -z "$public_key" ]; then
        _3xui_die "Не удалось распарсить Reality keypair: $output"
        return 1
    fi

    # Возвращаем как JSON для упрощения парсинга в скиллах
    jq -n --arg priv "$private_key" --arg pub "$public_key" \
        '{private_key: $priv, public_key: $pub}'
}

# Проверка serverName для Reality: TLS 1.3 + HTTP/2 + доступность
# Возвращает 0 если домен подходит, 1 иначе.
api_validate_reality_dest() {
    local dest_domain="$1"
    if [ -z "$dest_domain" ]; then
        _3xui_die "api_validate_reality_dest: нужен домен"
        return 2
    fi

    _3xui_require curl

    # Проверка TLS 1.3 + HTTP/2
    local curl_out
    curl_out="$(curl -sI --max-time 10 --tlsv1.3 --tls-max 1.3 --http2 "https://${dest_domain}" 2>&1)" || {
        _3xui_log "Reality dest '$dest_domain' недоступен по TLS 1.3 + HTTP/2"
        return 1
    }

    # Дополнительно: проверка ответа 200 или 30x (не 5xx)
    local first_line
    first_line="$(echo "$curl_out" | head -n1)"
    if echo "$first_line" | grep -qE "HTTP/[12](\.[01])? (2|3)[0-9][0-9]"; then
        _3xui_log "Reality dest '$dest_domain' OK: $first_line"
        return 0
    fi

    _3xui_log "Reality dest '$dest_domain' вернул неподходящий статус: $first_line"
    return 1
}

# Записать секрет в менеджер паролей оператора.
# Параметры:
#   --manager keychain|pass|bw|op
#   --service <имя записи>
#   --account <логин>
#   --secret <пароль>
#   [--url <URL>]
#   [--notes <текст>]
api_store_secret() {
    _3xui_parse_args "$@" || return 1

    local manager="${_3XUI_ARGS[manager]:-}"
    local service="${_3XUI_ARGS[service]:-}"
    local account="${_3XUI_ARGS[account]:-}"
    local secret="${_3XUI_ARGS[secret]:-}"
    local url="${_3XUI_ARGS[url]:-}"
    local notes="${_3XUI_ARGS[notes]:-}"

    [ -z "$manager" ] && _3xui_die "--manager обязателен" && return 2
    [ -z "$service" ] && _3xui_die "--service обязателен" && return 2
    [ -z "$account" ] && _3xui_die "--account обязателен" && return 2
    [ -z "$secret" ] && _3xui_die "--secret обязателен" && return 2

    case "$manager" in
        keychain)
            _3xui_require security
            # -U updates если запись существует
            security add-generic-password \
                -s "$service" \
                -a "$account" \
                -w "$secret" \
                ${url:+-l "$url"} \
                ${notes:+-j "$notes"} \
                -U
            ;;
        pass)
            _3xui_require pass
            # pass хранит multiline: первая строка — пароль, дальше metadata
            {
                printf '%s\n' "$secret"
                [ -n "$account" ] && printf 'login: %s\n' "$account"
                [ -n "$url" ] && printf 'url: %s\n' "$url"
                [ -n "$notes" ] && printf 'notes: %s\n' "$notes"
            } | pass insert -m "$service"
            ;;
        bw)
            _3xui_require bw
            bw create item "$(jq -n \
                --arg name "$service" \
                --arg user "$account" \
                --arg pass "$secret" \
                --arg uri "$url" \
                --arg notes "$notes" \
                '{type: 1, name: $name, login: {username: $user, password: $pass, uris: ($uri | select(. != "") | [{uri: .}])}, notes: $notes}')" >/dev/null
            ;;
        op)
            _3xui_require op
            op item create \
                --category=login \
                --title="$service" \
                --vault=Private \
                "username=$account" \
                "password=$secret" \
                ${url:+--url="$url"} \
                ${notes:+"notes=$notes"} >/dev/null
            ;;
        *)
            _3xui_die "Неизвестный менеджер паролей: $manager"
            return 1
            ;;
    esac

    return 0
}
