#!/usr/bin/env bash
# assemble-configs.sh — сборка ДВУХ draft-конфигов (Шаг 8 скилла sysadmin-init).
#
# ДВА РЕЖИМА, и разница между ними принципиальная:
#
#   ПЕРВИЧНЫЙ (AGENT_CURRENT/INFRA_CURRENT не заданы) — база draft'а это пустой skeleton,
#   обязательные переменные обязаны быть заданы все. Так настраивается новый оператор.
#
#   СЛИЯНИЕ (AGENT_CURRENT=<путь> и/или INFRA_CURRENT=<путь>) — база draft'а это СУЩЕСТВУЮЩИЙ
#   конфиг оператора, а переменные окружения перекрывают ТОЛЬКО то, что реально задано.
#   Всё остальное — включая блоки, о которых этот скрипт и скилл не знают вовсе
#   (`state`, `map`, будущие) — переносится как есть.
#
# ЗАЧЕМ РЕЖИМ СЛИЯНИЯ (аудит 2026-09-24, ADR-0042). Раньше `--reconfigure` тоже собирал
# файл из skeleton'а и писал поверх живого. Ради правки одного блока оператор молча терял:
# `state` (паспорт автосборки снимка — агент слепнет на диагностике), второй сервер в
# `servers[]` (массив присваивался одним элементом), `vpn` (адрес панели, роль сервера,
# вид upstream), `monitoring.kind`, канал Telegram, лишние записи в `projects[]` мозга,
# `meta.onboarding_completed`. В тексте скилла при этом стояло обещание «panel_url и meta
# не затираю» — кода за ним не было. Проверки после записи потерю не ловили и печатали
# «✅ проверено». Теперь обещание держит код, а не проза.
#
# Использование:
#   NAME=... LANG=ru TIMEZONE=... MANAGER=keychain PROJ_ID=... PROJ_INFRA_ROOT=... \
#   SRV_ALIAS=... SRV_SSH=... SRV_ROLE=production \
#   [MON_ENABLED=true MON_STACK_JSON='["uptime-kuma"]' MON_PANEL_DOMAIN=... [MON_KIND=custom]] \
#   [BACKUPS_ENABLED=true BACKUPS_DESTINATION=yandex-disk-webdav \
#     BACKUPS_RETENTION_JSON='{"daily":7,"weekly":4,"monthly":6}' BACKUPS_RCLONE_REMOTE=yandex-disk] \
#   [BACKUPS_ENABLED=true BACKUPS_DESTINATION=sftp \
#     BACKUPS_SFTP_HOST=<ssh-алиас источника> BACKUPS_SFTP_PATH=/repo [BACKUPS_SFTP_USER=...]] \
#   [TG_ENABLED=true TG_BOT_USERNAME=mybot TG_CHAT_TYPE=personal] \
#   [VPN_ENABLED=true [VPN_REALITY_DEST=www.cloudflare.com]] \
#   [AGENT_CURRENT=<путь к живому agent-config.json>] [INFRA_CURRENT=<путь к живому infra-config.json>] \
#   assemble-configs.sh <workdir> [<sysadmin_root>]
#
# Контракт переменных (мозг): NAME, LANG(ru|en), TIMEZONE, MANAGER(enum),
#   CLI_AVAILABLE(true|false; для известных менеджеров выставляется автоматически),
#   MANAGER_NAME(для manager=other), PROJ_ID, PROJ_TITLE(опц., ""→без title), PROJ_INFRA_ROOT,
#   PROJ_MAKE_DEFAULT(опц., true → сделать этот проект активным; при первичной настройке всегда).
# Контракт переменных (карта): SRV_ALIAS, SRV_SSH, SRV_ROLE(enum), SRV_DOMAIN(опц.),
#   MON_*, BACKUPS_* (retention — ОБЪЕКТ {daily,weekly,monthly}, НЕ строка!), TG_*, VPN_*.
#
# В режиме слияния обязательных переменных нет: что не задано — то не трогается.
# Заданная переменная перекрывает соответствующее поле, остальной файл остаётся прежним.
#
# Возврат: 0 — оба draft'а собраны; 1 — нет аргументов / нет jq / не хватает обязательного
# поля (только первичный режим) / указанный *_CURRENT не читается или не JSON.

set -u

WORKDIR="${1:-}"
SYSADMIN_ROOT="${2:-${SYSADMIN_ROOT:-}}"

