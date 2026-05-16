#!/usr/bin/env bash
# install-pass.sh — ставит pass + gnupg2 на Linux (Debian/Ubuntu),
# создаёт GPG-ключ если его нет, инициализирует pass-store.
# Идемпотентный.

set -euo pipefail

echo "[pass] Установка pass + gnupg2..."

# --- 1. Проверка ОС ---
if [ "$(uname -s)" != "Linux" ]; then
    echo "[pass] WARNING: pass обычно используется на Linux. Текущая ОС: $(uname -s)"
    echo "[pass] На macOS можно ставить через 'brew install pass gnupg', но рекомендуется Keychain."
fi

# --- 2. Установка пакетов ---
if ! command -v pass &>/dev/null || ! command -v gpg &>/dev/null; then
    if command -v apt-get &>/dev/null; then
        sudo apt-get update -y
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y pass gnupg2
    elif command -v brew &>/dev/null; then
        brew install pass gnupg
    else
        echo "[pass] ERROR: не нашёл apt-get или brew. Установи pass и gnupg вручную."
        exit 1
    fi
else
    echo "[pass] pass и gnupg уже установлены — пропускаю установку"
fi

echo "[pass] Версии:"
pass --version | head -1
gpg --version | head -1

# --- 3. Проверка GPG-ключа ---
echo ""
echo "[pass] Проверяю GPG-ключи..."

GPG_KEYS=$(gpg --list-secret-keys --keyid-format LONG 2>/dev/null | grep -cE '^(sec|ssb)')

if [ "$GPG_KEYS" -eq 0 ]; then
    echo "[pass] Нет GPG-ключей — нужно создать."
    echo ""
    echo "[pass] Запусти ВРУЧНУЮ (интерактивно):"
    echo ""
    echo "    gpg --full-generate-key"
    echo ""
    echo "[pass] Параметры:"
    echo "    Тип ключа:    (1) RSA and RSA"
    echo "    Размер:       4096"
    echo "    Срок:         0 (не истекает) или 2y"
    echo "    Имя:          <твоё имя>"
    echo "    Email:        <твой email>"
    echo "    Passphrase:   надёжная (запиши в Keychain если есть, или в надёжное место)"
    echo ""
    echo "[pass] После создания запусти этот скрипт снова."
    exit 0
fi

echo "[pass] GPG-ключи найдены:"
gpg --list-secret-keys --keyid-format LONG | grep -E '^(sec|uid)'

# Получить email первого ключа автоматически
DEFAULT_KEY=$(gpg --list-secret-keys --with-colons | awk -F: '/^uid/ {print $10; exit}' | sed 's/.*<\(.*\)>.*/\1/')
echo "[pass] Будет использован ключ для: $DEFAULT_KEY"

# --- 4. Инициализация pass ---
if [ ! -d "$HOME/.password-store" ] || [ ! -f "$HOME/.password-store/.gpg-id" ]; then
    pass init "$DEFAULT_KEY"
    echo "[pass] pass-store инициализирован в ~/.password-store"
else
    echo "[pass] pass-store уже инициализирован"
fi

# --- 5. Настройка gpg-agent для кэширования passphrase ---
mkdir -p "$HOME/.gnupg"
chmod 700 "$HOME/.gnupg"

GPG_AGENT_CONF="$HOME/.gnupg/gpg-agent.conf"
if ! grep -q "default-cache-ttl" "$GPG_AGENT_CONF" 2>/dev/null; then
    cat >> "$GPG_AGENT_CONF" <<'EOF'
# Кэш passphrase — 1 час обычный, 8 часов максимум
default-cache-ttl 3600
max-cache-ttl 28800
EOF
    gpgconf --kill gpg-agent 2>/dev/null || true
    echo "[pass] gpg-agent настроен на кэш passphrase 1ч (max 8ч)"
fi

# --- 6. Smoke-test ---
echo ""
echo "[pass] Smoke-test:"
TEST_NAME="infra-smoke-test-$$"
TEST_VALUE="test-value-$(date +%s)"

echo "$TEST_VALUE" | pass insert -e "$TEST_NAME"
RETRIEVED=$(pass "$TEST_NAME")

if [ "$RETRIEVED" = "$TEST_VALUE" ]; then
    echo "[pass] CREATE ✓"
    echo "[pass] READ   ✓"
else
    echo "[pass] FAIL: читаю '$RETRIEVED', ожидал '$TEST_VALUE'"
    exit 1
fi

pass rm -f "$TEST_NAME" >/dev/null
echo "[pass] DELETE ✓"

cat <<EOF

[pass] ============================================================
[pass] OK — pass работает с GPG-ключом ${DEFAULT_KEY}.
[pass]
[pass] Примеры команд:
[pass]
[pass]   # Сохранить секрет (интерактивно — спросит значение):
[pass]   pass insert infra/db/postgres
[pass]
[pass]   # Сохранить из stdin:
[pass]   echo 'my-secret' | pass insert -e infra/db/postgres
[pass]
[pass]   # Прочитать:
[pass]   pass infra/db/postgres
[pass]
[pass]   # Удалить:
[pass]   pass rm infra/db/postgres
[pass]
[pass]   # Список:
[pass]   pass ls
[pass]
[pass] Бэкап pass-store: ~/.password-store/ — это git-репозиторий по умолчанию.
[pass] Можно push'ать на приватный git-сервер (он содержит только зашифрованные .gpg файлы).
[pass]
[pass] Дальше: создай inventory/access.md из templates/access-md-template.md.
[pass] ============================================================
EOF