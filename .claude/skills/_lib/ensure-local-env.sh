#!/usr/bin/env bash
# ensure-local-env.sh — гейт локального окружения (bash+jq) для машины оператора.
#
# Подключён в `/sysadmin-init` (Шаг 0.0) — это критический вход, где окружение
# проверяется ОДИН раз при первичной настройке. Другие локальные скиллы (Cold Start,
# inventory-scan и т.п.) полагаются на то, что jq уже есть (его доустановил init),
# а также на поведенческую защиту C.9 персоны: при упавшей машинерии агент STOP'ает,
# а не импровизирует суррогат. Если понадобится жёсткий гейт в ещё одном скилле —
# вызови `ensure_local_env check` (только проверка, без автоустановки) в его Шаге 0.
#
# Проблема, ради которой этот файл существует:
#   Весь агент архитектурно стоит на bash + jq. На нативном Windows Claude Code
#   использует bash ТОЛЬКО если установлен Git for Windows; иначе падает на
#   PowerShell, где bash-скрипты не исполняются вообще. Даже при наличии bash
#   `jq` НЕ входит в Git for Windows — его ставят отдельно. Без jq весь
#   sysadmin-init не может собрать конфиг.
#
#   Если этого не проверить ЯВНО в начале — машинерия молча падает на середине,
#   а агент (LLM) импровизирует руками и создаёт суррогаты (мёртвый infra.md
#   вместо нормальной папки infra/ с sysadmin-config.json). Инцидент 2026-05-24.
#
# Контракт: этот гейт ОБЯЗАН пройти ДО любой работы с конфигом. Если он не
# проходит — скилл STOP, агент НЕ продолжает импровизацией (см. C.9 персоны).
#
# Использование (в bash-блоке SKILL.md или в начале скрипта):
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
#   source "$SCRIPT_DIR/../_lib/ensure-local-env.sh"
#   ensure_local_env          # печатает диагноз; exit 1 если окружение непригодно
#
# Режимы:
#   ensure_local_env          # default: пытается доустановить недостающее, при
#                             #          неудаче — STOP с понятной инструкцией
#   ensure_local_env check    # только проверка, ничего не ставит (для health-check)
#
# Возврат:
#   0 — окружение пригодно (bash + jq доступны).
#   1 — окружение непригодно, выведена инструкция оператору.
#
# Переменные после вызова:
#   $LOCAL_ENV_OS   — Darwin | Linux | MINGW (Git Bash на Windows) | unknown
#   $LOCAL_ENV_PM   — пакетный менеджер для автоустановки: brew|apt|winget|choco|none

# Защита от двойного source
[ -n "${_SYSADMIN_ENSURE_ENV_LOADED:-}" ] && return 0
_SYSADMIN_ENSURE_ENV_LOADED=1

# --- Детект ОС (кросс-платформенно, не падает если uname нет) ---
_detect_local_os() {
    # На нативном Windows без bash этот скрипт вообще не запустится (нечем).
    # Значит мы либо в Git Bash (MINGW/MSYS), либо в WSL/macOS/Linux.
    case "${OSTYPE:-}" in
        darwin*) echo "Darwin"; return ;;
        linux-gnu*|linux*) echo "Linux"; return ;;
        msys*|cygwin*) echo "MINGW"; return ;;
    esac
    # OSTYPE может быть пуст в некоторых оболочках — пробуем uname
    if command -v uname >/dev/null 2>&1; then
        case "$(uname -s 2>/dev/null)" in
            Darwin) echo "Darwin"; return ;;
            Linux) echo "Linux"; return ;;
            MINGW*|MSYS*|CYGWIN*) echo "MINGW"; return ;;
        esac
    fi
    echo "unknown"
}

# --- Какой пакетный менеджер доступен для автоустановки ---
_detect_pkg_manager() {
    local os="$1"
    case "$os" in
        Darwin)
            command -v brew >/dev/null 2>&1 && { echo "brew"; return; }
            ;;
        Linux)
            command -v apt-get >/dev/null 2>&1 && { echo "apt"; return; }
            command -v dnf >/dev/null 2>&1 && { echo "dnf"; return; }
            command -v pacman >/dev/null 2>&1 && { echo "pacman"; return; }
            ;;
        MINGW)
            # winget и choco — это Windows-нативные менеджеры. Из Git Bash
            # они вызываются как winget.exe / choco.exe (если в PATH).
            command -v winget >/dev/null 2>&1 && { echo "winget"; return; }
            command -v choco >/dev/null 2>&1 && { echo "choco"; return; }
            ;;
    esac
    echo "none"
}

