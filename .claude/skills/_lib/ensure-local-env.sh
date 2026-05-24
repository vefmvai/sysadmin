#!/usr/bin/env bash
# ensure-local-env.sh — адаптивный гейт локального окружения (bash+jq) для машины оператора.
#
# Подключён в `/sysadmin-init` (Шаг 0.0) — критический вход, где окружение проверяется
# и при необходимости доустанавливается. Другие локальные скиллы полагаются на то, что
# jq уже есть, + на поведенческую защиту C.9 персоны (не смог → STOP, не суррогат).
#
# ФИЛОСОФИЯ (см. feedback Василия 2026-05-24): «спрашивай систему, не предполагай;
# не смог — скажи прямо». Поэтому:
#   - ДЕТЕКТ окружения — динамический (пробег по PATH), а не хардкод «ОС → менеджер».
#   - УСТАНОВКА — whitelist проверенных команд (LLM НЕ угадывает команды записи в систему),
#     но с УНИВЕРСАЛЬНЫМ fallback: скачать self-contained бинарник jq напрямую с
#     официального GitHub (github.com/jqlang/jq) под ОС+архитектуру — работает на любой
#     версии любой ОС без всякого пакетного менеджера.
#   - ВЕРИФИКАЦИЯ — после установки реально вызываем `jq --version`, не верим на слово.
#   - НЕ СМОГ — возвращаем 1; вызывающий скилл обязан выдать честный вердикт оператору
#     (а не притворяться, что готово).
#
# Граница автономии: ставим САМ, без отдельного вопроса, но ГРОМКО проговариваем
# каждое действие в stderr (оператор видит, что именно ставится и откуда).
#
# Использование:
#   source "<...>/_lib/ensure-local-env.sh"
#   ensure_local_env          # детект → автоустановка jq при отсутствии → верификация
#   ensure_local_env check    # только проверка, ничего не ставит
#
# Возврат: 0 — bash+jq доступны; 1 — непригодно (инструкция уже выведена в stderr).
#
# Переменные после вызова:
#   $LOCAL_ENV_OS    — Darwin | Linux | MINGW | unknown
#   $LOCAL_ENV_ARCH  — x86_64 | arm64 | i386 | unknown
#   $LOCAL_ENV_PM    — найденный пакетный менеджер или "none"
#   $LOCAL_ENV_JQ    — путь к рабочему jq (если ставили скачиванием — локальный путь)

# Защита от двойного source
[ -n "${_SYSADMIN_ENSURE_ENV_LOADED:-}" ] && return 0
_SYSADMIN_ENSURE_ENV_LOADED=1

# Куда складываем скачанные вручную бинарники (когда нет пакетного менеджера)
_SYSADMIN_BIN_DIR="${SYSADMIN_BIN_DIR:-$HOME/.sysadmin/bin}"

# Авто-добор скачанного бинарника в PATH ПРИ КАЖДОМ source этого файла.
# Зачем: Claude Code исполняет bash-блоки скилла часто в РАЗНЫХ процессах, и export PATH
# из одного блока теряется в следующем. Но файл ~/.sysadmin/bin/jq лежит на диске постоянно.
# Раз этот helper source'ится в начале каждого важного блока (через find-config.sh или
# напрямую) — он каждый раз заново добавляет папку в PATH. Так «агент сам находит» скачанный
# jq и после смены процесса, и после перезапуска сессии. Идемпотентно (проверяем дубль).
if [ -d "$_SYSADMIN_BIN_DIR" ]; then
    case ":$PATH:" in
        *":$_SYSADMIN_BIN_DIR:"*) : ;;                       # уже в PATH — ничего
        *) PATH="$_SYSADMIN_BIN_DIR:$PATH"; export PATH ;;
    esac
fi

# --- Детект ОС (динамический, не падает если uname нет) ---
_detect_local_os() {
    case "${OSTYPE:-}" in
        darwin*) echo "Darwin"; return ;;
        linux-gnu*|linux*) echo "Linux"; return ;;
        msys*|cygwin*) echo "MINGW"; return ;;
    esac
    if command -v uname >/dev/null 2>&1; then
        case "$(uname -s 2>/dev/null)" in
            Darwin) echo "Darwin"; return ;;
            Linux) echo "Linux"; return ;;
            MINGW*|MSYS*|CYGWIN*) echo "MINGW"; return ;;
        esac
    fi
    echo "unknown"
}

# --- Детект архитектуры (для прямого скачивания бинарника) ---
_detect_arch() {
    local m=""
    command -v uname >/dev/null 2>&1 && m="$(uname -m 2>/dev/null)"
    case "$m" in
        x86_64|amd64)        echo "x86_64" ;;
        arm64|aarch64)       echo "arm64" ;;
        i386|i686)           echo "i386" ;;
        *)                   echo "${m:-unknown}" ;;
    esac
}

