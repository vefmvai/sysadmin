#!/bin/bash
# resolve-hwid.sh — добыть HWID (hardware ID) для запроса HWID-locked подписки.
#
# ЗАЧЕМ: некоторые провайдеры (Panterra, NurVPN и Happ-подобные) отдают реальный
# список серверов ТОЛЬКО зарегистрированному устройству — по заголовку X-Hwid.
# Незнакомый HWID → заглушка (0.0.0.0 / «App not supported»). См. ADR-0010
# и references/subscription-formats.md «Формат 5».
#
# Два пути добычи HWID (канон ADR-0010, "оба пути — агент выбирает"):
#
#   ПУТЬ A — из plist уже установленного приложения Happ (macOS).
#     Берём HWID устройства оператора, на котором подписка УЖЕ работает.
#     Слот НЕ тратим — переиспользуем существующую регистрацию. Предпочтительно.
#
#   ПУТЬ B — сгенерировать СТАБИЛЬНЫЙ HWID и сохранить рядом с подпиской в infra.
#     При первом запросе с этим HWID провайдер (если есть свободный слот)
#     привяжет его к «устройству-серверу». Стабильный = перезапуски агента
#     переиспользуют тот же HWID и НЕ жгут новые слоты.
#
# Стратегия: сначала A (если Happ установлен), иначе B. MODE форсирует путь.
#
# Использование:
#   MODE=auto|happ|generate \
#   PROVIDER_SLUG=panterra \
#   INFRA_DIR=/path/to/infra \
#   ./resolve-hwid.sh
#
# Выход (stdout): один HWID (16-символьный hex), без перевода строки.
# Диагностика (stderr): откуда взят HWID (путь A или B), путь к файлу для B.
# Возвращаемый код:
#   0 — HWID получен
#   1 — не удалось (нет Happ для MODE=happ; нет INFRA_DIR для генерации/сохранения)
#   2 — ошибка параметров

set -euo pipefail

MODE="${MODE:-auto}"                       # auto | happ | generate
PROVIDER_SLUG="${PROVIDER_SLUG:-subscription}"
# Нормализуем slug так же, как в save-subscription-servers.sh (единый стиль имён).
PROVIDER_SLUG="$(echo "$PROVIDER_SLUG" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9_-' '-' | sed 's/^-*//; s/-*$//')"
[ -z "$PROVIDER_SLUG" ] && PROVIDER_SLUG="subscription"

# --- Путь A: HWID из plist установленного Happ (только macOS) --------------
hwid_from_happ() {
    local plist="$HOME/Library/Group Containers/group.su.ffg.happ.plus/Library/Preferences/group.su.ffg.happ.plus.plist"
    [ -f "$plist" ] || return 1
    command -v plutil >/dev/null 2>&1 || return 1
    # plutil -p печатает "hwid" => "0123456789abcdef"
    local hwid
    hwid="$(plutil -p "$plist" 2>/dev/null | grep -i '"hwid"' | sed -E 's/.*=> *"?([0-9a-fA-F]+)"?.*/\1/' | head -n1)"
    # Валидируем: непустой hex длиной 12..64 (не выдумываем — берём как есть из plist)
    if [[ "$hwid" =~ ^[0-9a-fA-F]{12,64}$ ]]; then
        printf '%s' "$hwid"
        return 0
    fi
    return 1
}

# --- Путь B: стабильный сгенерированный HWID, сохранённый в infra ----------
# Файл: $INFRA/inventory/shared/vpn-subscriptions/.hwid-<provider>
# Лежит в приватной infra/ (в её .gitignore рядом с *.txt подписок) —
# в публичный репо не попадает.
hwid_from_store_or_generate() {
    if [ -z "${INFRA_DIR:-}" ]; then
        echo "ERROR: INFRA_DIR не задан — некуда сохранить стабильный HWID." >&2
        echo "       Передай infrastructure.root_path из конфига." >&2
        return 1
    fi
    local dir="${INFRA_DIR%/}/inventory/shared/vpn-subscriptions"
    local store="${dir}/.hwid-${PROVIDER_SLUG}"

    # Уже сохранён ранее → переиспользуем (НЕ жжём новый слот при перезапуске).
    if [ -f "$store" ]; then
        local existing
        existing="$(tr -d '[:space:]' < "$store")"
        if [[ "$existing" =~ ^[0-9a-fA-F]{12,64}$ ]]; then
            echo "[resolve-hwid] Путь B: переиспользую сохранённый HWID → $store" >&2
            printf '%s' "$existing"
            return 0
        fi
    fi

    # Генерируем новый стабильный 16-hex HWID (имитирует формат Happ).
    mkdir -p "$dir"
    local hwid
    if command -v python3 >/dev/null 2>&1; then
        hwid="$(python3 -c 'import secrets;print(secrets.token_hex(8))')"
    else
        hwid="$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    fi
    printf '%s' "$hwid" > "$store"
    chmod 600 "$store" 2>/dev/null || true
    echo "[resolve-hwid] Путь B: сгенерирован НОВЫЙ стабильный HWID → $store" >&2
    echo "[resolve-hwid]   ВНИМАНИЕ: первый запрос с этим HWID займёт 1 слот подписки." >&2
    echo "[resolve-hwid]   Убедись, что у оператора есть свободный слот (см. ADR-0010)." >&2
    printf '%s' "$hwid"
    return 0
}

case "$MODE" in
    happ)
        if hwid_from_happ; then
            echo "[resolve-hwid] Путь A: HWID взят из установленного Happ (слот не тратим)." >&2
            exit 0
        fi
        echo "ERROR: MODE=happ, но Happ не установлен или HWID в plist не найден." >&2
        exit 1
        ;;
    generate)
        hwid_from_store_or_generate
        ;;
    auto|*)
        # Сначала пробуем существующий Happ (бесплатно, без траты слота).
        if HWID_A="$(hwid_from_happ)"; then
            echo "[resolve-hwid] Путь A: HWID взят из установленного Happ (слот не тратим)." >&2
            printf '%s' "$HWID_A"
            exit 0
        fi
        # Happ нет → стабильный сгенерированный (займёт слот при свободном).
        echo "[resolve-hwid] Happ не установлен — перехожу к пути B (свой стабильный HWID)." >&2
        hwid_from_store_or_generate
        ;;
esac
