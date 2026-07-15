#!/usr/bin/env bash
# 3xui.sh — общий helper для REST API панели 3X-UI (MHSanaei/3x-ui).
#
# Используется скиллами VPN-блока: /setup-vpn-panel, /configure-vpn-routing,
# /setup-server-proxy, /generate-client-config.
#
# Контракт (см. .claude/knowledge/networking/_reference/3x-ui-api.md §3):
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
#     security (macOS Keychain), pass (Unix), bw (Bitwarden CLI), op (1Password CLI),
#     keepassxc-cli (KeePassXC)
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
_3XUI_AUTH_MODE=""        # "" | "cookie" | "bearer"
_3XUI_BEARER_TOKEN=""     # активный Bearer-токен (не логируется)
_3XUI_CSRF_TOKEN=""       # активный CSRF-токен (переиспользуется на чувствительных эндпоинтах)
_3XUI_PANEL_VERSION=""    # "legacy" (≤v2.x) | "v3+" (с CSRF) — выясняется в api_login
_3XUI_API_VARIANT=""      # "legacy" (§1–14) | "spa" (§15) — REST-вариант, детект после логина (ADR-0020)

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
#   keepassxc:<заголовок записи> — KeePassXC через keepassxc-cli(1). База и разблокировка
#                                  берутся из ENV: KEEPASSXC_DB=/путь/к.kdbx (обязательно),
#                                  KEEPASSXC_PASSWORD=<мастер-пароль> (подаётся по stdin),
#                                  KEEPASSXC_KEYFILE=<ключ-файл> (опционально). Секреты БД
#                                  не логируются.
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
        keepassxc)
            _3xui_require keepassxc-cli
            local kdbx="${KEEPASSXC_DB:-}"
            if [ -z "$kdbx" ]; then
                _3xui_die "keepassxc: не задан путь к базе (ENV KEEPASSXC_DB=/путь/к.kdbx)"
                return 1
            fi
            # Мастер-пароль подаётся по stdin (не в аргументах — не светится в ps).
            # -q подавляет prompt-текст, -a Password печатает только атрибут пароля.
            if [ -n "${KEEPASSXC_KEYFILE:-}" ]; then
                printf '%s' "${KEEPASSXC_PASSWORD:-}" \
                    | keepassxc-cli show -q -a Password -k "$KEEPASSXC_KEYFILE" "$kdbx" "$value" 2>/dev/null
            else
                printf '%s' "${KEEPASSXC_PASSWORD:-}" \
                    | keepassxc-cli show -q -a Password "$kdbx" "$value" 2>/dev/null
            fi
            ;;
        env)
            printf '%s' "${!value:-}"
            ;;
        plain)
            printf '%s' "$value"
            ;;
        *)
            _3xui_die "Неизвестная схема password-ref: '$scheme'. Поддерживается: keychain, pass, bw, op, keepassxc, env, plain."
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

