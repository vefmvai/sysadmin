#!/usr/bin/env bash
# install-keepassxc.sh — ставит KeePassXC через apt (Linux) или brew (macOS).
# KeePassXC — cross-platform GUI + CLI менеджер с локальным .kdbx-файлом.

set -euo pipefail

echo "[keepassxc] Установка KeePassXC..."

# --- 1. Установка ---
if command -v keepassxc-cli &>/dev/null; then
    echo "[keepassxc] Уже установлен:"
    keepassxc-cli --version
else
    case "$(uname -s)" in
        Linux*)
            if ! command -v apt-get &>/dev/null; then
                echo "[keepassxc] ERROR: не нашёл apt-get. Установи KeePassXC вручную:"
                echo "  https://keepassxc.org/download/"
                exit 1
            fi
            sudo apt-get update -y
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y keepassxc
            ;;
        Darwin*)
            if ! command -v brew &>/dev/null; then
                echo "[keepassxc] ERROR: не нашёл brew. Установи Homebrew или скачай KeePassXC вручную:"
                echo "  https://keepassxc.org/download/"
                exit 1
            fi
            brew install --cask keepassxc
            ;;
        *)
            echo "[keepassxc] ERROR: ОС $(uname -s) не поддерживается этим скриптом."
            echo "[keepassxc] Скачай вручную: https://keepassxc.org/download/"
            exit 1
            ;;
    esac
fi

echo ""
echo "[keepassxc] Версия:"
keepassxc-cli --version

# --- 2. Проверка / создание базы данных ---
KDBX_PATH="${KDBX_PATH:-$HOME/secrets.kdbx}"

if [ ! -f "$KDBX_PATH" ]; then
    cat <<EOF

[keepassxc] База данных $KDBX_PATH не существует.
[keepassxc] Запусти ВРУЧНУЮ (интерактивно — спросит master-пароль):

    keepassxc-cli db-create --set-password "$KDBX_PATH"

[keepassxc] Master-пароль:
    - длинный (≥20 символов или 4-5 длинных слов через пробел)
    - запомни его (или запиши в Keychain / другой менеджер)
    - НИКОГДА не теряй — без master-пароля .kdbx-файл бесполезен

[keepassxc] После создания базы запусти этот скрипт снова — будет smoke-test.
EOF
    exit 0
fi

echo "[keepassxc] База существует: $KDBX_PATH"
echo "[keepassxc] Размер: $(du -h "$KDBX_PATH" | cut -f1)"

# --- 3. Smoke-test ---
echo ""
echo "[keepassxc] Smoke-test (потребует master-пароль базы — введи интерактивно):"

TEST_ENTRY="infra-smoke-test-$$"
TEST_VALUE="test-value-$(date +%s)"

# CREATE
echo "$TEST_VALUE" | keepassxc-cli add -p "$KDBX_PATH" "$TEST_ENTRY" >/dev/null

# READ
RETRIEVED=$(keepassxc-cli show -s -a Password "$KDBX_PATH" "$TEST_ENTRY" 2>/dev/null)

if [ "$RETRIEVED" = "$TEST_VALUE" ]; then
    echo "[keepassxc] CREATE ✓"
    echo "[keepassxc] READ   ✓"
else
    echo "[keepassxc] FAIL: читаю '$RETRIEVED', ожидал '$TEST_VALUE'"
    exit 1
fi

# DELETE
keepassxc-cli rm "$KDBX_PATH" "$TEST_ENTRY" >/dev/null
echo "[keepassxc] DELETE ✓"

cat <<EOF

[keepassxc] ============================================================
[keepassxc] OK — KeePassXC работает.
[keepassxc]
[keepassxc] Примеры команд (CLI):
[keepassxc]
[keepassxc]   # Добавить запись:
[keepassxc]   keepassxc-cli add -p "$KDBX_PATH" infra/db/postgres
[keepassxc]
[keepassxc]   # Прочитать пароль:
[keepassxc]   keepassxc-cli show -s -a Password "$KDBX_PATH" infra/db/postgres
[keepassxc]
[keepassxc]   # Список:
[keepassxc]   keepassxc-cli ls "$KDBX_PATH"
[keepassxc]
[keepassxc]   # Удалить:
[keepassxc]   keepassxc-cli rm "$KDBX_PATH" infra/db/postgres
[keepassxc]
[keepassxc] Работа через GUI — запусти 'keepassxc &' и открой $KDBX_PATH.
[keepassxc]
[keepassxc] БЭКАП $KDBX_PATH: файл — единая точка отказа. Сделай как минимум:
[keepassxc]   - Регулярная копия в облако (Dropbox/iCloud/syncthing).
[keepassxc]   - Распечатанный fallback master-password в сейфе.
[keepassxc]
[keepassxc] Дальше: создай inventory/access.md из templates/access-md-template.md.
[keepassxc] ============================================================
EOF