[ -n "$WORKDIR" ] || { echo "ERROR: usage: assemble-configs.sh <workdir> [<sysadmin_root>]" >&2; exit 1; }
[ -d "$WORKDIR" ] || { echo "ERROR: нет каталога WORKDIR: $WORKDIR" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq не найден" >&2; exit 1; }

# Корень репо — для skeleton'ов. Если не передан/не задан — выводим от расположения скрипта.
if [ -z "$SYSADMIN_ROOT" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
    SYSADMIN_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
fi
TPL="$SYSADMIN_ROOT/.claude/skills/sysadmin-init/templates"
[ -f "$TPL/agent-config-skeleton.json" ] || { echo "ERROR: не найден skeleton мозга: $TPL/agent-config-skeleton.json" >&2; exit 1; }

AGENT_CURRENT="${AGENT_CURRENT:-}"
INFRA_CURRENT="${INFRA_CURRENT:-}"

# Указанный существующий конфиг обязан читаться и быть валидным JSON. Иначе — ГРОМКИЙ отказ:
# молча свалиться на skeleton значит устроить ровно ту потерю, от которой защищает слияние.
for pair in "AGENT_CURRENT:$AGENT_CURRENT" "INFRA_CURRENT:$INFRA_CURRENT"; do
    _name="${pair%%:*}"; _path="${pair#*:}"
    [ -n "$_path" ] || continue
    [ -f "$_path" ] || { echo "ERROR: $_name указывает на несуществующий файл: $_path" >&2; exit 1; }
    jq empty "$_path" >/dev/null 2>&1 || { echo "ERROR: $_name не разбирается как JSON: $_path" >&2; exit 1; }
done

MERGE_AGENT=false; [ -n "$AGENT_CURRENT" ] && MERGE_AGENT=true
MERGE_INFRA=false; [ -n "$INFRA_CURRENT" ] && MERGE_INFRA=true

# Обязательные поля — только в первичном режиме (в слиянии молчание = «оставить как было»).
if [ "$MERGE_AGENT" != "true" ]; then
    for v in NAME LANG TIMEZONE MANAGER PROJ_ID PROJ_INFRA_ROOT; do
        eval "val=\${$v:-}"
        [ -n "$val" ] || { echo "ERROR: не задана обязательная переменная окружения: $v" >&2; exit 1; }
    done
fi
if [ "$MERGE_INFRA" != "true" ]; then
    for v in SRV_ALIAS SRV_SSH SRV_ROLE; do
        eval "val=\${$v:-}"
        [ -n "$val" ] || { echo "ERROR: не задана обязательная переменная окружения: $v" >&2; exit 1; }
    done
fi

AGENT_DRAFT="$WORKDIR/agent-config-draft.json"
INFRA_DRAFT="$WORKDIR/infra-config-draft.json"
_x="$WORKDIR/.assemble.tmp"
_apply() { mv "$_x" "$1"; }   # $1 = целевой draft

# ── Мозг (agent-config-draft.json) ────────────────────────────────────────────
if [ "$MERGE_AGENT" = "true" ]; then cp "$AGENT_CURRENT" "$AGENT_DRAFT"
else cp "$TPL/agent-config-skeleton.json" "$AGENT_DRAFT"; fi

# operator: каждое поле — только если задано.
[ -n "${NAME:-}" ]     && { jq --arg n "$NAME"      '.operator.name=$n'      "$AGENT_DRAFT" > "$_x" && _apply "$AGENT_DRAFT"; }
[ -n "${LANG:-}" ]     && { jq --arg l "$LANG"      '.operator.language=$l'  "$AGENT_DRAFT" > "$_x" && _apply "$AGENT_DRAFT"; }
[ -n "${TIMEZONE:-}" ] && { jq --arg tz "$TIMEZONE" '.operator.timezone=$tz' "$AGENT_DRAFT" > "$_x" && _apply "$AGENT_DRAFT"; }

# secrets: для известных менеджеров CLI есть всегда → cli_available=true; для other — из ресёрча.
if [ -n "${MANAGER:-}" ]; then
    case "$MANAGER" in
        keychain|bitwarden|1password|pass|keepassxc) CLI_AVAILABLE=true ;;
        other) CLI_AVAILABLE="${CLI_AVAILABLE:-false}" ;;
        *) echo "ERROR: неизвестный MANAGER='$MANAGER' (не из enum схемы)" >&2; exit 1 ;;
    esac
    jq --arg m "$MANAGER" --argjson cli "$CLI_AVAILABLE" \
       '.secrets.manager=$m | .secrets.cli_available=$cli' "$AGENT_DRAFT" > "$_x" && _apply "$AGENT_DRAFT"
    if [ "$MANAGER" = "other" ]; then
        jq --arg mn "${MANAGER_NAME:-}" '.secrets.manager_name=$mn' "$AGENT_DRAFT" > "$_x" && _apply "$AGENT_DRAFT"
    fi