# URL-энкод значения для вставки в path (например, email клиента в SPA clients/del/{email}).
# Фронтенд SPA-панели делает encodeURIComponent — повторяем через jq @uri.
_3xui_urlencode() {
    printf '%s' "$1" | jq -sRr @uri
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

# api_login --domain X --port N --web-path P [--admin U --password-ref REF | --bearer-token-ref REF]
# Поддерживает два режима:
#   1. Username/password (двухшаговый с автодетектом CSRF v3.0.0+).
#   2. Bearer-token (через --bearer-token-ref) — устойчивее, не зависит от CSRF.
#      Токен предварительно создан в UI панели (Settings → Security → API Tokens).
#
# При первом запуске на свежей v3.0+ панели рекомендуется username/password
# (токена ещё нет). В повторных запусках, если в infra-config.json (секция vpn) есть
# panel_api_token — лучше Bearer.
#
# Сохраняет состояние во внутренние переменные. Не выводит секреты в лог.
api_login() {
    _3xui_require curl
    _3xui_require jq
    _3xui_parse_args "$@" || return 1

    local domain="${_3XUI_ARGS[domain]:-}"
    local port="${_3XUI_ARGS[port]:-}"
    local web_path="${_3XUI_ARGS[web-path]:-}"
    local admin="${_3XUI_ARGS[admin]:-}"
    local password_ref="${_3XUI_ARGS[password-ref]:-}"
    local bearer_ref="${_3XUI_ARGS[bearer-token-ref]:-}"

    [ -z "$domain" ] && _3xui_die "--domain обязателен" && return 2
    [ -z "$port" ] && _3xui_die "--port обязателен" && return 2

    _3XUI_DOMAIN="$domain"
    _3XUI_PORT="$port"
    _3XUI_WEB_PATH="$web_path"
    _3XUI_BASE_URL="$(_3xui_build_base_url "$domain" "$port" "$web_path")"

    # ─── Bearer-режим ─────────────────────────────────────────────────────
    if [ -n "$bearer_ref" ]; then
        local token
        token="$(_3xui_resolve_password "$bearer_ref")"
        if [ -z "$token" ]; then
            _3xui_die "Не удалось получить Bearer-токен по ссылке '$bearer_ref'"
            return 1
        fi
        _3XUI_BEARER_TOKEN="$token"
        _3XUI_AUTH_MODE="bearer"
        _3XUI_COOKIE_JAR=""   # cookie не нужен
        trap 'api_logout 2>/dev/null || true' EXIT INT TERM
        _3xui_detect_api_variant
        _3xui_log "Login OK (bearer mode, variant=${_3XUI_API_VARIANT})"
        return 0
    fi

    # ─── Username/password режим ──────────────────────────────────────────
    [ -z "$admin" ] && _3xui_die "--admin обязателен (или передай --bearer-token-ref)" && return 2
    [ -z "$password_ref" ] && _3xui_die "--password-ref обязателен (или передай --bearer-token-ref)" && return 2

    local password
    password="$(_3xui_resolve_password "$password_ref")"
    if [ -z "$password" ]; then
        _3xui_die "Не удалось получить пароль по ссылке '$password_ref'"
        return 1
    fi

    _3XUI_COOKIE_JAR="$(mktemp -t 3xui-cookie.XXXXXX)"
    _3XUI_AUTH_MODE="cookie"

    # Cleanup при завершении (защита cookie с токеном)
    trap 'api_logout 2>/dev/null || true' EXIT INT TERM

    # Шаг 1: GET страницы логина — получить session-cookie + CSRF-токен.
    _3xui_log "Login step 1: GET ${_3XUI_BASE_URL}/login (probe CSRF)"
    local login_html
    login_html="$(
        curl -sS \
            --max-time "$_3XUI_DEFAULT_TIMEOUT" \
            -c "$_3XUI_COOKIE_JAR" -b "$_3XUI_COOKIE_JAR" \
            "${_3XUI_BASE_URL}/login" \
            2>/dev/null
    )" || login_html=""

    # Попытка №1: CSRF в HTML-мете <meta name="csrf-token" content="...">.
    # `|| true` обязателен: скрипты скилла работают под `set -euo pipefail`, а на SPA-сборке
    # GET /login отдаёт пустое тело (CSRF берётся через /csrf-token ниже). grep-без-совпадения
    # под pipefail = exit 1 → без `|| true` роняет весь вызывающий скрипт ещё до fallback.
    _3XUI_CSRF_TOKEN="$(
        printf '%s' "$login_html" \
            | grep -oE '<meta[^>]+name="csrf-token"[^>]+content="[^"]+"' \
            | sed -E 's/.*content="([^"]+)".*/\1/' \
            | head -n1 || true
    )"

    # Попытка №2: отдельный endpoint /csrf-token (v3.0.x)
    if [ -z "$_3XUI_CSRF_TOKEN" ]; then
        local csrf_resp
        csrf_resp="$(
            curl -sS \
                --max-time "$_3XUI_DEFAULT_TIMEOUT" \
                -c "$_3XUI_COOKIE_JAR" -b "$_3XUI_COOKIE_JAR" \
                "${_3XUI_BASE_URL}/csrf-token" \
                2>/dev/null
        )" || csrf_resp=""
        _3XUI_CSRF_TOKEN="$(printf '%s' "$csrf_resp" \
            | jq -r '.token // .csrfToken // .obj // empty' 2>/dev/null)"
    fi

    if [ -n "$_3XUI_CSRF_TOKEN" ]; then
        _3XUI_PANEL_VERSION="v3+"
        _3xui_log "CSRF token acquired (panel v3.0+)"
    else
        _3XUI_PANEL_VERSION="legacy"
        _3xui_log "No CSRF token (panel likely v2.x — legacy login)"
    fi

    # Шаг 2: POST /login. Заголовок CSRF — только если токен есть.
    _3xui_log "Login step 2: POST ${_3XUI_BASE_URL}/login (admin=$admin, csrf=${_3XUI_PANEL_VERSION})"

    local curl_args=(
        -sS
        --max-time "$_3XUI_DEFAULT_TIMEOUT"
        -c "$_3XUI_COOKIE_JAR" -b "$_3XUI_COOKIE_JAR"
        -X POST
        -d "username=${admin}&password=${password}"
        -w "\n__HTTP_CODE__%{http_code}"
    )
    [ -n "$_3XUI_CSRF_TOKEN" ] && curl_args+=(-H "x-csrf-token: ${_3XUI_CSRF_TOKEN}")
    curl_args+=("${_3XUI_BASE_URL}/login")

    local raw
    raw="$(curl "${curl_args[@]}" 2>&1)" || {
        _3xui_die "Login: curl failed: $raw"
        return 1
    }
    local http_code response
    http_code="$(echo "$raw" | grep "__HTTP_CODE__" | sed 's/.*__HTTP_CODE__//')"
    response="$(echo "$raw" | grep -v "__HTTP_CODE__" || true)"

    # HTTP 403 = CSRF-middleware отбила запрос.
    # Это два сценария:
    #  - токен невалидный/просрочился — попробовать обновить и повторить;
    #  - токен не нашли, а на сервере на самом деле v3.0+ — повторить с GET /csrf-token.
    if [ "$http_code" = "403" ]; then
        _3xui_log "POST /login → 403 (CSRF rejected). Refreshing CSRF token and retrying."

        # Принудительно дёргаем /csrf-token эндпоинт ещё раз
        local csrf_resp2
        csrf_resp2="$(
            curl -sS \
                --max-time "$_3XUI_DEFAULT_TIMEOUT" \
                -c "$_3XUI_COOKIE_JAR" -b "$_3XUI_COOKIE_JAR" \
                "${_3XUI_BASE_URL}/csrf-token" \
                2>/dev/null
        )" || csrf_resp2=""
        local new_csrf
        new_csrf="$(printf '%s' "$csrf_resp2" \
            | jq -r '.token // .csrfToken // .obj // empty' 2>/dev/null)"

        if [ -z "$new_csrf" ]; then
            _3xui_die "Login: 403 на POST /login и не удалось получить CSRF-токен через /csrf-token. Проверь версию панели и доступ к /login через браузер."
            return 1
        fi

        _3XUI_CSRF_TOKEN="$new_csrf"
        _3XUI_PANEL_VERSION="v3+"

        local curl_args2=(
            -sS
            --max-time "$_3XUI_DEFAULT_TIMEOUT"
            -c "$_3XUI_COOKIE_JAR" -b "$_3XUI_COOKIE_JAR"
            -X POST
            -d "username=${admin}&password=${password}"
            -H "x-csrf-token: ${_3XUI_CSRF_TOKEN}"
            -w "\n__HTTP_CODE__%{http_code}"
            "${_3XUI_BASE_URL}/login"
        )
        raw="$(curl "${curl_args2[@]}" 2>&1)" || {
            _3xui_die "Login retry: curl failed: $raw"
            return 1
        }
        http_code="$(echo "$raw" | grep "__HTTP_CODE__" | sed 's/.*__HTTP_CODE__//')"
        response="$(echo "$raw" | grep -v "__HTTP_CODE__" || true)"
    fi

    if [ "$http_code" != "200" ]; then
        _3xui_die "Login: HTTP $http_code (ожидался 200). Тело ответа: $response"
        return 1
    fi

    local success
    success="$(echo "$response" | jq -r '.success // false' 2>/dev/null)"
    if [ "$success" != "true" ]; then
        local msg
        msg="$(echo "$response" | jq -r '.msg // "unknown error"' 2>/dev/null)"
        _3xui_die "Login failed: $msg"
        return 1
    fi

    _3xui_detect_api_variant
    _3xui_log "Login OK (cookie mode, panel=${_3XUI_PANEL_VERSION}, variant=${_3XUI_API_VARIANT})"
    return 0
}

