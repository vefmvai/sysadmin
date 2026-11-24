#!/usr/bin/env bash
# Тест процедуры «обнови sysadmin» (cold-start.md, Шаг 5.5; ADR-0040).
# Прогон: bash .claude/hooks/tests/test-upgrade-procedure.sh
#
# Процедура записана кодом внутри документа, и агент исполняет её по тексту. Поэтому тест
# берёт блок ДОСЛОВНО из cold-start.md (источник правды, а не пересказ) и гоняет его на
# сценариях установки мозга. Сценарии и первые четыре поломки нашла независимая проверка
# 15.09.2026: свой коммит на отсоединённом HEAD терялся, тег-двойник выкатывался,
# конфликт слияния заканчивался словом «Готово», мозг впереди релиза откатывался.
#
# Параметры — испытать тест на исторической версии:
#   DOC=<cold-start.md>   откуда брать блок процедуры;
#   HOOK=<скрипт>         какой brain-update-check.sh положить в мозг-фикстуру.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
DOC="${DOC:-$REPO/.claude/agents/references/cold-start.md}"
HOOK="${HOOK:-$REPO/.claude/hooks/brain-update-check.sh}"
PASS=0; FAIL=0; POUT=""; PRC=0

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
T="$TMP/обнови с пробелом"
mkdir -p "$T"

# Изоляция от глобальной настройки git машины — окружение фикстуры, не подопечного.
export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.name test
git config --global user.email test@example.invalid
git config --global init.defaultBranch main
git config --global advice.detachedHead false