# --- Ручная инструкция по установке jq (fallback когда автоустановка невозможна) ---
_jq_manual_hint() {
    case "$1" in
        Darwin) echo "  brew install jq" ;;
        Linux)  echo "  sudo apt-get install -y jq   (Debian/Ubuntu)" ;;
        MINGW)  cat <<'EOF'
  Вариант 1 (через winget, в PowerShell):  winget install --id jqlang.jq -e
  Вариант 2 (через Chocolatey):            choco install jq -y
  Вариант 3 (вручную): скачай jq-win64.exe с https://jqlang.github.io/jq/download/,
            переименуй в jq.exe и положи рядом с git в PATH
            (например C:\Program Files\Git\mingw64\bin\).
  После установки перезапусти сессию Claude Code, чтобы jq появился в PATH.
EOF
                ;;
        *) echo "  Установи jq для своей ОС: https://jqlang.github.io/jq/download/" ;;
    esac
}

# --- Инструкция по установке bash (для нативного Windows без Git) ---
_bash_manual_hint() {
    cat <<'EOF'
Claude Code на Windows использует bash, только если установлен Git for Windows.
Без него команды идут через PowerShell, и скиллы агента не работают.

Поставь Git for Windows (в нём есть Git Bash):
  Вариант 1 (через winget, в PowerShell):  winget install --id Git.Git -e
  Вариант 2 (вручную): скачай с https://git-scm.com/download/win и установи
            со значениями по умолчанию.
После установки ПЕРЕЗАПУСТИ сессию Claude Code — тогда Bash-инструмент пойдёт
через Git Bash, и я смогу нормально настроить агента.
EOF
}

# --- Попытка автоустановки jq через найденный пакетный менеджер ---
# Возврат: 0 — поставили и jq теперь доступен; 1 — не вышло.
_try_install_jq() {
    local pm="$1"
    echo ">> Пробую установить jq через $pm ..." >&2
    case "$pm" in
        brew)   brew install jq >&2 2>&1 ;;
        apt)    sudo apt-get update -qq >&2 2>&1 && sudo apt-get install -y jq >&2 2>&1 ;;
        dnf)    sudo dnf install -y jq >&2 2>&1 ;;
        pacman) sudo pacman -S --noconfirm jq >&2 2>&1 ;;
        winget) winget install --id jqlang.jq -e --accept-source-agreements --accept-package-agreements >&2 2>&1 ;;
        choco)  choco install jq -y >&2 2>&1 ;;
        *)      return 1 ;;
    esac
    # winget/choco кладут jq.exe в PATH, который в текущей сессии может не
    # обновиться — поэтому проверяем заново и честно сообщаем про перезапуск.
    command -v jq >/dev/null 2>&1
}

# --- Главная функция гейта ---
# Аргумент 1: mode = install (default) | check
ensure_local_env() {
    local mode="${1:-install}"

    LOCAL_ENV_OS="$(_detect_local_os)"
    LOCAL_ENV_PM="$(_detect_pkg_manager "$LOCAL_ENV_OS")"

    # 1. bash. Если мы дошли сюда — bash уже есть (скрипт исполняется в нём).
    #    Эта ветка — на случай явной диагностики/документации, не реальный отказ.
    if [ -z "${BASH_VERSION:-}" ]; then
        echo "ERROR: этот скрипт требует bash, а исполняется в другой оболочке." >&2
        _bash_manual_hint >&2
        return 1
    fi

    # 2. jq — критичная зависимость всего sysadmin-init.
    if command -v jq >/dev/null 2>&1; then
        return 0   # всё на месте
    fi

    # jq нет. В режиме check — просто докладываем и выходим.
    if [ "$mode" = "check" ]; then
        echo "MISSING: jq не установлен (ОС: $LOCAL_ENV_OS, менеджер: $LOCAL_ENV_PM)." >&2
        return 1
    fi

    # Режим install: пытаемся доустановить.
    echo "jq не найден — без него я не могу собрать конфиг. ОС: $LOCAL_ENV_OS." >&2

    if [ "$LOCAL_ENV_PM" != "none" ]; then
        if _try_install_jq "$LOCAL_ENV_PM"; then
            echo "OK: jq установлен и доступен ($(jq --version 2>/dev/null))." >&2
            return 0
        fi
        # Поставили, но в текущем PATH ещё не видно (частый случай winget/choco)
        echo "" >&2
        echo "jq, возможно, установлен, но недоступен в текущей сессии." >&2
        echo "ПЕРЕЗАПУСТИ сессию Claude Code и снова запусти /sysadmin-init." >&2
        echo "Если после перезапуска jq всё ещё не виден — поставь вручную:" >&2
        _jq_manual_hint "$LOCAL_ENV_OS" >&2
        return 1
    fi

    # Автоустановка невозможна — нет пакетного менеджера. Честная инструкция.
    echo "" >&2
    echo "Не нашёл пакетный менеджер для автоустановки. Поставь jq вручную:" >&2
    _jq_manual_hint "$LOCAL_ENV_OS" >&2
    return 1
}