# api_call METHOD ENDPOINT [--json-body JSON] [--form k=v]
# Возвращает тело ответа в stdout. Код 0 при success:true, 1 иначе.
api_call() {
    local method="$1"
    local endpoint="$2"
    shift 2

    if [ -z "$_3XUI_AUTH_MODE" ]; then
        _3xui_die "Не залогинены (вызови api_login сначала)"
        return 1
    fi
    if [ "$_3XUI_AUTH_MODE" = "cookie" ]; then
        [ -z "$_3XUI_COOKIE_JAR" ] && _3xui_die "Cookie jar пуст" && return 1
        [ ! -f "$_3XUI_COOKIE_JAR" ] && _3xui_die "Cookie jar не найден ($_3XUI_COOKIE_JAR)" && return 1
    fi

    local json_body=""
    local form_args=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --json-body) json_body="$2"; shift 2 ;;
            --form) form_args+=("-d" "$2"); shift 2 ;;
            --form-enc) form_args+=("--data-urlencode" "$2"); shift 2 ;;
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
    local csrf_retry_done=0

    while [ "$attempt" -lt "$max_attempts" ]; do
        attempt=$((attempt + 1))

        local curl_args=(
            -sS
            --max-time "$_3XUI_DEFAULT_TIMEOUT"
            -X "$method"
            -w "\n__HTTP_CODE__%{http_code}"
        )

        # Аутентификация по режиму
        if [ "$_3XUI_AUTH_MODE" = "bearer" ]; then
            curl_args+=(-H "Authorization: Bearer ${_3XUI_BEARER_TOKEN}")
        else
            curl_args+=(-b "$_3XUI_COOKIE_JAR")
            # На POST/PUT/DELETE и панели v3+ — пробрасываем CSRF, если есть.
            # На GET-запросах CSRF не нужен. На v2.x токена нет, заголовок не отправляется.
            if [ "$_3XUI_PANEL_VERSION" = "v3+" ] && [ -n "$_3XUI_CSRF_TOKEN" ] \
               && [ "$method" != "GET" ]; then
                curl_args+=(-H "x-csrf-token: ${_3XUI_CSRF_TOKEN}")
            fi
        fi

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
        http_code="$(echo "$response" | grep "__HTTP_CODE__" | sed 's/__HTTP_CODE__//' || true)"
        response="$(echo "$response" | grep -v "__HTTP_CODE__" || true)"

        if [ "$http_code" = "200" ]; then
            break
        elif [ "$http_code" = "403" ] && [ "$_3XUI_AUTH_MODE" = "cookie" ] && [ "$csrf_retry_done" -eq 0 ]; then
            # CSRF-middleware. Обновляем токен и повторяем — без увеличения delay.
            _3xui_log "Attempt $attempt: HTTP 403 (CSRF). Refreshing token..."
            local csrf_resp_new
            csrf_resp_new="$(
                curl -sS \
                    --max-time "$_3XUI_DEFAULT_TIMEOUT" \
                    -c "$_3XUI_COOKIE_JAR" -b "$_3XUI_COOKIE_JAR" \
                    "${_3XUI_BASE_URL}/csrf-token" \
                    2>/dev/null
            )" || csrf_resp_new=""
            local new_csrf
            new_csrf="$(printf '%s' "$csrf_resp_new" \
                | jq -r '.token // .csrfToken // .obj // empty' 2>/dev/null)"
            if [ -n "$new_csrf" ]; then
                _3XUI_CSRF_TOKEN="$new_csrf"
                _3XUI_PANEL_VERSION="v3+"
                csrf_retry_done=1
                attempt=$((attempt - 1))   # этот заход не считаем за полноценную попытку
                continue
            fi
            # Не смогли обновить — выходим как с обычной 4xx
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

