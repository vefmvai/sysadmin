#!/usr/bin/env bash
# migrate-legacy.sh — расщепление старого всё-в-одном sysadmin-config.json (ADR-0013)
# на два draft-файла: agent-config (мозг) + infra-config (карта).
#
# Использование:
#   migrate-legacy.sh <legacy_path> <workdir>
#     <legacy_path> — путь к старому sysadmin-config.json (валидный JSON).
#     <workdir>     — каталог для draft'ов (обычно $WORKDIR из Шага 0 скилла).
#
# На выходе: <workdir>/agent-config-draft.json и <workdir>/infra-config-draft.json.
# Дальше скилл идёт на Шаг 9 (валидация обоих) → Шаг 10 (превью + запись), минуя интервью.
#
# Правило раскладки полей (что куда уезжает):
#   operator.name, operator.timezone        → agent-config.operator
#   language                                 → agent-config.operator.language
#   secrets.*                                → agent-config.secrets
#   meta.* (онбоардинг)                      → agent-config.meta
#   infrastructure.root_path                 → agent-config.projects[0].infra_root
#   monitoring/backups/notifications/servers/vpn/map → infra-config.*
#   backups.retention "Nd-Nw-Nm" (legacy-строка) → объект {daily,weekly,monthly} (новая схема)
#
# Возврат: 0 — оба draft'а собраны; 1 — ошибка (нет аргументов / нет jq / битый legacy).

set -u

LEGACY_PATH="${1:-}"
WORKDIR="${2:-}"

if [ -z "$LEGACY_PATH" ] || [ -z "$WORKDIR" ]; then
    echo "ERROR: usage: migrate-legacy.sh <legacy_path> <workdir>" >&2
    exit 1
fi
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq не найден" >&2; exit 1; }
[ -f "$LEGACY_PATH" ] && jq empty "$LEGACY_PATH" >/dev/null 2>&1 \
    || { echo "ERROR: legacy-конфиг отсутствует или не валидный JSON: $LEGACY_PATH" >&2; exit 1; }
[ -d "$WORKDIR" ] || { echo "ERROR: нет каталога WORKDIR: $WORKDIR" >&2; exit 1; }

# resolve_infra_path (раскрытие tilde / относительного пути от каталога legacy) — из общего helper'а.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
for cand in "$SCRIPT_DIR/../../_lib" "$HOME/sysadmin/.claude/skills/_lib"; do
    [ -f "$cand/find-config.sh" ] && { . "$cand/find-config.sh"; break; }
done

AGENT_DRAFT="$WORKDIR/agent-config-draft.json"
INFRA_DRAFT="$WORKDIR/infra-config-draft.json"

# Раскрываем infra_root: из legacy берём infrastructure.root_path (резолвим от каталога legacy).
RAW_ROOT="$(jq -r '.infrastructure.root_path // empty' "$LEGACY_PATH")"
[ -z "$RAW_ROOT" ] && RAW_ROOT="$(cd "$(dirname "$LEGACY_PATH")" && pwd)"  # сам каталог legacy
if command -v resolve_infra_path >/dev/null 2>&1; then
    INFRA_PATH="$(resolve_infra_path "$RAW_ROOT" "$LEGACY_PATH")" || INFRA_PATH="${RAW_ROOT/#\~/$HOME}"
else
    INFRA_PATH="${RAW_ROOT/#\~/$HOME}"
fi

# id проекта генерируем из alias первого сервера (или "main-server").
PROJ_ID="$(jq -r '(.servers[0].alias // "main-server")
  | ascii_downcase | gsub("[^a-z0-9-]";"-") | gsub("^-+|-+$";"")' "$LEGACY_PATH")"
[ -z "$PROJ_ID" ] && PROJ_ID="main-server"
PROJ_TITLE="$(jq -r '.servers[0].domain // "Основной проект"' "$LEGACY_PATH")"

# agent-config draft: operator + language + secrets + meta + projects[] + default_project.
jq --arg id "$PROJ_ID" --arg title "$PROJ_TITLE" --arg root "$INFRA_PATH" '
  {
    "$schema": "./agent-config.schema.json",
    version: "1.0",
    operator: {
      name: (.operator.name // "Оператор"),
      language: (.language // "ru"),
      timezone: (.operator.timezone // "UTC")
    },
    secrets: (.secrets // {manager:"keychain"}),
    projects: [ { id: $id, title: $title, infra_root: $root } ],
    default_project: $id,
    interaction: {},
    meta: (.meta // {onboarding_completed:false, onboarding_completed_at:null})
  }' "$LEGACY_PATH" > "$AGENT_DRAFT" || { echo "ERROR: не собрался agent-config draft" >&2; exit 1; }

# infra-config draft: всё инфра-центричное, БЕЗ агент-полей и БЕЗ infrastructure.
jq '
  {
    "$schema": "./infra-config.schema.json",
    version: "1.0"
  }
  + (if .map then {map: .map} else {} end)
  + { monitoring: (.monitoring // {enabled:false}) }
  + { backups: (
      # retention в legacy — строка "Nd-Nw-Nm"; новая схема требует объект {daily,weekly,monthly}.
      (.backups // {enabled:false}) as $b
      | if (($b.retention?) | type) == "string" then
          ($b.retention) as $s
          | if ($s | test("^[0-9]+d-[0-9]+w-[0-9]+m$")) then
              ($s | capture("(?<d>[0-9]+)d-(?<w>[0-9]+)w-(?<m>[0-9]+)m")) as $r
              | $b + {retention: {daily:($r.d|tonumber), weekly:($r.w|tonumber), monthly:($r.m|tonumber)}}
            else
              $b + {retention: {daily:7, weekly:4, monthly:6}}
            end
        else $b end
    ) }
  + { notifications: (.notifications // {telegram:{enabled:false}}) }
  + { servers: (.servers // []) }
  + (if .vpn then {vpn: .vpn} else {} end)
' "$LEGACY_PATH" > "$INFRA_DRAFT" || { echo "ERROR: не собрался infra-config draft" >&2; exit 1; }

echo "→ legacy расщеплён:"
echo "   мозг:  $AGENT_DRAFT"
echo "   карта: $INFRA_DRAFT"
echo "   infra_root проекта: $INFRA_PATH (id=$PROJ_ID)"
