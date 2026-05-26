#!/bin/bash
# setup-routing.sh — настроить routing rules в xray-конфиге по «золотой
# середине» (см. эталон 16-ЭТАЛОН-гибкой-маршрутизации-3xui.md §2.5).
#
# Генерирует 7 правил (сверху вниз, первое совпавшее применяется):
#   1. inboundTag=api                          → api      (служебное, если есть api-inbound)
#   2. ip=geoip:private                        → direct   (локальная сеть; НЕ blocked!)
#   3. protocol=bittorrent                     → blocked
#   4. domain=geosite:category-ads-all         → blocked  (реклама раньше всего)
#   5. ip=geoip:ru                             → direct   (топ-РФ-сервисы по IP)
#   6. domain=[geosite:category-ru, .ru/.su/.рф regex] → direct
#   7. default (vless/mixed inbounds)          → balancerTag/outboundTag upstream
#
#  - Явный список РФ-доменов НЕ добавляем (research §2.6: топ-сервисы на РФ-IP,
#    ловятся правилом 5; домены типа tinkoff.com выдуманы).
#  - geoip:private → direct (а не объединять в одно правило и не blocked).
#  - blackhole-outbound "blocked" создаётся, если его нет (для рекламы/bittorrent).
#  - balancer объединяет несколько upstream outbound-ов (если >1).
#  - observatory для leastPing/leastLoad-балансировки.
#
# Вход через ENV:
#   PANEL_DOMAIN, PANEL_PORT, WEB_BASE_PATH, ADMIN_LOGIN, PASSWORD_REF
#   UPSTREAM_TAGS_JSON  — JSON-массив тегов outbound-ов: ["upstream-de", "upstream-nl"]
#   UPSTREAM_COUNTRIES_JSON — (опц.) JSON-массив кодов стран ПАРАЛЛЕЛЬНО тегам:
#                        ["us","us","us"]. Источник — enriched-JSON Шага 5A
#                        (поле .country по slug). Нужен для guard «разные страны
#                        в балансире» (см. ниже). НЕ парсим страну из имени тега —
#                        тег может быть upstream-blanc-usa/upstream-server, угадывание
#                        страны = нарушение правила №1 CLAUDE.md. Если не передан —
#                        страну тега считаем "?" → guard срабатывает в сторону
#                        безопасности (лучше переспросить, чем молча собрать мульти-кантри).
#   CONFIRM_MULTI_COUNTRY — yes | no (default: no). Осознанное согласие собрать
#                        балансир из серверов РАЗНЫХ стран (скачущий IP). По умолчанию
#                        запрещено — exit 3 с менторским объяснением. Симметрично
#                        CONFIRM_REALITY_ON_RU в create-vless-inbound.sh.
#   BALANCER_STRATEGY   — random | roundRobin | leastPing | leastLoad (default: leastPing)
#   USE_BALANCER        — yes | no (default: auto — yes если UPSTREAM_TAGS > 1)
#   PROBE_INTERVAL      — как часто observatory переоценивает серверы (default: 5m).
#                         ВАЖНО: 3X-UI по умолчанию ставит 1m — это часто, IP «скачет»
#                         между близкими по пингу серверами. 5m = реже переоценка =
#                         клиент дольше держится за один сервер. См. эталон §2.7.
#   PROBE_SAMPLING      — сколько замеров усреднять (для leastLoad/burstObservatory;
#                         default: 4 вместо дефолтных 2 — сглаживает всплески пинга).
#   INBOUND_TAGS_JSON   — JSON-массив тегов inbound-ов, к которым применяется
#                         default-правило (default: все vless/mixed inbound из list)
#
# ПРО ПРИЛИПАНИЕ К IP (важно для предсказуемого выхода):
#   Балансир 3X-UI/Xray НЕ умеет sticky-гистерезис («держись пока не станет хуже
#   на N мс» — это клиентский sing-box urltest.tolerance, не серверный). На сервере
#   стабильность IP достигается двумя рычагами:
#     1. selector из серверов ОДНОЙ страны → даже при failover страна та же,
#        аккаунты не банятся за «прыжки по странам». ЭТО ПРОВЕРЯЕТ guard ниже:
#        разные страны в балансире без CONFIRM_MULTI_COUNTRY=yes → exit 3.
#     2. PROBE_INTERVAL=5m → редкая переоценка → редкие переключения.
#   Для АБСОЛЮТНО неизменного IP — один сервер в selector (USE_BALANCER=no).
#   leastPing-балансир здесь = механизм FAILOVER (мёртвый сервер исключается
#   observatory), а не «выбираю быстрейший на каждом запросе».
#
# Выход (на stdout): JSON с описанием применённой схемы.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
LIB="${REPO_ROOT}/scripts/lib-api/3xui.sh"
# shellcheck source=/dev/null
source "$LIB"