# --- Динамический детект пакетного менеджера: пробег по PATH, НЕ привязка к ОС ---
# Спрашиваем систему «что у тебя реально есть», а не «какая ты ОС → значит у тебя X».
# Порядок — от более «родного» к более редкому; первый найденный выигрывает.
_detect_pkg_manager() {
    local pm
    for pm in brew apt-get dnf yum zypper pacman apk nix-env winget choco scoop port; do
        if command -v "$pm" >/dev/null 2>&1; then
            # нормализуем apt-get → apt для единообразия в _try_install_jq
            [ "$pm" = "apt-get" ] && { echo "apt"; return; }
            echo "$pm"; return
        fi
    done
    echo "none"
}

# --- Установка jq через КОНКРЕТНЫЙ известный менеджер (whitelist команд) ---
# Возврат: 0 — менеджер отработал; 1 — менеджер неизвестен/упал.
_install_jq_via_pm() {
    local pm="$1"
    echo ">> Ставлю jq через $pm (это займёт несколько секунд)..." >&2
    case "$pm" in
        brew)    brew install jq >&2 2>&1 ;;
        apt)     { sudo apt-get update -qq >&2 2>&1; sudo apt-get install -y jq >&2 2>&1; } ;;
        dnf)     sudo dnf install -y jq >&2 2>&1 ;;
        yum)     sudo yum install -y jq >&2 2>&1 ;;
        zypper)  sudo zypper --non-interactive install jq >&2 2>&1 ;;
        pacman)  sudo pacman -S --noconfirm jq >&2 2>&1 ;;
        apk)     { sudo apk add jq >&2 2>&1 || apk add jq >&2 2>&1; } ;;
        nix-env) nix-env -iA nixpkgs.jq >&2 2>&1 ;;
        port)    sudo port install jq >&2 2>&1 ;;
        winget)  winget install --id jqlang.jq -e --accept-source-agreements --accept-package-agreements >&2 2>&1 ;;
        choco)   choco install jq -y >&2 2>&1 ;;
        scoop)   scoop install jq >&2 2>&1 ;;
        *)       return 1 ;;
    esac
}

# --- УНИВЕРСАЛЬНЫЙ fallback: скачать бинарник jq напрямую с официального GitHub ---
# Работает на любой ОС/версии без пакетного менеджера. Источник захардкожен ОФИЦИАЛЬНЫЙ
# (это правильный хардкод — безопасность: не качаем jq из случайного места).
# Возврат: 0 — скачали рабочий бинарник, путь в $LOCAL_ENV_JQ; 1 — не вышло.
_install_jq_via_download() {
    local os="$1" arch="$2"
    local base="https://github.com/jqlang/jq/releases/latest/download"
    local asset=""
    case "$os/$arch" in
        Darwin/arm64)   asset="jq-macos-arm64" ;;
        Darwin/x86_64)  asset="jq-macos-amd64" ;;
        Linux/x86_64)   asset="jq-linux-amd64" ;;
        Linux/arm64)    asset="jq-linux-arm64" ;;
        Linux/i386)     asset="jq-linux-i386" ;;
        MINGW/x86_64)   asset="jq-windows-amd64.exe" ;;
        MINGW/i386)     asset="jq-windows-i386.exe" ;;
        *)              echo ">> Прямое скачивание для $os/$arch не предусмотрено." >&2; return 1 ;;
    esac

    local dest="$_SYSADMIN_BIN_DIR/jq"
    case "$asset" in *.exe) dest="$dest.exe" ;; esac

    echo ">> Пакетного менеджера нет — качаю официальный бинарник jq напрямую:" >&2
    echo "   $base/$asset → $dest" >&2
    mkdir -p "$_SYSADMIN_BIN_DIR" || { echo ">> Не смог создать $_SYSADMIN_BIN_DIR" >&2; return 1; }

    local ok=1
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$base/$asset" -o "$dest" >&2 2>&1 && ok=0
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$base/$asset" -O "$dest" >&2 2>&1 && ok=0
    else
        echo ">> Нет ни curl, ни wget — скачать не могу." >&2
        return 1
    fi
    [ "$ok" -eq 0 ] || { echo ">> Скачивание не удалось (нет сети? GitHub недоступен?)." >&2; return 1; }

    chmod +x "$dest" 2>/dev/null
    # Проверяем что бинарник реально запускается на этой системе
    if "$dest" --version >/dev/null 2>&1; then
        export PATH="$_SYSADMIN_BIN_DIR:$PATH"
        LOCAL_ENV_JQ="$dest"
        echo ">> jq скачан и работает: $("$dest" --version 2>/dev/null) ($dest)" >&2
        echo ">> Добавил $_SYSADMIN_BIN_DIR в PATH на эту сессию. Для постоянного доступа" >&2
        echo "   допиши эту папку в PATH (или просто запускай агента — он сам найдёт)." >&2
        return 0
    fi
    echo ">> Скачанный бинарник не запустился (несовместимая сборка?)." >&2
    return 1
}

