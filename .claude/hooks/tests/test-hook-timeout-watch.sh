#!/usr/bin/env bash
# Тесты еженедельного поиска прерванных хуков (ADR-0044).
# Прогон: bash .claude/hooks/tests/test-hook-timeout-watch.sh
#
# Подопечный параметризован (CHECKER=<скрипт>), чтобы тест можно было прогнать на испорченной
# версии, а не только на исправной (персона §3.11; свод замков, правила 3г и 3д).
# Формат события — как в настоящем транскрипте Claude Code (26.09.2026): запись с
# attachment.type == "hook_cancelled", hookName, timedOut, timeoutMs и timestamp в ISO.
set -uo pipefail
export PYTHONIOENCODING=utf-8

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
CHECKER="${CHECKER:-$REPO/.claude/hooks/hook-timeout-watch.sh}"
SETTINGS="${SETTINGS:-$REPO/.claude/settings.json}"
PASS=0; FAIL=0; OUT=""; RC=0

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# Путь с пробелом и кириллицей — как реальные пути операторов (свод замков, чек-лист).
W="$TMP/мозг с пробелом"; mkdir -p "$W/brain" "$W/projects"

ok()  { PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$1"; }

iso() { python3 -c 'import datetime,sys;print(datetime.datetime.fromtimestamp(int(sys.argv[1]),datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"))' "$1"; }
NOW="$(date -u +%s)"

# event <файл> <секунд назад> <hookName> — дописывает событие прерывания в транскрипт.
event() {
    python3 - "$1" "$(iso $(( NOW - $2 )))" "$3" <<'PY'
import json, sys
with open(sys.argv[1], "a", encoding="utf-8") as f:
    f.write(json.dumps({"type": "attachment", "timestamp": sys.argv[2], "isSidechain": False,
        "attachment": {"type": "hook_cancelled", "hookName": sys.argv[3], "toolUseID": "toolu_x",
                       "hookEvent": sys.argv[3].split(":")[0], "command": "Проверяю зону операции…",
                       "durationMs": 56125, "timedOut": True, "timeoutMs": 15000}},
        ensure_ascii=False) + "\n")
PY
}
noise() { # обычные строки транскрипта, в том числе упоминание слова в тексте реплики
    # и событие другого типа, где слово стоит значением поля (в кавычках, как в JSON):
    # его отсекает только проверка attachment.type, а не дешёвый фильтр подстроки.
    python3 - "$1" "$(iso "$NOW")" <<'PY'
import json, sys
with open(sys.argv[1], "a", encoding="utf-8") as f:
    f.write(json.dumps({"type": "attachment", "timestamp": sys.argv[2],
        "attachment": {"type": "hook_success", "hookName": "PreToolUse:Bash", "note": "hook_cancelled"}},
        ensure_ascii=False) + "\n")
PY
    printf '%s\n' '{"type":"user","timestamp":"'"$(iso $NOW)"'","message":{"role":"user","content":"почини"}}' \
                  '{"type":"assistant","timestamp":"'"$(iso $NOW)"'","message":{"role":"assistant","content":[{"type":"text","text":"в журнале было hook_cancelled — разберу"}]}}' >> "$1"
}

call() { OUT="$(bash "$CHECKER" --root "$W/brain" --projects "$W/projects" "$@" </dev/null 2>/dev/null)"; RC=$?; }

echo "── Тесты еженедельного поиска прерванных хуков ─────────"

echo "[1] Находит прерывания за неделю и не считает лишнего"
mkdir -p "$W/projects/proj-a" "$W/projects/proj b"
A="$W/projects/proj-a/s1.jsonl"; B="$W/projects/proj b/s2.jsonl"; OLD="$W/projects/proj-a/old.jsonl"
noise "$A"; event "$A" 3600 "PreToolUse:Bash"; event "$A" 7200 "PreToolUse:Bash"; event "$A" $((9*86400)) "PreToolUse:Bash"
noise "$B"; event "$B" 600 "Stop"
# Файл не менялся 10 дней — не читаем. Старим через python3, а не `touch -d '10 days ago'`:
# такая запись есть только в GNU touch, BSD touch на macOS её не понимает, файл оставался
# свежим, и тест краснел (найдено при вливании PR #22, 2026-11-24). python3 тест и так требует.
event "$OLD" 100 "PreToolUse:Bash"
python3 -c 'import os,sys,time; t=time.time()-10*86400; os.utime(sys.argv[1],(t,t))' "$OLD"
call
if [ "$RC" -eq 0 ] && grep -q 'по таймауту 3 раза' <<<"$OUT"; then ok "3 события в окне (событие 9-дневной давности и старый файл не в счёт)"
else bad "ждали «3 раза», код $RC: ${OUT:0:200}"; fi
if grep -q 'PreToolUse:Bash ×2' <<<"$OUT" && grep -q 'Stop ×1' <<<"$OUT"; then ok "разбивка по хукам"
else bad "нет разбивки по хукам: ${OUT:0:200}"; fi
if grep -q 'proj b ×1' <<<"$OUT"; then ok "проект с пробелом в имени назван"
else bad "проект с пробелом не назван"; fi
if grep -q 'hook_cancelled — разберу' <<<"$(cat "$A")" && ! grep -q 'по таймауту 4' <<<"$OUT"; then ok "слово hook_cancelled в тексте реплики событием не считается"
else bad "упоминание в тексте посчитано событием"; fi

echo "[2] Недельный лимит и метка"
if [ -f "$W/brain/.hook-timeout-check" ]; then ok "метка записана"; else bad "метки нет"; fi
call
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "повторный старт в ту же неделю — молча"
else bad "повторный старт не молчит: ${OUT:0:120}"; fi
call --force
if grep -q 'по таймауту' <<<"$OUT"; then ok "--force проверяет без лимита"; else bad "--force молчит"; fi
printf '%s\n' $(( NOW - 8*86400 )) > "$W/brain/.hook-timeout-check"; event "$A" 60 "PreToolUse:Bash"
call
if grep -q 'по таймауту 4 раза' <<<"$OUT"; then ok "неделя прошла — считает всё после прошлой проверки (4 раза)"
else bad "после недели ждали «4 раза»: ${OUT:0:200}"; fi

echo "[3] Прерываний нет — всё равно одна строка (молчание не значит порядок)"
E="$TMP/empty"; mkdir -p "$E/p/x"; noise "$E/p/x/s.jsonl"
OUT="$(bash "$CHECKER" --root "$E" --projects "$E/p" </dev/null 2>/dev/null)"; RC=$?
if [ "$RC" -eq 0 ] && grep -q 'ни разу не прерывались' <<<"$OUT"; then ok "итог «ни разу» напечатан"
else bad "при нуле событий хук молчит или сбоит: код $RC, ${OUT:-пусто}"; fi

echo "[4] Не смог проверить — говорит об этом"
OUT="$(env HOOK_WATCH_BUDGET=0 bash "$CHECKER" --root "$W/brain" --projects "$W/projects" --force </dev/null 2>/dev/null)"; RC=$?
if [ "$RC" -eq 0 ] && grep -q 'не выполнена' <<<"$OUT"; then ok "бюджет исчерпан — «проверка не выполнена», а не молчание"
else bad "при исчерпанном бюджете: код $RC, ${OUT:-пусто}"; fi
OUT="$(bash "$CHECKER" --root "$W/brain" --projects "$TMP/no-such-dir" --force </dev/null 2>/dev/null)"; RC=$?
if [ "$RC" -eq 0 ] && grep -q 'не выполнена' <<<"$OUT"; then ok "нет каталога транскриптов — «не выполнена»"
else bad "без каталога транскриптов: код $RC, ${OUT:-пусто}"; fi
CODE="$(grep -v '^[[:space:]]*#' "$CHECKER")"
if grep -qF 'HOOK_WATCH_BUDGET" -lt "$BUDGET"' <<<"$CODE"; then ok "переменная окружения может бюджет только уменьшить"
else bad "не нашёл ограничения «только уменьшить» для HOOK_WATCH_BUDGET"; fi

echo "[5] Подключение и время (ADR-0043)"
ENGINE_TO="$(python3 - "$SETTINGS" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for m in d.get("hooks", {}).get("SessionStart", []):
    for h in m.get("hooks", []):
        if "hook-timeout-watch.sh" in h.get("command", ""):
            print(h.get("timeout", 60))
PY
)"
BUDGET="$(grep -Eo '^BUDGET=[0-9]+' "$CHECKER" | cut -d= -f2)"
if [ -z "$ENGINE_TO" ]; then bad "хук не подключён в settings.json (SessionStart)"
elif [ -z "$BUDGET" ]; then bad "в хуке нет своего бюджета BUDGET="
elif [ "$ENGINE_TO" -gt $((BUDGET + 3)) ]; then ok "подключён; бюджет ${BUDGET} с с запасом меньше таймаута движка ${ENGINE_TO} с"
else bad "бюджет ${BUDGET} с не оставляет запаса до таймаута ${ENGINE_TO} с"; fi
# Вызов так, как его делает движок: команда из settings, вход — JSON события.
CMD="$(python3 - "$SETTINGS" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for m in d.get("hooks", {}).get("SessionStart", []):
    for h in m.get("hooks", []):
        if "hook-timeout-watch.sh" in h.get("command", ""):
            print(h["command"])