# ─── Вариант API: legacy (§1–14) vs SPA-сборка 3.4.x+ (§15) — ADR-0020 ─────────
# ⚠️ SPA-ветки ниже РЕВЕРС-ИНЖИНИРЕНЫ с живой панели 3.4.2 (2026-07-14) и НЕ прогнаны
# автотестами. Проверять на реальной панели перед доверием (режим сисадмина, не /dev).
# Legacy-путь оставлен как был.

# _3xui_detect_api_variant — определить вариант панели ПОСЛЕ успешного логина.
# Эвристика (§15.1): у SPA-сборки работает server/getConfigJson; у legacy его нет (404).
_3xui_detect_api_variant() {
    if api_call GET "/panel/api/server/getConfigJson" >/dev/null 2>&1; then
        _3XUI_API_VARIANT="spa"
    else
        _3XUI_API_VARIANT="legacy"
    fi
    _3xui_log "API variant detected: ${_3XUI_API_VARIANT}"
}

# api_restart_xray — обязательный шаг после CRUD-операций
api_restart_xray() {
    _3xui_log "Restart Xray service (variant=${_3XUI_API_VARIANT:-legacy})"
    if [ "$_3XUI_API_VARIANT" = "spa" ]; then
        api_call POST "/panel/api/server/restartXrayService"
    else
        api_call POST "/panel/api/inbounds/restartXrayService"
    fi
}

