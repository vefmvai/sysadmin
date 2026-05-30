#!/usr/bin/env bash
# check-persona-sync.sh — линтер согласованности двухслойной персоны агента.
#
# ЗАЧЕМ. Персона живёт в двух слоях:
#   - выжимка        .claude/agents/sysadmin.md          (читается КАЖДЫЙ старт)
#   - полный слой    .claude/agents/references/*.md       (по ссылке из выжимки)
# Когда правят полный слой, а выжимку забывают — выжимка начинает врать или
# терять шаги, и агент на старте идёт по устаревшей версии. Этот линтер ловит
# рассинхрон ДО коммита. Правило — CLAUDE.md «персона двухслойна».
#
# ЧТО ПРОВЕРЯЕТ (классы дефектов из реальных инцидентов v1.9.1–v1.9.3):
#   C1. Битая ссылка: выжимка ссылается на references/FILE.md, которого нет.
#   C2. Указатель в пустоту: выжимка упоминает §3.8.N, а раздела «## 3.8.N»
#       в references/vpn-reflexes.md нет (потерянный 3.8.8/3.8.9).
#   C3. Осиротевший рефлекс: раздел «## 3.8.N» есть в references, но §3.8.N
#       не упомянут в выжимке (рефлекс существует, но агент о нём не узнает).
#   C4. Рассинхрон TTL: числа TTL слоёв (_live/_reference/_meta) в выжимке
#       не совпадают с каноном 14/60/365 (была дыра «TTL 30 дней»).
#   C5. Список шагов Cold Start: набор «Шаг N» в выжимке ≠ набору в cold-start.md
#       (потерянный Шаг 5.5).
#
# ИСПОЛЬЗОВАНИЕ:
#   bash .claude/skills/_lib/check-persona-sync.sh          # из корня sysadmin/
#   bash <path>/check-persona-sync.sh --root <sysadmin-root>
#
# КОДЫ ВОЗВРАТА: 0 — всё синхронно (PASS); 1 — найден рассинхрон (FAIL).
# Зависимости: только bash + grep + sed (jq НЕ требуется — кроссплатформенно).

set -u

# --- определить корень репо sysadmin/ -------------------------------------
ROOT=""
if [ "${1:-}" = "--root" ] && [ -n "${2:-}" ]; then
    ROOT="$2"
else
    # от расположения скрипта: _lib → skills → .claude → <root>
    SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    ROOT="$(cd "$SELF/../../.." && pwd)"
fi

PERSONA="$ROOT/.claude/agents/sysadmin.md"
REFDIR="$ROOT/.claude/agents/references"
VPNREF="$REFDIR/vpn-reflexes.md"
COLDSTART="$REFDIR/cold-start.md"

FAILS=0
note_fail() { printf '  ❌ %s\n' "$1"; FAILS=$((FAILS+1)); }
note_ok()   { printf '  ✅ %s\n' "$1"; }

if [ ! -f "$PERSONA" ]; then
    echo "FATAL: не найдена выжимка персоны: $PERSONA" >&2
    exit 1
fi

echo "── check-persona-sync ──────────────────────────────"
echo "корень: $ROOT"
echo

# --- C1. Битые ссылки на references/*.md ----------------------------------
echo "[C1] Ссылки выжимки на references/*.md существуют?"
while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    if [ -f "$REFDIR/$(basename "$ref")" ]; then
        :
    else
        note_fail "выжимка ссылается на $ref — файла нет"
    fi
done < <(grep -oE 'references/[a-z0-9-]+\.md' "$PERSONA" | sort -u)
[ "$FAILS" -eq 0 ] && note_ok "все ссылки на references/ ведут в существующие файлы"
echo

# --- C2/C3. Рефлексы §3.8.N: выжимка ↔ vpn-reflexes.md --------------------
if [ -f "$VPNREF" ]; then
    echo "[C2/C3] Рефлексы §3.8.N синхронны между выжимкой и vpn-reflexes.md?"
    # Списки во временные файлы (надёжно в bash 3.2: без heredoc/process-subst).
    # Из выжимки берём только ЖИРНЫЕ якоря «**3.8.N**» — так номера из
    # пояснительного текста (напр. «пропуск 3.8.10») не дают ложных срабатываний.
    P_LIST="$(mktemp)"; R_LIST="$(mktemp)"
    LC_ALL=C grep -oE '\*\*3\.8\.[0-9]+\*\*' "$PERSONA" | LC_ALL=C grep -oE '3\.8\.[0-9]+' | LC_ALL=C sort -u > "$P_LIST"
    LC_ALL=C grep -oE '^## 3\.8\.[0-9]+' "$VPNREF" | LC_ALL=C grep -oE '3\.8\.[0-9]+' | LC_ALL=C sort -u > "$R_LIST"

    C2=0
    while IFS= read -r num; do
        [ -z "$num" ] && continue
        if ! LC_ALL=C grep -qx "$num" "$R_LIST"; then
            note_fail "C2: 3.8.$num... упомянут в выжимке, но раздела в vpn-reflexes.md нет (указатель в пустоту): $num"
            C2=$((C2+1))
        fi
    done < "$P_LIST"
    while IFS= read -r num; do
        [ -z "$num" ] && continue
        if ! LC_ALL=C grep -qx "$num" "$P_LIST"; then
            note_fail "C3: $num раскрыт в vpn-reflexes.md, но не упомянут в выжимке (осиротевший рефлекс)"
            C2=$((C2+1))
        fi
    done < "$R_LIST"
    rm -f "$P_LIST" "$R_LIST"
    [ "$C2" -eq 0 ] && note_ok "набор 3.8.N совпадает в обоих слоях"
    echo