PY
)"
if [ -n "$CMD" ]; then
    P="$TMP/proj-root"; mkdir -p "$P/.claude/hooks"; cp "$CHECKER" "$P/.claude/hooks/hook-timeout-watch.sh"
    OUT="$(printf '{"hook_event_name":"SessionStart","source":"startup"}' \
           | HOME="$TMP/home-empty" CLAUDE_PROJECT_DIR="$P" bash -c "$CMD" 2>/dev/null)"; RC=$?
    if [ "$RC" -eq 0 ] && grep -q '^\[hook-timeout-watch\]' <<<"$OUT"; then ok "команда из settings со входом движка отрабатывает и помечает источник"
    else bad "команда из settings: код $RC, ${OUT:-пусто}"; fi
fi

echo "[6] Бюджет от старта хука; сломанный python3 — строка «не выполнена», а не тишина (ADR-0044, дополнение 2026-10-06)"
# Дефект: бюджет считала python-часть от СВОЕГО старта, а запуск python3 (на Windows — часто
# заглушка Microsoft Store, под нагрузкой десятки секунд) не считал никто; сломанный python3
# давал тишину, и раз метка уже записана — сводка молча пропадала на неделю. Подставные
# программы — только в PATH хука (правило 3д). Время — по захвату stdout И stderr.
now_ms() {   # часы без процессов и без GNU date (`date +%s%N` на macOS печатает N)
    if [ -n "${EPOCHREALTIME:-}" ]; then local t="${EPOCHREALTIME/[.,]/}"; NOW_MS=$(( 10#$t / 1000 ))
    else NOW_MS=$(( SECONDS * 1000 )); fi
}
MEDL="$TMP/medlennyj"; SLOM="$TMP/slomannyj"; mkdir -p "$MEDL" "$SLOM"
printf '#!/usr/bin/env bash\nsleep 8\nexit 1\n' > "$MEDL/python3"
printf '#!/usr/bin/env bash\necho "Python was not found; run without arguments to install from the Microsoft Store" >&2\nexit 9009\n' > "$SLOM/python3"
chmod +x "$MEDL/python3" "$SLOM/python3"
case6() { # $1 = описание, $2 = каталог подставных, $3 = бюджет, $4 = предел мс, $5 = ждём (строку|тишину), далее — аргументы хука
    local desc="$1" dir="$2" budget="$3" lim="$4" want="$5" s ms out; shift 5
    now_ms; s=$NOW_MS
    out="$(env PATH="$dir:$PATH" HOOK_WATCH_BUDGET="$budget" bash "$CHECKER" --root "$W/brain" --projects "$W/projects" "$@" </dev/null 2>&1)"
    now_ms; ms=$(( NOW_MS - s ))
    if [ "$ms" -ge "$lim" ]; then bad "${desc} — ${ms} мс, дольше ${lim} мс"
    elif [ "$want" = "тишину" ] && [ -z "$out" ]; then ok "${desc} — молча, ${ms} мс"
    elif [ "$want" != "тишину" ] && grep -q 'не выполнена' <<<"$out" && grep -q "$want" <<<"$out"; then ok "${desc} — «не выполнена», ${ms} мс"
    else bad "${desc} — ждали ${want}, получили: ${out:-тишину}"; fi
}
case6 "медленный python3"                        "$MEDL" 2 4000 "не уложилась" --force
case6 "сломанный python3"                        "$SLOM" "" 4000 "python3" --force
printf '%s\n' "$NOW" > "$W/brain/.hook-timeout-check"
case6 "неделя не прошла — python3 не запускается" "$MEDL" 2 1500 "тишину"
# Переносимость сторожа (правило 3г: поведение bash 3.2 здесь не воспроизвести — по тексту).
STRAZH="$(sed -n '/^# ── Сторож времени/,$p' "$CHECKER" | grep -v '^[[:space:]]*#')"
if [ -z "$STRAZH" ]; then bad "сторож времени не найден по маркеру — проверять нечего"
elif grep -Eq '=\$!([^:]|$)' <<<"$STRAZH" || grep -Eq '\$\?[[:space:]]*>[[:space:]]*128' <<<"$STRAZH" \
     || ! grep -q 'KONETS_PROVERKI' <<<"$STRAZH"; then bad "сторож опирается на \$! или код read — на bash 3.2 сломается"
else ok "сторож переносим: \${!:-} и метка конца"; fi

echo "[Вывод] Читаемо при любой локали"
OUT="$(env LC_ALL=C LANG=C bash "$CHECKER" --root "$W/brain" --projects "$W/projects" --force </dev/null 2>/dev/null)"; RC=$?
if [ "$RC" -eq 0 ] && grep -q 'Сообщи оператору' <<<"$OUT"; then ok "при LC_ALL=C текст доходит целиком"
else bad "при LC_ALL=C текст пустой или искажён"; fi

echo "─────────────────────────────────────────────────────────"
printf 'Итог: %d прошло, %d провалено\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