# api_server_status — статус сервера/панели (для smoke-check)
api_server_status() {
    api_call POST "/panel/api/server/status"
}

# api_get_xray_config — текущий xray-конфиг (для редактирования outbounds/routing)
api_get_xray_config() {
    if [ "$_3XUI_API_VARIANT" = "spa" ]; then
        api_call GET "/panel/api/server/getConfigJson"
    else
        api_call GET "/panel/api/inbounds/getXrayConfig"
    fi
}

# api_update_xray_config "<json>" — обновить xray-конфиг (outbounds + routing)
api_update_xray_config() {
    local config_json="$1"
    if [ "$_3XUI_API_VARIANT" = "spa" ]; then
        # SPA (§15.3): тело FORM (xraySetting=<json-строка> + outboundTestUrl); и ОБЯЗАТЕЛЬНО
        # вычистить .inbounds до служебного api — иначе вход из БД дублируется в шаблоне и
        # xray падает 'existing tag found'. Пользовательские входы придут из БД сами.
        local stripped
        stripped="$(printf '%s' "$config_json" | jq -c '.inbounds=[.inbounds[]?|select(.tag=="api")]' 2>/dev/null)"
        # Fail-closed: если strip не удался (битый JSON) — НЕ откатываемся на неочищенный
        # конфиг (это ровно та беда, ради которой strip и делается: дубль тега → xray падает
        # 'existing tag found'). Лучше явная ошибка, чем молча уронить xray.
        if [ -z "$stripped" ] || [ "$stripped" = "null" ]; then
            _3xui_die "api_update_xray_config: не удалось вычистить .inbounds (некорректный JSON конфига?). Запись отменена — риск 'existing tag found'."
            return 1
        fi
        local leftover
        leftover="$(printf '%s' "$stripped" | jq '[.inbounds[]?|select(.tag!="api")]|length' 2>/dev/null)"
        if [ "${leftover:-1}" != "0" ]; then
            _3xui_die "api_update_xray_config: после strip в .inbounds остались пользовательские входы — запись отменена (риск дубля тега)."
            return 1
        fi
        api_call POST "/panel/api/xray/update" \
            --form-enc "xraySetting=${stripped}" \
            --form-enc "outboundTestUrl=${_3XUI_OUTBOUND_TEST_URL:-https://www.google.com/gen_204}"
    else
        api_call POST "/panel/api/inbounds/updateXrayConfig" --json-body "$config_json"
    fi
}

