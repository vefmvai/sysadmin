#!/usr/bin/env bash
# validate-config.sh — валидация sysadmin-config.json по JSON Schema.
#
# Конфиг живёт в infra/ оператора, схема — в sysadmin/ (публичный репо).
#
# Использование:
#   validate-config.sh                              # ищет конфиг в стандартных местах
#   validate-config.sh /tmp/sysadmin-config-draft.json   # явный путь к draft-конфигу
#
# Возврат:
#   0 — конфиг валиден.
#   1 — конфиг не валиден (или файл не найден).
#   2 — нет утилит для валидации (jq не установлен).
#
# Способы валидации:
#   1) check-jsonschema (предпочтительный) — если установлен через `pipx install check-jsonschema`.
#   2) jq-fallback — минимальная проверка обязательных полей и enum'ов.

set -u

# Поиск конфига (если не передан аргументом — тот же алгоритм что в Cold Start персоны)
if [ "$#" -ge 1 ]; then
    CONFIG="$1"
else
    CONFIG=""
    for candidate in \
        "${INFRA_DIR:-/dev/null}/sysadmin-config.json" \
        "./sysadmin-config.json" \
        "../infra/sysadmin-config.json" \
        "$HOME/infra/sysadmin-config.json" \
        "$HOME/work/infra/sysadmin-config.json" \
        "$HOME/projects/infra/sysadmin-config.json"; do
        [ -f "$candidate" ] && { CONFIG="$candidate"; break; }
    done
    [ -z "$CONFIG" ] && { echo "ERROR: sysadmin-config.json не найден ни в одном стандартном месте"; exit 1; }
fi

# Схема живёт в sysadmin/ — относительно самого скрипта (он в .claude/skills/sysadmin-init/scripts/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSADMIN_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
SCHEMA="$SYSADMIN_ROOT/sysadmin-config.schema.json"

[ -f "$CONFIG" ] || { echo "ERROR: $CONFIG не существует"; exit 1; }
[ -f "$SCHEMA" ] || { echo "ERROR: схема $SCHEMA не найдена (ожидалась в корне репо sysadmin/)"; exit 1; }

# --- Способ 1: check-jsonschema (предпочтительный) ---
if command -v check-jsonschema >/dev/null 2>&1; then
    check-jsonschema --schemafile "$SCHEMA" "$CONFIG"
    exit $?
fi

# --- Способ 2: jq-fallback (минимальная проверка) ---
echo "WARN: check-jsonschema не установлен, использую jq-fallback (минимальная проверка)."
echo "      Для полной валидации: pipx install check-jsonschema"

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq не установлен. brew install jq (macOS) или apt-get install jq (Linux)."
    exit 2
fi

# 1. Обязательные поля верхнего уровня
REQUIRED_FIELDS=(version language operator secrets monitoring backups notifications servers)
for field in "${REQUIRED_FIELDS[@]}"; do
    if ! jq -e --arg f "$field" 'has($f)' "$CONFIG" >/dev/null 2>&1; then
        echo "FAIL: отсутствует обязательное поле .$field"
        exit 1
    fi
done

# 2. version === "1.0"
VERSION=$(jq -r '.version' "$CONFIG")
if [ "$VERSION" != "1.0" ]; then
    echo "FAIL: version = $VERSION, ожидалось \"1.0\""
    exit 1
fi

# 3. language ∈ {ru, en}
LANG=$(jq -r '.language' "$CONFIG")
case "$LANG" in
    ru|en) ;;
    *) echo "FAIL: language = $LANG, ожидалось ru или en"; exit 1 ;;
esac

# 4. secrets.manager ∈ {keychain, bitwarden, 1password, pass}
MANAGER=$(jq -r '.secrets.manager' "$CONFIG")
case "$MANAGER" in
    keychain|bitwarden|1password|pass) ;;
    *) echo "FAIL: secrets.manager = $MANAGER, ожидалось keychain|bitwarden|1password|pass"; exit 1 ;;
esac

# 5. operator.name и operator.timezone — непустые строки
OP_NAME=$(jq -r '.operator.name // ""' "$CONFIG")
[ -z "$OP_NAME" ] && { echo "FAIL: operator.name пуст"; exit 1; }
OP_TZ=$(jq -r '.operator.timezone // ""' "$CONFIG")
[ -z "$OP_TZ" ] && { echo "FAIL: operator.timezone пуст"; exit 1; }

# 6. monitoring.enabled / backups.enabled / notifications.telegram.enabled — boolean
for path in '.monitoring.enabled' '.backups.enabled' '.notifications.telegram.enabled'; do
    TYPE=$(jq -r "$path | type" "$CONFIG" 2>/dev/null)
    if [ "$TYPE" != "boolean" ]; then
        echo "FAIL: $path должен быть boolean, найден $TYPE"
        exit 1
    fi
done

# 7. servers — непустой массив
SERVERS_LEN=$(jq -r '.servers | length' "$CONFIG")
if [ "$SERVERS_LEN" -lt 1 ]; then
    echo "FAIL: servers — пустой массив, должен содержать ≥ 1 сервер"
    exit 1
fi

# 8. Каждый сервер имеет alias, ssh_alias, role
for i in $(seq 0 $((SERVERS_LEN - 1))); do
    for field in alias ssh_alias role; do
        VAL=$(jq -r ".servers[$i].$field // \"\"" "$CONFIG")
        if [ -z "$VAL" ]; then
            echo "FAIL: .servers[$i].$field пуст или отсутствует"
            exit 1
        fi
    done
done

echo "PASS: jq-fallback подтвердил минимальные требования. Для полной валидации установи check-jsonschema."
exit 0