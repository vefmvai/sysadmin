#!/usr/bin/env bash
# find-config.sh — единая функция поиска sysadmin-config.json
#
# Используется во всех скиллах, которым нужен конфиг оператора.
# Алгоритм поиска идентичен Cold Start Protocol персоны
# (.claude/agents/references/cold-start.md, Шаг 0).
#
# Единая точка изменения: если правила поиска меняются (добавляется
# $XDG_CONFIG_HOME, переименовываются типичные папки) — правим один файл,
# а не 9+ скиллов и validate-config.sh.
#
# Использование:
#
#   # В SKILL.md внутри bash-блока:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
#   source "$SCRIPT_DIR/../_lib/find-config.sh"
#
#   # либо абсолютным путём (если запускается из скилла, не из script-файла):
#   source "<...>/sysadmin/.claude/skills/_lib/find-config.sh"
#
#   # затем вызвать:
#   find_sysadmin_config strict     # exit 1 если не найден или невалидный JSON
#   find_sysadmin_config optional   # WARN + defaults если не найден
#   find_sysadmin_config silent     # тихо, $CONFIG="" если не найден
#
#   # после успешного вызова доступны переменные:
#   #   $CONFIG                — путь к найденному файлу (или "" в silent)
#   #   $SYSADMIN_CONFIG_FOUND — "true"/"false"
#
# Дополнительные геттеры (читают уже найденный $CONFIG, не делают повторного поиска):
#
#   require_config_field "vpn.panel_url" "Установи /setup-vpn-panel"
#       # exit 1 если поле пустое — с понятным сообщением
#
#   get_config_field "language" "ru"
#       # echo значения поля или дефолта
#
# Все сообщения об ошибках выводятся в stderr (>&2), exit codes:
#   0 — конфиг найден (или silent-режим без конфига)
#   1 — конфиг не найден в strict-режиме / не валидный JSON / поле пусто в require_*

# Защита от двойного source
[ -n "${_SYSADMIN_FIND_CONFIG_LOADED:-}" ] && return 0
_SYSADMIN_FIND_CONFIG_LOADED=1

# Определить SYSADMIN_ROOT (корень sysadmin/ репо) — нужно, например, для доступа
# к sysadmin-config.schema.json и другим артефактам мозга агента.
# Алгоритм: bridge-файл ~/.claude/agents/sysadmin.md содержит абсолютный путь
# к актуальному sysadmin/ в строке формата "**`/path/to/sysadmin/`**".
# Если bridge нет — пробуем типичные локации и cwd-эвристики.
locate_sysadmin_root() {
    SYSADMIN_ROOT=""

    # 1. Через bridge-файл (надёжный источник истины)
    local bridge="$HOME/.claude/agents/sysadmin.md"
    if [ -f "$bridge" ]; then
        # Ищем абсолютный путь к sysadmin/ в обратных кавычках. Кросс-платформенно:
        #   - Unix/MINGW:   `/home/.../sysadmin`  или  `/c/Users/.../sysadmin`
        #   - Windows-native: `C:\Users\...\sysadmin`  или  `C:/Users/.../sysadmin`
        # Поэтому НЕ требуем ведущий '/'. Берём всё между обратными кавычками, что
        # заканчивается на sysadmin (с возможным завершающим слешем любого типа).
        local from_bridge
        from_bridge=$(grep -oE '`[^`]+sysadmin[/\\]?`' "$bridge" 2>/dev/null \
            | head -1 \
            | sed 's|^`||; s|`$||; s|[/\\]$||')
        # Windows-native путь (C:\...) внутри Git Bash нужно привести к /c/... —
        # bash не умеет с C:\ напрямую. cygpath есть в Git Bash; если нет — оставляем.
        if [ -n "$from_bridge" ] && command -v cygpath >/dev/null 2>&1; then
            case "$from_bridge" in
                [A-Za-z]:*) from_bridge="$(cygpath -u "$from_bridge" 2>/dev/null || echo "$from_bridge")" ;;
            esac
        fi
        if [ -n "$from_bridge" ] && [ -d "$from_bridge" ]; then
            SYSADMIN_ROOT="$from_bridge"
            return 0
        fi
    fi

    # 2. Типичные локации
    local candidate
    for candidate in \
        "./sysadmin" \
        "../sysadmin" \
        "$HOME/sysadmin" \
        "$HOME/work/sysadmin" \
        "$HOME/projects/sysadmin"; do
        if [ -f "$candidate/.claude/agents/sysadmin.md" ]; then
            SYSADMIN_ROOT="$(cd "$candidate" && pwd)"
            return 0
        fi
    done

    # 3. Эвристика — может, мы внутри самого sysadmin/?
    if [ -f "./.claude/agents/sysadmin.md" ]; then
        SYSADMIN_ROOT="$(pwd)"
        return 0
    fi

    return 1
}

