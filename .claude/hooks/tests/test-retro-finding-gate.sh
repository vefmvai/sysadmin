#!/usr/bin/env bash
# Тесты гейта находок /retro (ADR-0021). Прогон: bash .claude/hooks/tests/test-retro-finding-gate.sh
set -uo pipefail

# Обвязка теста тоже печатает русский текст через python: на чужой кодовой странице
# (Windows cp1252) она падает и подаёт хуку пустой вход — тест «проваливается» там,
# где замок исправен. Правило 3д свода замков.
export PYTHONIOENCODING=utf-8
# RETRO_GATE_HOOK — другая версия гейта (например, историческая из git): так тест
# проверяется на дефекте, который должен ловить (персона §3.11).
HOOK="${RETRO_GATE_HOOK:-$(cd "$(dirname "$0")/.." && pwd)/retro-finding-gate.sh}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

run() { # $1 = file_path, $2 = текст правки, $3 = поле (new_string|content)
  python3 - "$1" "$2" "${3:-new_string}" <<'PY' | env PYTHONIOENCODING="${HOOK_ENC:-utf-8}" RETRO_GATE_BUDGET="${GATE_BUDGET_ENV:-}" PATH="${HOOK_PATH:-$PATH}" bash "$HOOK"
import json, sys
print(json.dumps({"tool_name": "Edit", "tool_input": {"file_path": sys.argv[1], sys.argv[3]: sys.argv[2]}}, ensure_ascii=False))
PY
}

check() { # $1 = allow|deny, $2 = описание, $3 = path, $4 = текст, $5 = поле
  local out; out="$(run "$3" "$4" "${5:-new_string}")"
  local got="allow"; printf '%s' "$out" | grep -q '"permissionDecision": *"deny"' && got="deny"
  if [ "$got" = "$1" ]; then PASS=$((PASS+1)); printf '  ✅ %s\n' "$2"
  else FAIL=$((FAIL+1)); printf '  ❌ %s — ожидали %s, получили %s\n' "$2" "$1" "$got"; fi
}

B="/repo/retro/BACKLOG.md"
OK_FACT='| 2026-07-24 | MUST | скиллы | факт | скилл выдал ложный drift | чинить парсер | open |'
OK_HYPO='| 2026-07-24 | MAY | персона | гипотеза | возможно, рефлекс не сработал | проверить на след. сессии | open |'
NO_BASIS='| 2026-07-24 | MUST | скиллы | агент сломал оператору рабочий VPN | откатить | open |'
HISTORIC='| 2026-06-14 | MUST | скиллы | старая находка без основания | предложение | done (fix abc123) |'
HEADER='| Дата | Severity | Фронт | Основание | Находка | Предложение | Статус |
|------|----------|-------|----------|---------|-------------|--------|'

echo "── Тесты гейта находок /retro ───────────────────────────"
echo "[1] Посторонние файлы гейт не трогает"
check allow "правка README"            "/repo/README.md"        "$NO_BASIS"
check allow "заметки, не бэклог"       "/repo/docs/NOTES.md"    "$NO_BASIS"
# Ожидание изменено осознанно (F5, 2026-07-24): раньше гейт стоял только на
# `retro/BACKLOG.md`, теперь — на любом бэклоге находок, потому что саморазбор
# переехал в `_retro/`. Кейс `/repo/docs/BACKLOG.md` переехал в секцию [5].

echo "[2] Корректные находки проходят"
check allow "основание «факт»"         "$B" "$OK_FACT"
check allow "основание «гипотеза»"     "$B" "$OK_HYPO"
check allow "шапка и разделитель"      "$B" "$HEADER"
check allow "историческая строка done" "$B" "$HISTORIC"
check allow "обычный текст без таблиц" "$B" "## Раздел про находки, open вопросы"

echo "[3] Находка без основания блокируется"
check deny  "нет ни факта, ни гипотезы" "$B" "$NO_BASIS"
check deny  "среди корректных затесалась плохая" "$B" "$OK_FACT
$NO_BASIS"
check deny  "полная перезапись файла (content)"  "$B" "$HEADER
$NO_BASIS" content

echo "[4] Относительный путь тоже под гейтом"
check deny  "retro/BACKLOG.md без префикса" "retro/BACKLOG.md" "$NO_BASIS"

