#!/bin/bash
# 05-smoke-test.sh — финальная функциональная проверка серверного прокси.
#
# Проверяет:
#  1. Панель 3X-UI работает (override сработал, петли нет).
#  2. curl https://api.anthropic.com через свежий SSH → HTTP/2 (любой статус ≠ Could not resolve).
#  3. curl https://ya.ru → HTTP/2 (быстро, через direct — РФ).
#  4. curl https://www.google.com (через VPN) → HTTP/2.
#
# Вход через ENV:
#   SSH_TARGET — SSH-цель

set -uo pipefail

SSH_TARGET="${SSH_TARGET:?SSH_TARGET обязателен}"

PASS=0
FAIL=0

check() {
    local name="$1"
    local cmd="$2"
    local expected="$3"

    echo -n "[smoke] $name ... "

    local output
    # shellcheck disable=SC2029  # client-side expansion $cmd намеренная (передаём команду на удалённый shell)
    output="$(ssh "$SSH_TARGET" "source /etc/environment 2>/dev/null; $cmd" 2>&1 | head -n5)"

    if echo "$output" | grep -qE "$expected"; then
        echo "✓"
        PASS=$((PASS + 1))
        return 0
    else
        echo "✗"
        echo "    expected: $expected"
        echo "    got: $output" | head -n3
        FAIL=$((FAIL + 1))
        return 1
    fi
}

echo "=== Smoke test серверного прокси ==="

# 1. Панель работает
check "x-ui active" \
    "systemctl is-active x-ui" \
    "^active$"

# 2. Anthropic API доступен через прокси (не должно быть Could not resolve)
check "curl api.anthropic.com через прокси" \
    "curl -sI --max-time 15 https://api.anthropic.com" \
    "HTTP/[12]"

# 3. РФ-сайт через direct (быстро)
check "curl ya.ru через direct" \
    "curl -sI --max-time 10 https://ya.ru" \
    "HTTP/[12]"

# 4. Google (через VPN)
check "curl google.com через прокси" \
    "curl -sI --max-time 15 https://www.google.com" \
    "HTTP/[12]"

# 5. socks5h работает (DNS на прокси)
check "DNS-resolution через прокси (api.openai.com)" \
    "curl -sI --max-time 15 https://api.openai.com" \
    "HTTP/[12]"

echo ""
echo "=== Итог ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "⚠ Возможные причины проблем:"
    echo "  - /etc/environment не подхватился в SSH-сессии (используем 'source')"
    echo "  - panel падает (проверь journalctl -u x-ui)"
    echo "  - upstream VPN-сервер не отвечает"
    echo "  - на сервере не установлен curl или возвращает что-то странное"
    exit 1
fi

exit 0