PANEL_DOMAIN="${PANEL_DOMAIN:?обязателен}"
PANEL_PORT="${PANEL_PORT:?обязателен}"
WEB_BASE_PATH="${WEB_BASE_PATH:?обязателен}"
ADMIN_LOGIN="${ADMIN_LOGIN:?обязателен}"
PASSWORD_REF="${PASSWORD_REF:?обязателен}"
UPSTREAM_TAGS_JSON="${UPSTREAM_TAGS_JSON:?UPSTREAM_TAGS_JSON обязателен (например, [\"upstream-de\"])}"
BALANCER_STRATEGY="${BALANCER_STRATEGY:-leastPing}"
# Реже дефолтного 1m — чтобы клиент дольше держался за один сервер (меньше «скачков» IP).
PROBE_INTERVAL="${PROBE_INTERVAL:-5m}"
# Больше дефолтного 2 — усреднение сглаживает случайные всплески пинга.
PROBE_SAMPLING="${PROBE_SAMPLING:-4}"

# Парсим массив upstream-тегов
UPSTREAM_COUNT="$(echo "$UPSTREAM_TAGS_JSON" | jq 'length')"
if [ "$UPSTREAM_COUNT" -lt 1 ]; then
    echo "ERROR: UPSTREAM_TAGS_JSON пустой" >&2
    exit 2
fi

# Auto-balancer: yes если >1 upstream
USE_BALANCER="${USE_BALANCER:-auto}"
if [ "$USE_BALANCER" = "auto" ]; then
    if [ "$UPSTREAM_COUNT" -gt 1 ]; then
        USE_BALANCER="yes"
    else
        USE_BALANCER="no"
    fi
fi

# --- Guard: разные страны в одном балансире = «скачущий IP» = риск бана нейросетями ---
# Антифрод OpenAI/Anthropic/Google смотрит на СТАБИЛЬНОСТЬ выходного fingerprint,
# а не на «забанена ли страна». Смена страны внутри сессии (Германия→США→Франция)
# = паттерн угона аккаунта/ботнета → капчи, ре-логины, верификация, бан. Скачущий
# IP НЕ обходит блокировку — он сам ЯВЛЯЕТСЯ её триггером. Поэтому балансир по
# умолчанию = серверы ОДНОЙ страны (см. ADR про политику балансира, рефлекс 3.8.6).
#
# НЕ запрет — информированный выбор: легитимный кейс «самый быстрый пинг любой ценой,
# НЕ для нейронок» возможен через CONFIRM_MULTI_COUNTRY=yes.
#
# Страну каждого тега берём из UPSTREAM_COUNTRIES_JSON (параллельно тегам). НЕ
# угадываем из имени тега (правило №1 CLAUDE.md). Неизвестную страну считаем "?" —
# два разных "?" = разные страны → guard срабатывает в сторону безопасности.
if [ "$USE_BALANCER" = "yes" ]; then
    if [ -n "${UPSTREAM_COUNTRIES_JSON:-}" ]; then
        # Нормализуем: пустые/null → "?", приводим к нижнему регистру.
        DISTINCT_COUNTRIES="$(echo "$UPSTREAM_COUNTRIES_JSON" \
            | jq -r '.[] | (. // "?") | if . == "" then "?" else ascii_downcase end' \
            | sort -u | grep -c . || true)"
    else
        # Список стран не передан — не можем подтвердить, что страна одна.
        # Безопасный дефолт: считаем как неопределённость (>1), требуем подтверждения.
        DISTINCT_COUNTRIES=2
    fi

    if [ "$DISTINCT_COUNTRIES" -gt 1 ] && [ "${CONFIRM_MULTI_COUNTRY:-no}" != "yes" ]; then
        cat >&2 <<'EOF'
⛔ Балансир собирается из серверов РАЗНЫХ стран (либо страна серверов не подтверждена).

  Выходной IP будет «прыгать» между странами. Для антифрода нейросетей
  (OpenAI / Anthropic / Google) смена страны внутри сессии = паттерн угона
  аккаунта: капчи, ре-логины, запрос верификации телефона, в худшем случае бан.
  Скачущий IP НЕ обходит блокировку — он САМ является её триггером.

  Это НЕ запрет. Варианты:
   • Для работы с нейронками — собери балансир из серверов ОДНОЙ страны
     (передай UPSTREAM_COUNTRIES_JSON с одинаковым кодом, например ["us","us"]).
   • Если задача — «самый быстрый пинг любой ценой» и это НЕ для нейронок —
     повтори запуск с CONFIRM_MULTI_COUNTRY=yes (осознанный выбор оператора).
   • Если просто не передал страны — добавь UPSTREAM_COUNTRIES_JSON, чтобы guard
     убедился, что страна действительно одна.