echo "[5] Гейт следует за находками, а не за каталогом (F5, разбор 2026-07-24)"
check deny  "_retro/BACKLOG.md (глобальный /lore-retro)" "/repo/_retro/BACKLOG.md" "$NO_BASIS"
check deny  "любой иной бэклог находок"                  "/repo/docs/notes/BACKLOG.md" "$NO_BASIS"
check allow "сырой отчёт аудитора не гейтим"             "/repo/_retro/REVIEW-2026-07-24-1c176a94.md" "$NO_BASIS"
check allow "дайджест стенограммы не гейтим"             "/repo/_retro/_digest.md" "$NO_BASIS"

echo "[Кодировка] Вердикт доходит и при чужой кодовой странице консоли (правило 3д)"
# Дефект 26.08.2026: гейт печатал ответ через python, а консоль на Windows в cp1252 —
# python падал на первом же русском символе, хук не печатал НИЧЕГО и выходил с кодом 0.
# Движок читает это как «возражений нет»: 6 случаев из 6 проходили как разрешённые.
# Лечится строкой `export PYTHONIOENCODING=utf-8` в шапке ХУКА, но проверять её надо
# отдельным случаем: своим таким же export (шапка этого файла) тест лечит хук ЗА НЕГО —
# переменная наследуется дочернему процессу, и убери её из хука, итог останется зелёным.
# Здесь кодировка навязывается ИМЕННО ХУКУ, перекрывая наследство.
HOOK_ENC=cp1252
check deny  "отказ доходит при cp1252-консоли" "$B" "$NO_BASIS"
check allow "находка с основанием проходит"    "$B" "$OK_FACT"
ENC_OUT="$(run "$B" "$NO_BASIS" 2>/dev/null)"
if printf '%s' "$ENC_OUT" | grep -q 'основани'; then
  PASS=$((PASS+1)); echo "  ✅ русский текст причины не искажён"
else
  FAIL=$((FAIL+1)); echo "  ❌ причина при cp1252 пуста или искажена"
fi
unset HOOK_ENC

echo "[6] Время: у гейта нет цикла по данным (ADR-0043, правило 3ж)"
# Гейт порождает постоянное число процессов, и время не растёт с объёмом записи (замер
# 26.09.2026 на Windows: 0,5 с на обычном файле, 1,7 с на записи в 2000 строк бэклога при
# таймауте 15 с). С 06.10.2026 у него есть и бюджет — от медленного запуска python3, а не от
# объёма (секция [7]); отсутствие цикла в оболочке по-прежнему держит время постоянным.
G_CODE="$(grep -v '^[[:space:]]*#' "$HOOK")"
if [ -z "$G_CODE" ]; then
  FAIL=$((FAIL+1)); echo "  ❌ текст гейта не прочитан — проверять нечего"
elif grep -Eq '(^|[[:space:];])do([[:space:]]|$)' <<<"$G_CODE"; then   # у любого цикла оболочки есть do; у python и этой awk-программы — нет
  FAIL=$((FAIL+1)); echo "  ❌ в гейте появился цикл оболочки — нужен свой бюджет времени (правило 3ж)"
else
  PASS=$((PASS+1)); echo "  ✅ циклов оболочки нет — число процессов не зависит от объёма записи"
fi