fi

# projects: ДОПИСЫВАЕМ или обновляем запись по id, а не затираем реестр (аудит 2026-09-24).
# default_project трогаем при первичной настройке и по явному PROJ_MAKE_DEFAULT=true.
if [ -n "${PROJ_ID:-}" ]; then
    _mkdef=false
    [ "$MERGE_AGENT" != "true" ] && _mkdef=true
    [ "${PROJ_MAKE_DEFAULT:-}" = "true" ] && _mkdef=true
    jq --arg id "$PROJ_ID" --arg title "${PROJ_TITLE:-}" --arg root "${PROJ_INFRA_ROOT:-}" \
       --argjson mkdef "$_mkdef" '
        ( [ (.projects // [])[] | select(.id == $id) ] | first // {id:$id} ) as $old
      | ( $old
          + {id:$id}
          + (if $root != "" then {infra_root:$root} else {} end)
          + (if $title != "" then {title:$title} else {} end)
        ) as $entry
      | .projects = ( ((.projects // []) | map(select(.id != $id and .id != "__FILL__"))) + [$entry] )
      | (if $mkdef then .default_project = $id else . end)' \
       "$AGENT_DRAFT" > "$_x" && _apply "$AGENT_DRAFT"
fi
# meta НЕ трогаем: в слиянии переносится из живого файла, при первичной — из skeleton.

# ── Карта (infra-config-draft.json) ───────────────────────────────────────────
if [ "$MERGE_INFRA" = "true" ]; then cp "$INFRA_CURRENT" "$INFRA_DRAFT"
else cp "$TPL/infra-config-skeleton.json" "$INFRA_DRAFT"; fi

# servers: обновляем запись по alias, остальные серверы остаются на месте.
if [ -n "${SRV_ALIAS:-}" ]; then
    case "${SRV_ROLE:-production}" in production|staging|test|personal) : ;;
        *) echo "ERROR: SRV_ROLE='${SRV_ROLE:-}' не из enum (production/staging/test/personal)" >&2; exit 1 ;; esac
    jq --arg a "$SRV_ALIAS" --arg s "${SRV_SSH:-}" --arg r "${SRV_ROLE:-production}" --arg d "${SRV_DOMAIN:-}" '
        ( [ (.servers // [])[] | select(.alias == $a) ] | first // {alias:$a} ) as $old
      | ( $old
          + {alias:$a, role:$r}
          + (if $s != "" then {ssh_alias:$s} else {} end)
          + (if $d != "" then {domain:$d} else {} end)
        ) as $entry
      | .servers = ( ((.servers // []) | map(select(.alias != $a and .alias != "__FILL__"))) + [$entry] )' \
       "$INFRA_DRAFT" > "$_x" && _apply "$INFRA_DRAFT"
fi

# monitoring: доливаем поверх существующего объекта, не подменяя его целиком
# (иначе теряется kind=custom — самописное наблюдение объявлялось отсутствующим).
if [ -n "${MON_ENABLED:-}" ]; then
    jq --argjson en "$MON_ENABLED" --argjson stack "${MON_STACK_JSON:-null}" \
       --arg pd "${MON_PANEL_DOMAIN:-}" --arg kind "${MON_KIND:-}" '
        .monitoring = ( (.monitoring // {}) + {enabled:$en}
          + (if $kind != "" then {kind:$kind} else {} end)
          + (if $stack != null then {stack:$stack} else {} end)
          + (if $pd != "" then {panel_domain:$pd} else {} end) )' \
       "$INFRA_DRAFT" > "$_x" && _apply "$INFRA_DRAFT"
fi

# backups. retention — ОБЪЕКТ {daily,weekly,monthly}. Приёмник sftp — блок backups.sftp.
if [ -n "${BACKUPS_ENABLED:-}" ]; then
    # Дефолт retention задаём отдельной строкой: фигурные скобки внутри ${var:-...}
    # ломают разбор параметра (первая } закрывает выражение раньше времени).
    _ret="${BACKUPS_RETENTION_JSON:-}"
    if [ -z "$_ret" ] && [ "${BACKUPS_ENABLED}" = "true" ]; then _ret='{"daily":7,"weekly":4,"monthly":6}'; fi
    [ -z "$_ret" ] && _ret=null
    jq --argjson en "$BACKUPS_ENABLED" --arg dest "${BACKUPS_DESTINATION:-}" --argjson ret "$_ret" '
        .backups = ( (.backups // {}) + {enabled:$en}
          + (if $dest != "" then {destination:$dest} else {} end)
          + (if $ret != null then {retention:$ret} else {} end) )' \
       "$INFRA_DRAFT" > "$_x" && _apply "$INFRA_DRAFT"
    # rclone_remote — для webdav-приёмников.
    [ -n "${BACKUPS_RCLONE_REMOTE:-}" ] && { jq --arg rr "$BACKUPS_RCLONE_REMOTE" \
        '.backups.rclone_remote=$rr' "$INFRA_DRAFT" > "$_x" && _apply "$INFRA_DRAFT"; }
    # sftp-приёмник (свой второй сервер, ADR-0041). host+path обязательны по схеме;
    # user опционален — нужен, только если пользователь не задан ssh-алиасом источника.
    if [ -n "${BACKUPS_SFTP_HOST:-}" ] || [ -n "${BACKUPS_SFTP_PATH:-}" ] || [ -n "${BACKUPS_SFTP_USER:-}" ]; then
        # Значения берём ЧЕРЕЗ ОКРУЖЕНИЕ (env.VAR), а не через --arg. Причина: на Windows
        # в Git Bash jq — программа Windows, и MSYS подменяет её аргументы, похожие на
        # POSIX-путь: `--arg p /data/srv1` молча превращается в
        # `C:/Program Files/Git/data/srv1`, и в конфиг уезжает чужой путь. Значения
        # переменных окружения не подменяются. Поймано тестом 2026-09-24.
        _SFTP_H="${BACKUPS_SFTP_HOST:-}" _SFTP_P="${BACKUPS_SFTP_PATH:-}" _SFTP_U="${BACKUPS_SFTP_USER:-}" \
        jq '
            .backups.sftp = ( (.backups.sftp // {})
              + (if env._SFTP_H != "" then {host: env._SFTP_H} else {} end)
              + (if env._SFTP_P != "" then {path: env._SFTP_P} else {} end)
              + (if env._SFTP_U != "" then {user: env._SFTP_U} else {} end) )' \
           "$INFRA_DRAFT" > "$_x" && _apply "$INFRA_DRAFT"
    fi
fi

# notifications.telegram
if [ -n "${TG_ENABLED:-}" ]; then
    jq --argjson en "$TG_ENABLED" --arg bu "${TG_BOT_USERNAME:-}" --arg ct "${TG_CHAT_TYPE:-}" '
        .notifications.telegram = ( (.notifications.telegram // {}) + {enabled:$en}
          + (if $bu != "" then {bot_username:$bu} else {} end)
          + (if $ct != "" then {chat_type:$ct} else {} end) )' \
       "$INFRA_DRAFT" > "$_x" && _apply "$INFRA_DRAFT"
fi

# vpn: заготовку под VPN-скиллы создаём, ТОЛЬКО если блока ещё нет. Живой блок не трогаем —
# в нём panel_url, server_role и upstream_kind, на которые опираются рефлексы персоны.
if [ "${VPN_ENABLED:-false}" = "true" ]; then
    jq --arg rd "${VPN_REALITY_DEST:-www.cloudflare.com}" '
        if (.vpn | type) == "object" then .
        else .vpn = {
            enabled:false, panel_url:null, panel_web_base_path:null,
            server_proxy_enabled:false, upstream_kind:"none", default_reality_dest:$rd
          } end' "$INFRA_DRAFT" > "$_x" && _apply "$INFRA_DRAFT"
fi

# Страховка ADR-0013: в карте не должно быть агент-полей (если просочились — убрать).
jq 'del(.operator, .language, .secrets, .infrastructure)' "$INFRA_DRAFT" > "$_x" && _apply "$INFRA_DRAFT"

rm -f "$_x"
_mode_a="первичный"; [ "$MERGE_AGENT" = "true" ] && _mode_a="слияние с $AGENT_CURRENT"
_mode_i="первичный"; [ "$MERGE_INFRA" = "true" ] && _mode_i="слияние с $INFRA_CURRENT"
echo "→ собраны draft'ы:"
echo "   мозг:  $AGENT_DRAFT ($_mode_a)"
echo "   карта: $INFRA_DRAFT ($_mode_i)"