# api_add_client INBOUND_ID EMAIL [FLOW] [TOTAL_GB] [EXPIRY_MS] [LIMIT_IP] [UUID]
# Добавить клиента к входу. Модель данных разная (§15.3):
#   SPA    → POST clients/add {client:{...},inboundIds:[id]}. UUID генерит ПАНЕЛЬ — реальный
#            брать потом из inbounds/get/{id}, НЕ из ответа и НЕ передавать свой.
#   legacy → POST inbounds/addClient {id, settings:"{clients:[{id:uuid,...}]}"} (UUID нужен свой).
api_add_client() {
    local inbound_id="$1" email="$2" flow="${3:-}" total_gb="${4:-0}" expiry="${5:-0}" limit_ip="${6:-0}" uuid="${7:-}"
    [ -z "$inbound_id" ] && _3xui_die "api_add_client: нужен INBOUND_ID" && return 2
    [ -z "$email" ] && _3xui_die "api_add_client: нужен EMAIL" && return 2
    if [ "$_3XUI_API_VARIANT" = "spa" ]; then
        local body
        body="$(jq -nc --arg e "$email" --arg f "$flow" \
            --argjson g "$total_gb" --argjson x "$expiry" --argjson l "$limit_ip" --argjson id "$inbound_id" \
            '{client:({email:$e,enable:true,totalGB:$g,expiryTime:$x,limitIp:$l} + (if $f=="" then {} else {flow:$f} end)), inboundIds:[$id]}')"
        api_call POST "/panel/api/clients/add" --json-body "$body"
    else
        [ -z "$uuid" ] && uuid="$(api_gen_uuid)"
        local settings body
        settings="$(jq -nc --arg u "$uuid" --arg e "$email" --arg f "$flow" \
            --argjson g "$total_gb" --argjson x "$expiry" --argjson l "$limit_ip" \
            '{clients:[{id:$u,email:$e,flow:$f,enable:true,totalGB:$g,expiryTime:$x,limitIp:$l}]}')"
        body="$(jq -nc --argjson id "$inbound_id" --arg s "$settings" '{id:$id,settings:$s}')"
        api_call POST "/panel/api/inbounds/addClient" --json-body "$body"
    fi
}

# api_get_inbound INBOUND_ID — прочитать один вход (работает на обоих вариантах).
# ⚠️ Формат .obj.settings РАЗНЫЙ: на SPA — native-ОБЪЕКТ, на legacy — JSON-СТРОКА.
# Потребитель, разбирающий клиентов, ОБЯЗАН нормализовать:
#   (.obj.settings | if type=="string" then fromjson else . end)
# Готовые хелперы ниже (api_get_client_uuid) это уже делают — используй их, не парси вручную.
api_get_inbound() {
    local inbound_id="$1"
    [ -z "$inbound_id" ] && _3xui_die "api_get_inbound: нужен INBOUND_ID" && return 2
    api_call GET "/panel/api/inbounds/get/${inbound_id}"
}