echo "[7] Бюджет покрывает весь гейт; сломанный python3 не делает его немым (ADR-0044, дополнение 2026-10-06)"
# Дефекты: (1) своего бюджета не было вовсе, а запуск python3 (на Windows — часто заглушка
# Microsoft Store) под нагрузкой тянется десятки секунд — 03.10.2026 замок красной зоны так
# шёл 36,5 с при таймауте 15 с, и движок выполнил вызов без вердикта; (2) отказ печатался
# через python3, и при python3, который есть, но сразу падает, гейт молчал — «разрешаю».
# Подставные программы — только в PATH гейта (правило 3д). Время — по захвату stdout И stderr.
now_ms() {   # часы без процессов и без GNU date (`date +%s%N` на macOS печатает N)
  if [ -n "${EPOCHREALTIME:-}" ]; then local t="${EPOCHREALTIME/[.,]/}"; NOW_MS=$(( 10#$t / 1000 ))
  else NOW_MS=$(( SECONDS * 1000 )); fi
}
MEDL="$TMP/medlennyj"; SLOM="$TMP/slomannyj"; SLOM2="$TMP/slomany-oba"; mkdir -p "$MEDL" "$SLOM" "$SLOM2"
printf '#!/usr/bin/env bash\nsleep 6\nexit 1\n' > "$MEDL/python3"
printf '#!/usr/bin/env bash\necho "Python was not found; run without arguments to install from the Microsoft Store" >&2\nexit 9009\n' > "$SLOM/python3"
cp "$SLOM/python3" "$SLOM2/python3"; printf '#!/usr/bin/env bash\nexit 127\n' > "$SLOM2/jq"
chmod +x "$MEDL/python3" "$SLOM/python3" "$SLOM2/python3" "$SLOM2/jq"
case7() { # $1 = ожидание, $2 = описание, $3 = каталог подставных, $4 = бюджет, $5 = путь, $6 = текст, $7 = предел мс, $8 = слово
  now_ms; local s=$NOW_MS out got ms
  out="$(HOOK_PATH="$3:$PATH" GATE_BUDGET_ENV="$4" run "$5" "$6" 2>&1)"
  now_ms; ms=$(( NOW_MS - s ))
  got="allow"; printf '%s' "$out" | grep -q '"permissionDecision": *"deny"' && got="deny"
  if [ "$got" = "$1" ] && [ "$ms" -lt "$7" ] && { [ -z "${8:-}" ] || printf '%s' "$out" | grep -q "$8"; }; then
    PASS=$((PASS+1)); printf '  ✅ %s — %s, %s мс\n' "$2" "$got" "$ms"
  else
    FAIL=$((FAIL+1)); printf '  ❌ %s — ожидали %s быстрее %s мс, получили %s за %s мс\n' "$2" "$1" "$7" "$got" "$ms"
  fi
}
case7 deny  "медленный python3, бэклог без основания — «не успел»"   "$MEDL" 2 "$B" "$NO_BASIS" 4000 "НЕ УСПЕЛ"
case7 deny  "медленный python3, бэклог с основанием — проверить не успел" "$MEDL" 2 "$B" "$OK_FACT" 4000 "НЕ УСПЕЛ"
case7 allow "медленный python3, правка README — мимо гейта без python" "$MEDL" 2 "/repo/README.md" "$NO_BASIS" 1500
case7 allow "медленный python3, README упоминает BACKLOG.md — пропуск" "$MEDL" 2 "/repo/README.md" "см. retro/BACKLOG.md" 4000
case7 deny  "сломан python3 (jq цел), бэклог без основания — отказ"   "$SLOM" "" "$B" "$NO_BASIS" 4000 "ГЕЙТ"
case7 allow "сломан python3 (jq цел), бэклог с основанием — пропуск"  "$SLOM" "" "$B" "$OK_FACT" 4000
# Подробная причина («не смог разобрать») печатается через python, а он сломан — доходит
# запасной отказ; важно, что отказ, и что он называет причину — сломанный python3.
case7 deny  "сломаны python3 и jq, бэклог — проверить нечем, отказ"   "$SLOM2" "" "$B" "$OK_FACT" 4000 "сломан"
case7 allow "сломаны python3 и jq, правка README — пропуск"           "$SLOM2" "" "/repo/README.md" "$NO_BASIS" 4000
# Переносимость сторожа (правило 3г: поведение bash 3.2 здесь не воспроизвести — по тексту).
STRAZH="$(sed -n '/^# ── Сторож времени/,$p' "$HOOK" | grep -v '^[[:space:]]*#')"
if [ -z "$STRAZH" ]; then FAIL=$((FAIL+1)); echo "  ❌ сторож времени не найден по маркеру — проверять нечего"
elif grep -Eq '=\$!([^:]|$)' <<<"$STRAZH" || grep -Eq '\$\?[[:space:]]*>[[:space:]]*128' <<<"$STRAZH" \
     || ! grep -q 'KONETS_PROVERKI' <<<"$STRAZH"; then
  FAIL=$((FAIL+1)); echo "  ❌ сторож опирается на \$! или код read — на bash 3.2 сломается"
else PASS=$((PASS+1)); echo "  ✅ сторож переносим: \${!:-} и метка конца"; fi

echo "─────────────────────────────────────────────────────────"
printf 'Итог: %d прошло, %d провалено\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
