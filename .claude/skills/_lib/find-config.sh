#!/usr/bin/env bash
# find-config.sh — единая функция поиска конфига агента (agent-config.json мозг +
#                   infra-config.json карта; legacy sysadmin-config.json — fallback)
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

# ──────────────────────────────────────────────────────────────────────────
# require_jq — жёсткая проверка наличия jq (P10). Этот файл и большинство скиллов
# гоняют jq для чтения конфигов/JSON; без него вместо КРИПТОВОГО «jq: command not
# found» на середине — понятный STOP с инструкцией. jq — обязательная зависимость.
# (Полный гейт с авто-доустановкой — _lib/ensure-local-env.sh, его зовёт /sysadmin-init.)
# Скиллы, использующие jq БЕЗ поиска конфига, могут позвать require_jq напрямую:
#   source "<...>/_lib/find-config.sh"; require_jq || exit 1
require_jq() {
    command -v jq >/dev/null 2>&1 && return 0
    echo "ОШИБКА: jq не установлен — без него агент не читает конфиги и JSON." >&2
    echo "        Поставь: macOS — 'brew install jq'; Debian/Ubuntu — 'sudo apt install jq';" >&2
    echo "        Windows — 'winget install jqlang.jq' (перезапусти сессию). Затем повтори." >&2
    echo "        Полная настройка окружения с авто-доустановкой — запусти /sysadmin-init." >&2
    return 1
}

