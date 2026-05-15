#!/usr/bin/env bash
# 06-validate-reality-dest.sh — проверка serverName для VLESS+Reality inbound.
#
# Требования к serverName (из официальной документации XTLS/REALITY):
#  1. TLS 1.3 + HTTP/2 — обязательно.
#  2. Не redirect-only (главный домен → www допустим).
#  3. OCSP stapling — желательно.
#  4. Encrypted handshake messages после Server Hello — желательно
#     (примеры: dl.google.com, www.cloudflare.com, www.microsoft.com).
#  5. Не подсанкционный для региона сервера.
#  6. Не совпадает с доменом самой панели (см. vpn-protocols.md §6.3).
#
# Используется в /setup-vpn-panel при LOCATION=foreign-server.
#
# Вход через ENV:
#   REALITY_DEST  — домен-кандидат (например, www.cloudflare.com)
#   PANEL_DOMAIN  — домен панели (для проверки, что не совпадают)
#
# Выход:
#   0 — домен подходит
#   1 — домен не подходит (печатает причину)
#   2 — ошибка параметров

set -uo pipefail

REALITY_DEST="${REALITY_DEST:?REALITY_DEST обязателен}"
PANEL_DOMAIN="${PANEL_DOMAIN:-}"

# Используем общий helper
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
LIB_PATH="${REPO_ROOT}/scripts/lib-api/3xui.sh"

# shellcheck source=/dev/null
source "$LIB_PATH"

echo "[reality-dest] Проверка домена '$REALITY_DEST'..."

# Защита: не совпадает с панелью
if [ -n "$PANEL_DOMAIN" ] && [ "$REALITY_DEST" = "$PANEL_DOMAIN" ]; then
    echo "[reality-dest] ✗ serverName ($REALITY_DEST) НЕ должен совпадать с доменом панели ($PANEL_DOMAIN)"
    echo "[reality-dest]   Причина: цензор может выполнить active probing, сравнить TLS-сертификат с реальным сайтом, обнаружить несоответствие и пометить как circumvention traffic."
    exit 1
fi

# Защита: не совпадает с поддоменом панели
if [ -n "$PANEL_DOMAIN" ]; then
    BASE_PANEL_DOMAIN="$(echo "$PANEL_DOMAIN" | awk -F. '{n=NF; printf "%s.%s\n", $(n-1), $n}')"
    BASE_REALITY_DEST="$(echo "$REALITY_DEST" | awk -F. '{n=NF; printf "%s.%s\n", $(n-1), $n}')"
    if [ "$BASE_PANEL_DOMAIN" = "$BASE_REALITY_DEST" ]; then
        echo "[reality-dest] ⚠ serverName ($REALITY_DEST) находится в той же базовой зоне, что и панель ($PANEL_DOMAIN)"
        echo "[reality-dest]   Это допустимо, но менее безопасно. Лучше выбрать совершенно независимый домен."
        # warning, не fail
    fi
fi

# Используем helper из lib-api
if api_validate_reality_dest "$REALITY_DEST"; then
    echo "[reality-dest] ✓ Домен '$REALITY_DEST' подходит для Reality serverName"
    echo "[reality-dest]   - TLS 1.3 + HTTP/2: OK"
    echo "[reality-dest]   - HTTP-статус: OK (200 или 30x)"

    # Дополнительные проверки (информационные, не блокирующие)
    echo ""
    echo "[reality-dest] Дополнительные характеристики (информационно):"

    # OCSP stapling
    if echo | openssl s_client -servername "$REALITY_DEST" -connect "${REALITY_DEST}:443" -status -tls1_3 2>/dev/null | grep -q "OCSP response: no response"; then
        echo "[reality-dest]   ⚠ OCSP stapling НЕ найден"
    else
        echo "[reality-dest]   ✓ OCSP stapling: OK"
    fi

    # TLS 1.3 + HTTP/2 уже проверены в api_validate_reality_dest
    exit 0
else
    echo "[reality-dest] ✗ Домен '$REALITY_DEST' не подходит"
    echo "[reality-dest]   Возможные причины:"
    echo "[reality-dest]     - Не поддерживает TLS 1.3 + HTTP/2"
    echo "[reality-dest]     - Возвращает 4xx/5xx или таймаутит"
    echo "[reality-dest]     - Сетевой блокировки между нашим сервером и доменом"
    echo ""
    echo "[reality-dest] Проверенные альтернативы (используются в комьюнити):"
    echo "[reality-dest]     - www.cloudflare.com"
    echo "[reality-dest]     - dl.google.com"
    echo "[reality-dest]     - www.microsoft.com"
    echo "[reality-dest]     - www.amazon.com"
    echo "[reality-dest]     - www.apple.com"
    echo "[reality-dest]   ВАЖНО: домен-донор должен быть географически близко к серверу прокси."
    exit 1
fi