# api_get_client_uuid INBOUND_ID EMAIL — вернуть реальный UUID клиента по email.
# На SPA UUID генерит панель (в ответе clients/add его НЕТ) — забрать можно только так.
# Нормализует settings (объект|строка), поэтому безопасен на обоих вариантах.
api_get_client_uuid() {
    local inbound_id="$1" email="$2"
    [ -z "$inbound_id" ] && _3xui_die "api_get_client_uuid: нужен INBOUND_ID" && return 2
    [ -z "$email" ] && _3xui_die "api_get_client_uuid: нужен EMAIL" && return 2
    api_get_inbound "$inbound_id" \
        | jq -r --arg e "$email" \
            '(.obj.settings | if type=="string" then fromjson else . end)
             | .clients[]? | select(.email==$e) | .id' 2>/dev/null \
        | head -n1
}

# api_del_client EMAIL [INBOUND_ID] [UUID] [KEEP_TRAFFIC]
# Удалить клиента. Модель удаления РАЗНАЯ (проверено на живой SPA 3.4.2):
#   SPA    → POST clients/del/{EMAIL}[?keepTraffic=1]. Ключ — EMAIL (НЕ uuid, НЕ числовой id!).
#            Клиент — отдельная email-ключевая сущность (таблицы clients/client_inbounds).
#   legacy → POST inbounds/{INBOUND_ID}/delClient/{UUID}. Ключ — UUID (внутри inbound.settings).
# На legacy, если UUID не передан, но передан INBOUND_ID — резолвим UUID по email.
# KEEP_TRAFFIC="keep" → сохранить статистику трафика клиента (только SPA).
api_del_client() {
    local email="$1" inbound_id="${2:-}" uuid="${3:-}" keep="${4:-}"
    [ -z "$email" ] && _3xui_die "api_del_client: нужен EMAIL" && return 2
    if [ "$_3XUI_API_VARIANT" = "spa" ]; then
        local ep="/panel/api/clients/del/$(_3xui_urlencode "$email")"
        [ "$keep" = "keep" ] && ep="${ep}?keepTraffic=1"
        api_call POST "$ep"
    else
        [ -z "$inbound_id" ] && _3xui_die "api_del_client (legacy): нужен INBOUND_ID" && return 2
        if [ -z "$uuid" ]; then
            uuid="$(api_get_client_uuid "$inbound_id" "$email")"
        fi
        [ -z "$uuid" ] && _3xui_die "api_del_client (legacy): не удалось определить UUID клиента '$email'" && return 1
        api_call POST "/panel/api/inbounds/${inbound_id}/delClient/${uuid}"
    fi
}

# api_list_inbounds — список inbound-ов (работает на обоих вариантах)
api_list_inbounds() {
    api_call GET "/panel/api/inbounds/list"
}

# api_add_inbound INBOUND_JSON — создать вход. Возвращает ответ {success,obj:{id,tag,port,...}}.
# INBOUND_JSON — объект с полями remark,port,protocol,listen,enable,expiryTime и
# settings/streamSettings/sniffing как JSON-СТРОКАМИ (как строит create-vless-inbound.sh).
# Ветвление по варианту (контракт SPA проверен на живой панели 3.4.2, 2026-07-15):
#   SPA    → form-urlencoded; settings/streamSettings/sniffing уходят строками.
#   legacy → JSON-тело целиком.
# ⚠️ tag присваивает ПАНЕЛЬ (формат in-<port>-<network>, напр. in-443-tcp) — брать из
#    .obj.tag ответа, НЕ выдумывать локально. На SPA клиентов в settings НЕ встраивай —
#    заводи отдельно через api_add_client (клиент — email-ключевая сущность).
api_add_inbound() {
    local inbound_json="$1"
    [ -z "$inbound_json" ] && _3xui_die "api_add_inbound: нужен INBOUND_JSON" && return 2
    if [ "$_3XUI_API_VARIANT" = "spa" ]; then
        local remark port protocol listen enable expiry settings stream sniffing
        remark="$(jq -r '.remark // ""' <<<"$inbound_json")"
        port="$(jq -r '.port' <<<"$inbound_json")"
        protocol="$(jq -r '.protocol' <<<"$inbound_json")"
        listen="$(jq -r '.listen // ""' <<<"$inbound_json")"
        enable="$(jq -r '.enable // true' <<<"$inbound_json")"
        expiry="$(jq -r '.expiryTime // 0' <<<"$inbound_json")"
        # settings/streamSettings/sniffing: строкой берём как есть, объект — сериализуем.
        settings="$(jq -r '.settings | if type=="string" then . else tojson end' <<<"$inbound_json")"
        stream="$(jq -r '.streamSettings | if type=="string" then . else tojson end' <<<"$inbound_json")"
        sniffing="$(jq -r '.sniffing | if type=="string" then . else tojson end' <<<"$inbound_json")"
        api_call POST "/panel/api/inbounds/add" \
            --form-enc "remark=${remark}" \
            --form-enc "enable=${enable}" \
            --form-enc "expiryTime=${expiry}" \
            --form-enc "listen=${listen}" \
            --form-enc "port=${port}" \
            --form-enc "protocol=${protocol}" \
            --form-enc "settings=${settings}" \
            --form-enc "streamSettings=${stream}" \
            --form-enc "sniffing=${sniffing}"
    else
        api_call POST "/panel/api/inbounds/add" --json-body "$inbound_json"
    fi
}