EOF
        exit 3
    fi
fi

api_login \
    --domain "$PANEL_DOMAIN" \
    --port "$PANEL_PORT" \
    --web-path "$WEB_BASE_PATH" \
    --admin "$ADMIN_LOGIN" \
    --password-ref "$PASSWORD_REF"

# Текущий конфиг
CURRENT_CONFIG="$(api_call GET "/panel/api/inbounds/getXrayConfig" | jq '.obj')"

# Определяем INBOUND_TAGS — все vless inbounds, если не передано
if [ -z "${INBOUND_TAGS_JSON:-}" ]; then
    INBOUND_TAGS_JSON="$(api_call GET "/panel/api/inbounds/list" \
        | jq '[.obj[] | select(.protocol == "vless" or .protocol == "mixed") | .tag]')"
fi

# Убедимся, что direct outbound есть (РФ-трафик выходит с IP сервера)
HAS_DIRECT="$(echo "$CURRENT_CONFIG" | jq '[.outbounds[]? | select(.tag == "direct")] | length')"
if [ "$HAS_DIRECT" -eq 0 ]; then
    DIRECT_OUTBOUND='{"tag":"direct","protocol":"freedom","settings":{}}'
    CURRENT_CONFIG="$(echo "$CURRENT_CONFIG" | jq --argjson o "$DIRECT_OUTBOUND" '.outbounds = ((.outbounds // []) + [$o])')"
fi

# Убедимся, что blocked outbound (blackhole) есть — нужен для правил
# реклама → blocked и bittorrent → blocked (§2.5 правила 3,4).
HAS_BLOCKED="$(echo "$CURRENT_CONFIG" | jq '[.outbounds[]? | select(.tag == "blocked")] | length')"
if [ "$HAS_BLOCKED" -eq 0 ]; then
    BLOCKED_OUTBOUND='{"tag":"blocked","protocol":"blackhole","settings":{}}'
    CURRENT_CONFIG="$(echo "$CURRENT_CONFIG" | jq --argjson o "$BLOCKED_OUTBOUND" '.outbounds = ((.outbounds // []) + [$o])')"
fi

# --- Правила 1..6 (общие для balancer и single-upstream) -------------------
# Порядок критичен: сверху вниз, первое совпавшее применяется (§2.5).
#   1. inboundTag=api      → api      (служебное; добавляется ТОЛЬКО если в конфиге
#                                      есть api-блок/inbound — иначе Xray отклонит
#                                      правило с несуществующим outboundTag "api")
#   2. geoip:private       → direct   (НЕ blocked)
#   3. bittorrent          → blocked
#   4. category-ads-all    → blocked  (реклама раньше РФ-правил)
#   5. geoip:ru            → direct
#   6. category-ru + regex → direct
# Примечание про .рф: Xray regexp работает по punycode → .+\.xn--p1ai$.

