#!/usr/bin/env bash
# Регрессионный тест: конфиги generate-singbox-json.sh запускаются на актуальном sing-box.
#
# Исторический дефект (найден ревью 2026-10-14): для PLATFORM=ios и android генератор писал в
# TUN поля inet4_address/inet6_address, удалённые в sing-box 1.12.0. Живой прогон sing-box
# 1.14.3: «FATAL … legacy tun address fields are deprecated in sing-box 1.10.0 and removed in
# sing-box 1.12.0». То есть конфиги для iPhone и Android не запускались ни на одном актуальном
# клиенте sing-box (SFA, sing-box MT, NekoBox). Планку 1.11 держал sing-box-vt, его сняли.
#
# Прогон: bash .claude/skills/generate-client-config/tests/test-singbox-config-valid.sh
# Живая проверка: SINGBOX_BIN=/путь/к/sing-box (или sing-box в PATH) — тогда каждый конфиг
# прогоняется через `sing-box check`. Без бинаря — только статика, и тест это сообщает.
# Офлайновый: панель и сеть не нужны.

set -uo pipefail
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GEN="$SKILL_DIR/scripts/generate-singbox-json.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✅ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ❌ $1"; }

SB="${SINGBOX_BIN:-$(command -v sing-box 2>/dev/null || true)}"
if [ -n "$SB" ] && "$SB" version >/dev/null 2>&1; then
    echo "ℹ️  живая проверка: $("$SB" version | head -1)"
else
    SB=""; echo "⚠️  sing-box не найден (SINGBOX_BIN): только статика — запуск конфигов НЕ проверен"
fi

URL='vless://00000000-0000-0000-0000-000000000000@vpn.example.com:443?type=tcp&encryption=none&security=tls&sni=vpn.example.com&alpn=http%2F1.1&fp=chrome#t'
for RS in no yes; do
  for P in ios android desktop universal; do
    OUT="$WORK/$P-$RS.json"
    if ! PLATFORM="$P" USE_RULE_SET="$RS" VLESS_URL="$URL" bash "$GEN" > "$OUT" 2>"$WORK/err"; then
        no "$P (rule_set=$RS): генератор упал: $(tail -1 "$WORK/err")"; continue
    fi
    if jq -e '[.. | objects | select(has("inet4_address") or has("inet6_address"))] | length == 0' "$OUT" >/dev/null; then
        ok "$P (rule_set=$RS): удалённых в 1.12 полей TUN нет"
    else no "$P (rule_set=$RS): в конфиге inet4_address/inet6_address (удалены в sing-box 1.12.0)"; fi
    if [ -n "$SB" ]; then
        # Windows-овому sing-box путь нужен в форме Windows; cygpath есть только в Git Bash.
        CFG="$OUT"; command -v cygpath >/dev/null 2>&1 && CFG="$(cygpath -w "$OUT")"
        if R="$("$SB" check -c "$CFG" 2>&1)"; then ok "$P (rule_set=$RS): sing-box check — конфиг принят"
        else no "$P (rule_set=$RS): sing-box check: $(printf '%s' "$R" | head -1 | cut -c1-160)"; fi
    fi
  done
done

echo
[ -z "$SB" ] && echo "⚠️  без SINGBOX_BIN тест не доказывает, что конфиги запускаются"
echo "Итог: пройдено $PASS, провалено $FAIL"
[ "$FAIL" -eq 0 ]