# api_del_inbound INBOUND_ID — удалить вход (POST inbounds/del/{id}; работает на обоих вариантах).
api_del_inbound() {
    local id="$1"
    [ -z "$id" ] && _3xui_die "api_del_inbound: нужен INBOUND_ID" && return 2
    api_call POST "/panel/api/inbounds/del/${id}"
}

# api_logout — очистка cookie/токена и состояния
api_logout() {
    if [ "$_3XUI_AUTH_MODE" = "cookie" ] && [ -n "$_3XUI_COOKIE_JAR" ] && [ -f "$_3XUI_COOKIE_JAR" ]; then
        # Best-effort: вызываем /logout если есть, потом удаляем cookie.
        # На v3+ /logout сам требует CSRF — пробрасываем заголовок если есть.
        local logout_args=(-sS --max-time 5 -b "$_3XUI_COOKIE_JAR" -X GET)
        [ -n "$_3XUI_CSRF_TOKEN" ] && logout_args+=(-H "x-csrf-token: ${_3XUI_CSRF_TOKEN}")
        logout_args+=("${_3XUI_BASE_URL}/logout")
        curl "${logout_args[@]}" >/dev/null 2>&1 || true
        rm -f "$_3XUI_COOKIE_JAR"
    fi
    _3XUI_COOKIE_JAR=""
    _3XUI_BEARER_TOKEN=""
    _3XUI_CSRF_TOKEN=""
    _3XUI_AUTH_MODE=""
    _3XUI_PANEL_VERSION=""
    _3XUI_API_VARIANT=""
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
        keepassxc)
            _3xui_require keepassxc-cli
            local kdbx="${KEEPASSXC_DB:-}"
            [ -z "$kdbx" ] && _3xui_die "keepassxc: не задан KEEPASSXC_DB" && return 1
            # stdin: строка1 = мастер-пароль БД, строка2 = пароль записи (для флага -p).
            # ВНИМАНИЕ: create-only. Если запись уже есть — keepassxc-cli add вернёт ошибку;
            # обновление существующей — через keepassxc-cli edit (здесь не делаем).
            local kf_args=()
            [ -n "${KEEPASSXC_KEYFILE:-}" ] && kf_args=(-k "$KEEPASSXC_KEYFILE")
            printf '%s\n%s\n' "${KEEPASSXC_PASSWORD:-}" "$secret" \
                | keepassxc-cli add "${kf_args[@]}" \
                    -u "$account" \
                    ${url:+--url "$url"} \
                    -p \
                    "$kdbx" "$service" >/dev/null 2>&1
            ;;
        *)
            _3xui_die "Неизвестный менеджер паролей: $manager"
            return 1
            ;;
    esac

    return 0
}
