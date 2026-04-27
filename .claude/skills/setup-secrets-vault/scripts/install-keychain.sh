#!/usr/bin/env bash
# install-keychain.sh — для macOS Keychain.
# Фактически Keychain встроен в macOS, ставить нечего. Скрипт только проверяет
# наличие CLI `security`, выводит примеры команд и smoke-test.

set -euo pipefail

echo "[keychain] Проверяю окружение..."

# --- 1. Проверка ОС ---
if [ "$(uname -s)" != "Darwin" ]; then
    echo "[keychain] ERROR: Keychain работает только на macOS. Текущая ОС: $(uname -s)"
    echo "[keychain] Альтернативы: pass (Linux), KeePassXC (cross-platform)."
    exit 1
fi

# --- 2. Проверка CLI ---
if ! command -v security &>/dev/null; then
    echo "[keychain] ERROR: команда 'security' не найдена. Это странно — она должна быть на любой macOS."
    echo "[keychain] Проверь PATH: which security || echo 'NOT FOUND'"
    exit 1
fi

echo "[keychain] OK — security CLI найден: $(which security)"
echo "[keychain] Версия macOS: $(sw_vers -productVersion)"

# --- 3. Smoke-test ---
echo ""
echo "[keychain] Smoke-test (создание / чтение / удаление тестового секрета):"

TEST_SERVICE="infra-smoke-test-$$"
TEST_ACCOUNT="setup-secrets-vault-test"
TEST_VALUE="test-value-$(date +%s)"

# CREATE
security add-generic-password \
    -a "$TEST_ACCOUNT" \
    -s "$TEST_SERVICE" \
    -w "$TEST_VALUE" \
    -U  # update if exists

# READ
RETRIEVED=$(security find-generic-password -a "$TEST_ACCOUNT" -s "$TEST_SERVICE" -w 2>/dev/null)

if [ "$RETRIEVED" = "$TEST_VALUE" ]; then
    echo "[keychain] CREATE ✓"
    echo "[keychain] READ   ✓ (значение совпало)"
else
    echo "[keychain] FAIL: читаю '$RETRIEVED', ожидал '$TEST_VALUE'"
    exit 1
fi

# DELETE
security delete-generic-password -a "$TEST_ACCOUNT" -s "$TEST_SERVICE" >/dev/null
echo "[keychain] DELETE ✓"

# --- 4. Примеры использования ---
cat <<'EOF'

[keychain] ============================================================
[keychain] OK — Keychain работает.
[keychain]
[keychain] Примеры команд:
[keychain]
[keychain]   # Сохранить секрет:
[keychain]   security add-generic-password -a "<account>" -s "<service>" -w "<value>" -U
[keychain]
[keychain]   # Прочитать секрет:
[keychain]   security find-generic-password -a "<account>" -s "<service>" -w
[keychain]
[keychain]   # Удалить секрет:
[keychain]   security delete-generic-password -a "<account>" -s "<service>"
[keychain]
[keychain] Соглашение проекта по именованию:
[keychain]   account: имя оператора или 'project'.
[keychain]   service: 'infra/db/postgres', 'infra/telegram/bot', 'infra/api/<service>'.
[keychain]
[keychain] Дальше: создай inventory/access.md из templates/access-md-template.md.
[keychain] ============================================================
EOF