# Кандидаты поиска. Порядок важен: более специфичное место — выше.
_sysadmin_config_candidates() {
    # Используется через cat <<EOF чтобы поддержать раскрытие $INFRA_DIR/$HOME
    cat <<EOF
${INFRA_DIR:-/dev/null}/sysadmin-config.json
./sysadmin-config.json
../infra/sysadmin-config.json
$HOME/infra/sysadmin-config.json
$HOME/work/infra/sysadmin-config.json
$HOME/projects/infra/sysadmin-config.json
EOF
}

# Универсальное сообщение «не нашёл»
_sysadmin_not_found_message() {
    cat <<'EOF' >&2
sysadmin-config.json не найден ни в одном из стандартных мест:
  ./, ../infra/, ~/infra/, ~/work/infra/, ~/projects/infra/
  + переменная окружения $INFRA_DIR (если задана).

Запусти /sysadmin-init для первичной настройки агента — это 3-5 минут вопросов,
после которых скиллы будут знать всё необходимое.
EOF
}

# Главная функция поиска
# Аргумент 1: mode = strict | optional | silent (default: optional)
find_sysadmin_config() {
    local mode="${1:-optional}"
    case "$mode" in
        strict|optional|silent) ;;
        *)
            echo "ERROR: find_sysadmin_config: неизвестный режим '$mode' (ожидался strict|optional|silent)" >&2
            exit 2
            ;;
    esac
    CONFIG=""
    SYSADMIN_CONFIG_FOUND="false"

    local candidate
    while IFS= read -r candidate; do
        if [ -f "$candidate" ]; then
            CONFIG="$candidate"
            SYSADMIN_CONFIG_FOUND="true"
            break
        fi
    done < <(_sysadmin_config_candidates)

    # Если нашёл — валидируем JSON
    if [ "$SYSADMIN_CONFIG_FOUND" = "true" ]; then
        if ! jq empty "$CONFIG" >/dev/null 2>&1; then
            echo "ERROR: $CONFIG найден, но содержит невалидный JSON." >&2
            echo "       Проверь /sysadmin-init или исправь файл вручную." >&2
            [ "$mode" = "strict" ] && exit 1
            # optional/silent — обнуляем как будто не нашли
            CONFIG=""
            SYSADMIN_CONFIG_FOUND="false"
            return 1
        fi
        return 0
    fi

    # Не нашёл — поведение зависит от режима (валидация $mode была в начале функции)
    case "$mode" in
        strict)
            _sysadmin_not_found_message
            exit 1
            ;;
        optional)
            echo "WARN: sysadmin-config.json не найден. Использую defaults." >&2
            echo "      Для точности — запусти /sysadmin-init." >&2
            return 1
            ;;
        silent)
            return 1
            ;;
    esac
}

# Геттер поля с дефолтом (не падает если поля нет)
# Использование: get_config_field "language" "ru"
get_config_field() {
    local field="$1"
    local default="${2:-}"
    if [ -z "$CONFIG" ] || [ ! -f "$CONFIG" ]; then
        echo "$default"
        return 0
    fi
    local value
    value=$(jq -r ".$field // empty" "$CONFIG" 2>/dev/null)
    if [ -z "$value" ] || [ "$value" = "null" ]; then
        echo "$default"
    else
        echo "$value"
    fi
}

# Требование поля. exit 1 с понятным сообщением если пусто.
# Использование: require_config_field "vpn.panel_url" "Сначала запусти /setup-vpn-panel"
require_config_field() {
    local field="$1"
    local fix_hint="${2:-Проверь $CONFIG или запусти /sysadmin-init --reconfigure.}"
    if [ -z "$CONFIG" ]; then
        echo "ERROR: require_config_field вызван до find_sysadmin_config (CONFIG пуст)." >&2
        exit 1
    fi
    local value
    value=$(jq -r ".$field // empty" "$CONFIG" 2>/dev/null)
    if [ -z "$value" ] || [ "$value" = "null" ]; then
        echo "ERROR: В $CONFIG нет поля '$field' (или оно пустое)." >&2
        echo "       $fix_hint" >&2
        exit 1
    fi
    # Не echo'им значение — пусть caller сам прочитает get_config_field
    return 0
}