fi

# --- C4. TTL слоёв VPN-knowledge: канон 14/60/365 -------------------------
echo "[C4] TTL слоёв VPN-knowledge в выжимке = канон 14/60/365?"
# вытащим контекст презумпции #6 / упоминаний TTL в выжимке
TTL_CTX="$(grep -nE 'TTL|_live/|_reference/|_meta/' "$PERSONA" | grep -iE 'дн|TTL')"
BAD_TTL=0
# Запрещённое число «30 дней» рядом с VPN-knowledge — историческая дыра.
if printf '%s\n' "$TTL_CTX" | grep -qE 'TTL[^0-9]*30|30[^0-9]*(дн|day)'; then
    # убедимся, что это про VPN-knowledge, а не про ротацию секретов и т.п.
    if printf '%s\n' "$TTL_CTX" | grep -qiE 'VPN|knowledge|_live|_reference|_meta'; then
        note_fail "C4: в выжимке встречается «TTL 30 дней» в контексте VPN-knowledge — канон 14/60/365"
        BAD_TTL=$((BAD_TTL+1))
    fi
fi
# Если упомянут _live/ с TTL — число должно быть 14, _reference/ — 60, _meta/ — 365.
check_layer_ttl() {
    local layer="$1" want="$2"
    local line
    line="$(grep -nE "${layer}.{0,40}(дн|TTL)|(дн|TTL).{0,40}${layer}" "$PERSONA" | head -1)"
    [ -z "$line" ] && return 0
    if ! printf '%s\n' "$line" | grep -qE "\b${want}\b"; then
        note_fail "C4: слой ${layer} в выжимке — ожидается TTL ${want}; строка: ${line}"
        BAD_TTL=$((BAD_TTL+1))
    fi
}
check_layer_ttl "_live/" 14
check_layer_ttl "_reference/" 60
check_layer_ttl "_meta/" 365
[ "$BAD_TTL" -eq 0 ] && note_ok "TTL слоёв в выжимке согласованы с каноном (или TTL в выжимке не дублируется)"
echo

# --- C5. Список шагов Cold Start: выжимка ↔ cold-start.md ------------------
if [ -f "$COLDSTART" ]; then
    echo "[C5] Набор «Шаг N» Cold Start совпадает в выжимке и cold-start.md?"
    # шаги, перечисленные в выжимке (в §7.1: «**Шаг 0**», «**Шаг 5.5**» и т.д.)
    P_STEPS="$(grep -oE 'Шаг [0-9]+(\.[0-9]+)?' "$PERSONA" | grep -oE '[0-9]+(\.[0-9]+)?' | LC_ALL=C sort -u -t. -k1,1n -k2,2n)"
    # шаги-заголовки в cold-start.md («## Шаг N.» / «## Шаг N.M.»)
    C_STEPS="$(grep -oE '^## Шаг [0-9]+(\.[0-9]+)?' "$COLDSTART" | grep -oE '[0-9]+(\.[0-9]+)?' | LC_ALL=C sort -u -t. -k1,1n -k2,2n)"
    C5=0
    PS_FILE="$(mktemp)"; printf '%s\n' "$P_STEPS" > "$PS_FILE"
    CS_FILE="$(mktemp)"; printf '%s\n' "$C_STEPS" > "$CS_FILE"
    while IFS= read -r s; do
        [ -z "$s" ] && continue
        if ! LC_ALL=C grep -qx "$s" "$PS_FILE"; then
            note_fail "C5: Шаг $s есть в cold-start.md, но не упомянут в списке шагов выжимки (потерянный шаг)"
            C5=$((C5+1))
        fi
    done < "$CS_FILE"
    rm -f "$PS_FILE" "$CS_FILE"
    [ "$C5" -eq 0 ] && note_ok "все шаги Cold Start из cold-start.md присутствуют в выжимке"
    echo
fi

# --- вердикт ---------------------------------------------------------------
echo "────────────────────────────────────────────────────"
if [ "$FAILS" -eq 0 ]; then
    echo "PASS — персона согласована (выжимка ↔ references)."
    exit 0
else
    echo "FAIL — найдено рассинхронов: $FAILS. Синхронизируй выжимку и references (см. CLAUDE.md «персона двухслойна»)."
    exit 1
fi