# ──────────────────────────────────────────────────────────────────────────
# resolve_infra_path — ЕДИНЫЙ резолвер пути к папке инфры из root_path.
#
# Канон (ADR-0008, fix v1.4.2): относительный root_path резолвится ОТНОСИТЕЛЬНО
# КАТАЛОГА КОНФИГА, а не от cwd процесса. Причина: /sysadmin-init кладёт сам
# конфиг ВНУТРЬ папки инфры (CONFIG_PATH="$INFRA/sysadmin-config.json"), поэтому
# «../infra от конфига» однозначно и не зависит от того, из какой папки запущен
# агент/скилл/самопроверка. Раньше три места резолвили по-разному (cwd процесса,
# cwd скилла, только tilde) → ложный провал self-test на относительном пути.
#
# Правила:
#   • tilde (~) в начале → $HOME (через bash-замену, без eval — безопасно).
#   • абсолютный путь → как есть.
#   • относительный путь → от каталога $2 (каталог конфига).
#
# Использование:
#   resolve_infra_path "$RAW_ROOT_PATH" "$CONFIG_PATH"
#   # печатает абсолютный путь в stdout; rc=0 если папка существует, 1 если нет.
#   # ВАЖНО: rc=1 не значит ошибка — папки инфры может ещё не быть (First-Run).
resolve_infra_path() {
    local raw="$1"
    local config_path="$2"
    [ -z "$raw" ] && return 1

    # 1. tilde → $HOME (только ведущий ~, как в Cold Start)
    local expanded="${raw/#\~/$HOME}"

    # 2. абсолютный путь — отдаём как есть (Unix / и Windows-native C:\ или C:/)
    case "$expanded" in
        /*|[A-Za-z]:[\\/]*)
            printf '%s\n' "$expanded"
            [ -d "$expanded" ] && return 0 || return 1
            ;;
    esac

    # 3. относительный путь — резолвим от КАТАЛОГА КОНФИГА
    local base resolved
    if [ -n "$config_path" ]; then
        base="$(cd "$(dirname "$config_path")" 2>/dev/null && pwd)"
    fi
    # Если каталог конфига недоступен — честный fallback на cwd (лучше, чем молча соврать).
    [ -z "$base" ] && base="$(pwd)"

    # cd в существующую папку даёт нормализованный абсолютный путь (схлопывает ../).
    # Если папки ещё нет (First-Run) — собираем путь текстом, чтобы вызывающий
    # мог показать осмысленное сообщение и/или mkdir -p.
    resolved="$(cd "$base" 2>/dev/null && cd "$expanded" 2>/dev/null && pwd)"
    if [ -n "$resolved" ]; then
        printf '%s\n' "$resolved"
        return 0
    fi
    printf '%s\n' "$base/$expanded"
    return 1
}

# Определить SYSADMIN_ROOT (корень sysadmin/ репо) — нужно, например, для доступа
# к agent-config.schema.json и другим артефактам мозга агента.
# Алгоритм: bridge-файл ~/.claude/agents/sysadmin.md содержит абсолютный путь
# к актуальному sysadmin/ в строке формата "**`/path/to/sysadmin/`**".
# Если bridge нет — пробуем типичные локации и cwd-эвристики.
#
# Маркер корня (задача 0.5 рефакторинга, мина P12): версионируемый файл
# `.sysadmin-root` — устойчивый признак, НЕ зависящий от файла персоны. В 2.0
# (ADR-0015) ядро персоны переехало в CLAUDE.md, а .claude/agents/sysadmin.md стал
# тонкой заглушкой — поэтому основной маркер именно `.sysadmin-root`. Запасные
# признаки (CLAUDE.md, заглушка persona) оставлены для частично обновлённых установок.
_is_sysadmin_root() {
    [ -f "$1/.sysadmin-root" ] && return 0
    [ -f "$1/CLAUDE.md" ] && [ -d "$1/.claude/skills" ] && return 0   # 2.0: ядро в CLAUDE.md
    [ -f "$1/.claude/agents/sysadmin.md" ] && return 0   # legacy-признак (до 2.0)
    return 1
}

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
        if _is_sysadmin_root "$candidate"; then
            SYSADMIN_ROOT="$(cd "$candidate" && pwd)"
            return 0
        fi
    done

    # 3. Эвристика — может, мы внутри самого sysadmin/?
    if _is_sysadmin_root "."; then
        SYSADMIN_ROOT="$(pwd)"
        return 0
    fi

    return 1
}

# Кандидаты поиска (FALLBACK-перебор). Порядок важен: более специфичное место — выше.
#
# ВАЖНО (ADR-0013): этот перебор — РЕЗЕРВНЫЙ путь. Основной путь теперь —
# find_brain_config() читает sysadmin/agent-config.json напрямую и берёт infra-config.json
# из реестра projects[]. Перебор срабатывает ТОЛЬКО когда мозга нет (новый пользователь,
# первый запуск, или старая установка до миграции).
#
# Для каждого места проверяем ОБА имени: новое infra-config.json (после ADR-0013) и
# старое sysadmin-config.json (до миграции, переходная совместимость).
_sysadmin_config_candidates() {
    # Используется через cat <<EOF чтобы поддержать раскрытие $INFRA_DIR/$HOME
    cat <<EOF
${INFRA_DIR:-/dev/null}/infra-config.json
${INFRA_DIR:-/dev/null}/sysadmin-config.json
./infra-config.json
./sysadmin-config.json
../infra/infra-config.json
../infra/sysadmin-config.json
$HOME/infra/infra-config.json
$HOME/infra/sysadmin-config.json
$HOME/work/infra/infra-config.json
$HOME/work/infra/sysadmin-config.json
$HOME/projects/infra/infra-config.json
$HOME/projects/infra/sysadmin-config.json
EOF
}

# Универсальное сообщение «не нашёл»
_sysadmin_not_found_message() {
    cat <<'EOF' >&2
Конфиг инфры (infra-config.json; legacy sysadmin-config.json) не найден ни в одном из стандартных мест:
  ./, ../infra/, ~/infra/, ~/work/infra/, ~/projects/infra/
  + переменная окружения $INFRA_DIR (если задана).

Запусти /sysadmin-init для первичной настройки агента — это 3-5 минут вопросов,
после которых скиллы будут знать всё необходимое.
EOF
}

# ──────────────────────────────────────────────────────────────────────────
# find_brain_config — ОСНОВНОЙ путь поиска конфига мозга (ADR-0013).
#
# Находит sysadmin/agent-config.json — «дом агента». В отличие от перебора, это
# ОДНО известное место: корень публичного репо sysadmin/ (через locate_sysadmin_root).
# Никакого перебора по диску — поэтому быстро и без «ритуала поиска» на каждом старте.
#
# После успешного вызова доступны:
#   $BRAIN_CONFIG        — путь к agent-config.json (или "" если не найден)
#   $BRAIN_CONFIG_FOUND  — "true"/"false"
#
# rc=0 если найден и валиден; rc=1 если не найден или невалидный JSON.
# Сообщения — в stderr. Не делает exit (решение о фатальности — за caller'ом).
find_brain_config() {
    BRAIN_CONFIG=""
    BRAIN_CONFIG_FOUND="false"

    require_jq || exit 1           # P10: без jq дальше ничего не прочитать — STOP с инструкцией

    locate_sysadmin_root || true   # заполняет $SYSADMIN_ROOT (может быть пустым)

    local candidate=""
    if [ -n "${SYSADMIN_ROOT:-}" ] && [ -f "$SYSADMIN_ROOT/agent-config.json" ]; then
        candidate="$SYSADMIN_ROOT/agent-config.json"
    elif [ -f "./agent-config.json" ]; then
        # запасной случай: запущены прямо из sysadmin/, bridge недоступен
        candidate="./agent-config.json"
    fi

    if [ -z "$candidate" ]; then
        return 1
    fi

    if ! jq empty "$candidate" >/dev/null 2>&1; then
        echo "ERROR: $candidate найден, но содержит невалидный JSON." >&2
        echo "       Проверь /sysadmin-init или исправь файл вручную." >&2
        return 1
    fi

    BRAIN_CONFIG="$candidate"
    BRAIN_CONFIG_FOUND="true"
    return 0
}

# ──────────────────────────────────────────────────────────────────────────
# resolve_active_project — из мозга достать активный проект и путь к его infra-config.json.
#
# Аргумент 1 (опц.): id проекта. Если пусто — берётся default_project из мозга.
# Требует, чтобы find_brain_config уже отработал ($BRAIN_CONFIG заполнен).
#
# После успешного вызова доступны:
#   $ACTIVE_PROJECT_ID    — id выбранного проекта
#   $ACTIVE_INFRA_ROOT    — абсолютный путь к папке инфры проекта (tilde раскрыт)
#   $ACTIVE_INFRA_CONFIG  — путь к infra-config.json проекта
#
# rc=0 если проект найден и infra-config.json существует; rc=1 иначе (с сообщением).
resolve_active_project() {
    local want_id="${1:-}"
    ACTIVE_PROJECT_ID=""
    ACTIVE_INFRA_ROOT=""
    ACTIVE_INFRA_CONFIG=""

    if [ -z "${BRAIN_CONFIG:-}" ] || [ ! -f "${BRAIN_CONFIG:-}" ]; then
        echo "ERROR: resolve_active_project вызван до find_brain_config (BRAIN_CONFIG пуст)." >&2
        return 1
    fi

    # id проекта: аргумент → default_project
    if [ -z "$want_id" ]; then
        want_id="$(jq -r '.default_project // empty' "$BRAIN_CONFIG" 2>/dev/null)"
    fi
    if [ -z "$want_id" ]; then
        echo "ERROR: в $BRAIN_CONFIG нет default_project и id не передан." >&2
        return 1
    fi

    # достаём запись проекта по id
    local proj
    proj="$(jq -c --arg id "$want_id" '.projects[]? | select(.id == $id)' "$BRAIN_CONFIG" 2>/dev/null)"
    if [ -z "$proj" ]; then
        echo "ERROR: проект '$want_id' не найден в projects[] ($BRAIN_CONFIG)." >&2
        return 1
    fi

    local raw_root raw_config
    raw_root="$(printf '%s' "$proj" | jq -r '.infra_root // empty')"
    raw_config="$(printf '%s' "$proj" | jq -r '.config // empty')"

    if [ -z "$raw_root" ]; then
        echo "ERROR: у проекта '$want_id' пустой infra_root ($BRAIN_CONFIG)." >&2
        return 1
    fi

    # Резолв — через общий канон ADR-0008: tilde → $HOME, абсолютный как есть,
    # относительный — от КАТАЛОГА КОНФИГА (здесь — каталога мозга), а НЕ от cwd.
    # Раньше здесь стоял свой `cd "$root" && pwd`, считавший относительный путь от
    # рабочего каталога процесса, — и `agent-config.json` с `../infra` резолвился
    # по-разному в разных местах: host-digest.sh и self-test-setup.sh давно шли
    # каноном, Cold Start — нет (расхождение найдено проверкой 04.08.2026).
    # rc игнорируем намеренно: при отсутствующей папке (First-Run) функция всё равно
    # печатает лучший вариант пути, и вызывающий сам покажет осмысленное сообщение.
    local root
    root="$(resolve_infra_path "$raw_root" "$BRAIN_CONFIG")"
    [ -z "$root" ] && root="${raw_root/#\~/$HOME}"
    ACTIVE_INFRA_ROOT="$root"
    ACTIVE_PROJECT_ID="$want_id"

    # путь к infra-config.json: явный .config → иначе <infra_root>/infra-config.json
    local cfg
    if [ -n "$raw_config" ]; then
        cfg="${raw_config/#\~/$HOME}"
        case "$cfg" in
            /*|[A-Za-z]:[\\/]*) : ;;            # абсолютный — как есть
            *) cfg="$root/$cfg" ;;              # относительный — от infra_root
        esac
    else
        cfg="$root/infra-config.json"
    fi
    ACTIVE_INFRA_CONFIG="$cfg"

    if [ ! -f "$cfg" ]; then
        echo "ERROR: infra-config.json проекта '$want_id' не найден: $cfg" >&2
        return 1
    fi
    if ! jq empty "$cfg" >/dev/null 2>&1; then
        echo "ERROR: $cfg найден, но содержит невалидный JSON." >&2
        return 1
    fi
    return 0
}

# Главная функция поиска ИНФРА-конфига.
# Аргумент 1: mode = strict | optional | silent (default: optional)
#
# Порядок (ADR-0013):
#   1. ОСНОВНОЙ путь — мозг: find_brain_config → resolve_active_project →
#      $CONFIG = infra-config.json активного проекта. Без перебора. Активный проект:
#      $SYSADMIN_PROJECT (явное переключение в сессии) → иначе default_project.
#      Мозг есть, но проект не разрешился → ПОВРЕЖДЁННАЯ КАРТА → STOP (НЕ тихий fallback:
#      перебор увёл бы на чужую инфраструктуру, P15).
#   2. FALLBACK — старый перебор по типичным путям (_sysadmin_config_candidates),
#      ТОЛЬКО когда мозга нет вовсе (новый пользователь / старая установка до миграции).
#
# Совместимость: имя функции и переменные ($CONFIG, $SYSADMIN_CONFIG_FOUND) сохранены —
# 12 скиллов-потребителей не требуют правок. find_infra_config — псевдоним (см. ниже).
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

    # 1) ОСНОВНОЙ путь: мозг → активный проект → его infra-config.json.
    #    Какой проект активен: $SYSADMIN_PROJECT (явное переключение в сессии, P14) →
    #    иначе default_project из мозга. Так оператор работает с НЕ-дефолтным проектом,
    #    не трогая конфиг: `export SYSADMIN_PROJECT=<id>` перед запуском скилла.
    if find_brain_config; then
        if resolve_active_project "${SYSADMIN_PROJECT:-}"; then
            CONFIG="$ACTIVE_INFRA_CONFIG"
            SYSADMIN_CONFIG_FOUND="true"
            return 0
        fi
        # Мозг есть и АВТОРИТЕТЕН: он явно указывает, где карта проекта. Если она не
        # разрешилась (нет проекта с таким id / битый infra_root / нет/невалиден
        # infra-config.json) — это ПОВРЕЖДЁННАЯ КАРТА, а не повод искать в другом месте.
        # НЕ делаем тихий fallback-перебор (P15): он мог бы подцепить ЧУЖОЙ infra-config
        # из типичного пути и увести агента на НЕ ТУ инфраструктуру. Обнуляем и STOP.
        ACTIVE_INFRA_ROOT=""; ACTIVE_INFRA_CONFIG=""; CONFIG=""; SYSADMIN_CONFIG_FOUND="false"
        echo "ERROR: мозг (agent-config.json) есть, но карта проекта не разрешилась (причина выше)." >&2
        echo "       НЕ угадываю другой конфиг по типичным путям — это увело бы на чужую инфраструктуру." >&2
        echo "       Почини projects[]/infra_root в мозге или infra-config.json проекта." >&2
        [ -n "${SYSADMIN_PROJECT:-}" ] && echo "       (SYSADMIN_PROJECT='${SYSADMIN_PROJECT}' — проверь, что такой id есть в projects[].)" >&2
        case "$mode" in
            strict) exit 1 ;;
            optional|silent) return 1 ;;
        esac
    fi

    # 2) FALLBACK: старый перебор по типичным путям
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
            echo "WARN: конфиг инфры (infra-config.json / agent-config.json) не найден. Использую defaults." >&2
            echo "      Для точности — запусти /sysadmin-init." >&2
            return 1
            ;;
        silent)
            return 1
            ;;
    esac
}

# Псевдоним с корректным именем (ADR-0013): новые скиллы используют find_infra_config,
# старые продолжают звать find_sysadmin_config — это одна и та же функция.
find_infra_config() { find_sysadmin_config "$@"; }

# ──────────────────────────────────────────────────────────────────────────
# get_agent_field — геттер АГЕНТ-поля (ADR-0013) с legacy-fallback.
#
# Агент-поля (operator.language, operator.name, operator.timezone, secrets.manager,
# secrets.manager_name, secrets.cli_available) после расщепления живут в МОЗГЕ
# (agent-config.json / $BRAIN_CONFIG), а не в infra-config ($CONFIG). Но в legacy-конфиге
# (всё-в-одном sysadmin-config.json) они ещё лежат вместе с инфра-полями в $CONFIG —
# и иногда по ДРУГОМУ jq-пути (язык: мозг .operator.language, legacy top-level .language).
#
# Поэтому геттер принимает ДВА пути: для мозга и для legacy.
#
# Использование:
#   get_agent_field ".operator.language" ".language" "ru"      # язык (путь переехал)
#   get_agent_field ".secrets.manager"   ".secrets.manager" "" # менеджер (путь не менялся)
#
# Лениво вызывает find_brain_config, если $BRAIN_CONFIG ещё не выставлен.
get_agent_field() {
    local brain_path="$1"
    local legacy_path="${2:-$1}"
    local default="${3:-}"

    # лениво находим мозг, если ещё не искали
    if [ -z "${BRAIN_CONFIG:-}" ] && [ "${BRAIN_CONFIG_FOUND:-}" != "false-tried" ]; then
        find_brain_config || true
        [ -z "${BRAIN_CONFIG:-}" ] && BRAIN_CONFIG_FOUND="false-tried"
    fi

    local v=""
    if [ -n "${BRAIN_CONFIG:-}" ] && [ -f "${BRAIN_CONFIG:-}" ]; then
        v=$(jq -r "$brain_path // empty" "$BRAIN_CONFIG" 2>/dev/null)
    fi
    if [ -z "$v" ] && [ -n "${CONFIG:-}" ] && [ -f "${CONFIG:-}" ]; then
        v=$(jq -r "$legacy_path // empty" "$CONFIG" 2>/dev/null)
    fi
    if [ -z "$v" ] || [ "$v" = "null" ]; then
        echo "$default"
    else
        echo "$v"
    fi
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