# --- Ручная инструкция (последний рубеж, когда и менеджер, и скачивание не сработали) ---
_jq_manual_hint() {
    cat <<EOF >&2
Поставь jq вручную одним из способов:
  - macOS:        brew install jq   (или port install jq)
  - Debian/Ubuntu: sudo apt-get install jq
  - Fedora/RHEL:   sudo dnf install jq
  - Arch:          sudo pacman -S jq
  - openSUSE:      sudo zypper install jq
  - Alpine:        sudo apk add jq
  - Windows:       winget install --id jqlang.jq -e   (в PowerShell)
  - Любая ОС:      скачай бинарник с https://github.com/jqlang/jq/releases/latest
                   под свою ОС/архитектуру, положи в PATH, сделай исполняемым.
После установки ПЕРЕЗАПУСТИ сессию Claude Code и снова запусти /sysadmin-init.
EOF
}

# --- Инструкция по установке bash (нативный Windows без Git for Windows) ---
_bash_manual_hint() {
    cat <<'EOF' >&2
Claude Code на Windows использует bash только если установлен Git for Windows.
Без него команды идут через PowerShell, и скиллы агента не работают.
Поставь Git for Windows (в нём есть Git Bash):
  - через winget (в PowerShell):  winget install --id Git.Git -e
  - или вручную: https://git-scm.com/download/win (значения по умолчанию)
После установки ПЕРЕЗАПУСТИ сессию Claude Code.
EOF
}

# --- Главная функция гейта ---
# Аргумент 1: mode = install (default) | check
ensure_local_env() {
    local mode="${1:-install}"

    LOCAL_ENV_OS="$(_detect_local_os)"
    LOCAL_ENV_ARCH="$(_detect_arch)"
    LOCAL_ENV_PM="$(_detect_pkg_manager)"
    LOCAL_ENV_JQ="$(command -v jq 2>/dev/null || true)"

    # 1. bash. Если дошли сюда — bash есть (скрипт исполняется в нём). Ветка на случай
    #    явной диагностики; реальный отказ «нет bash» происходит ДО запуска этого файла.
    if [ -z "${BASH_VERSION:-}" ]; then
        echo "ERROR: нужен bash, а оболочка другая." >&2
        _bash_manual_hint
        return 1
    fi

    # 2. jq уже есть?
    if [ -n "$LOCAL_ENV_JQ" ]; then
        return 0
    fi

    # jq нет. В режиме check — только доклад.
    if [ "$mode" = "check" ]; then
        echo "MISSING: jq не установлен (ОС: $LOCAL_ENV_OS/$LOCAL_ENV_ARCH, менеджер: $LOCAL_ENV_PM)." >&2
        return 1
    fi

    echo "jq не найден — без него не собрать конфиг. Окружение: $LOCAL_ENV_OS/$LOCAL_ENV_ARCH." >&2

    # 3. Попытка через найденный пакетный менеджер (если есть).
    if [ "$LOCAL_ENV_PM" != "none" ]; then
        if _install_jq_via_pm "$LOCAL_ENV_PM"; then
            LOCAL_ENV_JQ="$(command -v jq 2>/dev/null || true)"
            if [ -n "$LOCAL_ENV_JQ" ]; then
                echo "OK: jq установлен и доступен ($(jq --version 2>/dev/null))." >&2
                return 0
            fi
            # Менеджер отработал, но jq не в PATH этой сессии (частый случай winget/choco)
            echo ">> jq установлен, но не виден в текущей сессии." >&2
        fi
    else
        echo ">> Пакетный менеджер не найден среди известных." >&2
    fi

    # 4. УНИВЕРСАЛЬНЫЙ fallback: прямое скачивание бинарника.
    if _install_jq_via_download "$LOCAL_ENV_OS" "$LOCAL_ENV_ARCH"; then
        return 0
    fi

    # 5. Всё перепробовали — честно сдаёмся (вызывающий скилл выдаст вердикт оператору).
    echo "" >&2
    echo "Не удалось установить jq автоматически (ни через менеджер, ни скачиванием)." >&2
    _jq_manual_hint
    return 1
}