ok()  { PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$1"; printf '%s\n' "$POUT" | tail -6 | sed 's/^/       | /'; }

echo "── Тест процедуры «обнови sysadmin» (ADR-0040) ────────────"

BLOCK="$TMP/block.sh"
awk '/^\*\*Когда оператор говорит «обнови sysadmin»:\*\*/{f=1;next} f&&/^```bash/{g=1;next} g&&/^```/{exit} g{print}' "$DOC" \
    | tr -d '\r' > "$BLOCK"
if [ ! -s "$BLOCK" ]; then
    bad "блок процедуры не найден в $DOC — тест потерял источник"
    echo "Итог: пройдено $PASS, провалено $FAIL"; exit 1
fi

# Автор: релизы 2.12.2, 2.13.0, 2.14.0 (аннотированные теги, как настоящие) и коммит
# разработки 2.15.0 без тега поверх.
SEED="$T/seed"
git init -q "$SEED"
mkdir -p "$SEED/.claude/hooks"
cp "$HOOK" "$SEED/.claude/hooks/brain-update-check.sh"
printf '/.update-check\n' > "$SEED/.gitignore"
for v in 2.12.2 2.13.0 2.14.0; do
    printf '%s\n' "$v" > "$SEED/VERSION"
    git -C "$SEED" add -A; git -C "$SEED" commit -q -m "release $v"
    git -C "$SEED" tag -a -m "v$v" "v$v"
done
printf '2.15.0\n' > "$SEED/VERSION"; git -C "$SEED" commit -qam "dev 2.15.0"
U="$T/author.git"
git clone -q --bare "$SEED" "$U"

clone() { git clone -q "$U" "$T/$1"; printf '%s\n' "$T/$1"; }
proc()  { POUT="$(cd "$1" && bash "$BLOCK" 2>&1)"; PRC=$?; }
at()    { [ "$(git -C "$1" rev-parse HEAD)" = "$(git -C "$1" rev-parse "$2^{commit}" 2>/dev/null)" ]; }
said()  { printf '%s\n' "$POUT" | grep -q "$1"; }

echo "[1] Версионированная установка переключается на последний релиз"
D="$(clone s1)"; git -C "$D" reset -q --hard v2.13.0; git -C "$D" tag -d v2.14.0 >/dev/null
proc "$D"
if [ "$PRC" -eq 0 ] && at "$D" v2.14.0; then ok "клон на main, отстал на один релиз → HEAD на v2.14.0"
else bad "клон на main, отстал на один релиз — код $PRC"; fi
D="$(clone s2)"; git -C "$D" reset -q --hard v2.12.2; git -C "$D" tag -d v2.13.0 v2.14.0 >/dev/null
proc "$D"
if [ "$PRC" -eq 0 ] && at "$D" v2.14.0; then ok "клон на main, отстал на два релиза → HEAD на v2.14.0"
else bad "клон на main, отстал на два релиза — код $PRC"; fi
D="$(clone s3)"; git -C "$D" checkout -q --detach v2.12.2
proc "$D"
if [ "$PRC" -eq 0 ] && at "$D" v2.14.0; then ok "отсоединён на старом теге → HEAD на v2.14.0"
else bad "отсоединён на старом теге — код $PRC"; fi

echo "[2] Своя копия мозга: релиз сливается, свои коммиты остаются"
D="$(clone s4)"; git -C "$D" reset -q --hard v2.12.2
printf 'моё\n' > "$D/notes.txt"; git -C "$D" add notes.txt; git -C "$D" commit -q -m "мой коммит"
OWN="$(git -C "$D" rev-parse HEAD)"
git clone -q --bare "$D" "$T/personal.git"
git -C "$D" remote rename origin upstream; git -C "$D" remote add origin "$T/personal.git"
proc "$D"
if [ "$PRC" -eq 0 ] && git -C "$D" merge-base --is-ancestor "$OWN" HEAD \
   && git -C "$D" merge-base --is-ancestor v2.14.0 HEAD && git -C "$D" symbolic-ref -q HEAD >/dev/null; then
    ok "ветка со своим коммитом, релизы у upstream → слияние, свой коммит в HEAD, ветка на месте"
else bad "ветка со своим коммитом — код $PRC"; fi

echo "[3] Опасные состояния — СТОП без изменений"
D="$(clone s5)"; git -C "$D" checkout -q --detach v2.13.0
printf 'моё\n' > "$D/notes.txt"; git -C "$D" add notes.txt; git -C "$D" commit -q -m "local tweaks"
OWN="$(git -C "$D" rev-parse HEAD)"
proc "$D"
if [ "$PRC" -ne 0 ] && [ "$(git -C "$D" rev-parse HEAD)" = "$OWN" ] && ! said 'Готово'; then
    ok "свой коммит поверх отсоединённого тега → СТОП, HEAD не тронут"
else bad "свой коммит поверх отсоединённого тега — код $PRC, коммит в HEAD: $(git -C "$D" merge-base --is-ancestor "$OWN" HEAD && echo да || echo НЕТ)"; fi

D="$(clone s6)"; git -C "$D" checkout -q --detach v2.12.2; git -C "$D" tag -d v2.13.0 v2.14.0 >/dev/null
printf 'ПОДДЕЛКА\n' > "$D/FAKE"; git -C "$D" add FAKE; git -C "$D" commit -q -m "чужой v2.14.0"
git -C "$D" tag v2.14.0; git -C "$D" checkout -q --detach v2.12.2
proc "$D"
if [ "$PRC" -ne 0 ] && [ ! -f "$D/FAKE" ] && at "$D" v2.12.2 && ! said 'Готово'; then
    ok "локальный тег-двойник v2.14.0 → СТОП, подделка не выкачена"
else bad "тег-двойник — код $PRC, FAKE в дереве: $([ -f "$D/FAKE" ] && echo ЕСТЬ || echo нет)"; fi

D="$(clone s9)"; git -C "$D" reset -q --hard v2.12.2
printf '2.12.3\n' > "$D/VERSION"; git -C "$D" commit -qam "свой номер версии"
proc "$D"
if [ "$PRC" -ne 0 ] && ! said 'Готово'; then ok "конфликт при слиянии → СТОП, «Готово» не сказано"
else bad "конфликт при слиянии — код $PRC"; fi

D="$(clone s10)"; git -C "$D" reset -q --hard v2.13.0; git -C "$D" tag -d v2.14.0 >/dev/null
printf 'правка\n' >> "$D/.gitignore"
proc "$D"
if [ "$PRC" -ne 0 ] && at "$D" v2.13.0 && grep -q 'правка' "$D/.gitignore"; then
    ok "незакоммиченные правки → СТОП, правки на месте"
else bad "незакоммиченные правки — код $PRC"; fi

echo "[4] Обновлять нечего — ничего не меняется"
D="$(clone s7)"; git -C "$D" checkout -q --detach origin/main
BEFORE="$(git -C "$D" rev-parse HEAD)"
proc "$D"
if [ "$PRC" -eq 0 ] && [ "$(git -C "$D" rev-parse HEAD)" = "$BEFORE" ]; then ok "мозг впереди релиза (dev 2.15.0) → не откатывает"
else bad "мозг впереди релиза — код $PRC, HEAD сдвинут: $(git -C "$D" describe --tags --always)"; fi
D="$(clone s8)"; git -C "$D" reset -q --hard v2.14.0
proc "$D"
if [ "$PRC" -eq 0 ] && at "$D" v2.14.0; then ok "уже на последнем релизе → без изменений"
else bad "уже на последнем релизе — код $PRC"; fi

echo "────────────────────────────────────────────────────"
echo "Итог: пройдено $PASS, провалено $FAIL"
[ "$FAIL" -eq 0 ]