# Правило 1 (api) — только если панель реально использует api-сервис.
# 3X-UI по умолчанию ставит api-inbound + api-блок, но если их нет — правило
# с outboundTag:"api" сломает конфиг. Поэтому добавляем условно.
HAS_API="$(echo "$CURRENT_CONFIG" | jq '
    ((.api // null) != null)
    or ([.inbounds[]? | select(.tag == "api")] | length > 0)
    or ([.routing.rules[]? | select((.inboundTag // []) | index("api"))] | length > 0)
')"
if [ "$HAS_API" = "true" ]; then
    API_RULE='[{"type":"field","inboundTag":["api"],"outboundTag":"api"}]'
else
    API_RULE='[]'
    echo "[routing] api-блок в конфиге не найден — правило inboundTag=api пропущено" >&2
fi

HEAD_RULES="$(jq -nc --argjson apirule "$API_RULE" '$apirule + [
    {
        type: "field",
        ip: ["geoip:private"],
        outboundTag: "direct"
    },
    {
        type: "field",
        protocol: ["bittorrent"],
        outboundTag: "blocked"
    },
    {
        type: "field",
        domain: ["geosite:category-ads-all"],
        outboundTag: "blocked"
    },
    {
        type: "field",
        ip: ["geoip:ru"],
        outboundTag: "direct"
    },
    {
        type: "field",
        domain: [
            "geosite:category-ru",
            "regexp:.+\\.ru$",
            "regexp:.+\\.su$",
            "regexp:.+\\.xn--p1ai$"
        ],
        outboundTag: "direct"
    }
]')"

# Формируем routing rules и опционально balancer
if [ "$USE_BALANCER" = "yes" ]; then
    # Balancer
    BALANCER_OBJ="$(jq -nc \
        --argjson selector "$UPSTREAM_TAGS_JSON" \
        --arg strategy "$BALANCER_STRATEGY" \
        '{
            tag: "upstream-balancer",
            selector: $selector,
            strategy: { type: $strategy },
            fallbackTag: "direct"
        }')"

    # Observatory (нужен для leastPing/leastLoad).
    # probeInterval = PROBE_INTERVAL (default 5m, НЕ 30s/1m) — реже переоценка,
    # клиент дольше держится за один сервер → стабильнее IP (см. шапку скрипта).
    if [ "$BALANCER_STRATEGY" = "leastPing" ] || [ "$BALANCER_STRATEGY" = "leastLoad" ]; then
        OBSERVATORY_OBJ="$(jq -nc \
            --argjson selector "$UPSTREAM_TAGS_JSON" \
            --arg interval "$PROBE_INTERVAL" \
            '{
                subjectSelector: $selector,
                probeUrl: "http://www.google.com/gen_204",
                probeInterval: $interval
            }')"
    else
        OBSERVATORY_OBJ="null"
    fi

    # Правило 7 (default): vless/mixed inbounds → upstream-balancer
    ROUTE_RULES="$(jq -nc \
        --argjson head "$HEAD_RULES" \
        --argjson inbounds "$INBOUND_TAGS_JSON" \
        '$head + [
            {
                type: "field",
                inboundTag: $inbounds,
                balancerTag: "upstream-balancer"
            }
        ]')"

    NEW_CONFIG="$(echo "$CURRENT_CONFIG" | jq \
        --argjson balancer "$BALANCER_OBJ" \
        --argjson observatory "$OBSERVATORY_OBJ" \
        --argjson rules "$ROUTE_RULES" \
        '
        .routing = {
            domainStrategy: "IPIfNonMatch",
            balancers: [$balancer],
            rules: $rules
        }
        | if $observatory != null then .observatory = $observatory else . end
        ')"
else
    # Один upstream — без balancer, default-правило шлёт на единственный outbound
    SINGLE_UPSTREAM="$(echo "$UPSTREAM_TAGS_JSON" | jq -r '.[0]')"

    # Правило 7 (default): vless/mixed inbounds → единственный upstream
    ROUTE_RULES="$(jq -nc \
        --argjson head "$HEAD_RULES" \
        --argjson inbounds "$INBOUND_TAGS_JSON" \
        --arg upstream "$SINGLE_UPSTREAM" \
        '$head + [
            {
                type: "field",
                inboundTag: $inbounds,
                outboundTag: $upstream
            }
        ]')"

    NEW_CONFIG="$(echo "$CURRENT_CONFIG" | jq \
        --argjson rules "$ROUTE_RULES" \
        '.routing = {
            domainStrategy: "IPIfNonMatch",
            rules: $rules
        }')"
fi

# Обновляем конфиг
echo "[routing] Применяю routing: balancer=$USE_BALANCER, upstream_count=$UPSTREAM_COUNT, strategy=$BALANCER_STRATEGY" >&2
api_update_xray_config "$NEW_CONFIG" >&2

api_restart_xray >&2

echo "[routing] ✓ Routing применён" >&2

# Финальный отчёт (rules_count = 7 если есть api-правило, иначе 6)
RULES_COUNT="$(echo "$ROUTE_RULES" | jq 'length')"
jq -nc \
    --arg use_balancer "$USE_BALANCER" \
    --arg strategy "$BALANCER_STRATEGY" \
    --argjson upstream_tags "$UPSTREAM_TAGS_JSON" \
    --argjson inbound_tags "$INBOUND_TAGS_JSON" \
    --argjson rules_count "$RULES_COUNT" \
    '{
        use_balancer: $use_balancer,
        strategy: $strategy,
        upstream_tags: $upstream_tags,
        inbound_tags: $inbound_tags,
        rules_count: $rules_count,
        model: "golden-middle (geoip:private→direct, ads→block, bittorrent→block, geoip:ru→direct, category-ru+regex→direct, default→upstream)"
    }'

api_logout >&2
exit 0
