#!/usr/bin/env bash
# check-causal-provenance.sh — мягкий замок ADR-0046: «почему» в записи — только с пометкой источника.
#
# Смотрит ДОБАВЛЕННЫЕ строки staged-изменений (или одного коммита — `--rev <коммит>`) в файлах,
# подходящих под шаблоны путей, ищет причинные слова («потому что», «из-за», «посчитав»…) и, если
# в той же строке и в соседних (±1) нет пометки, откуда причина взялась («сверено», «по словам»,
# «гипотеза»…), печатает предупреждение. Коммит НЕ блокирует: код выхода всегда 0.
#
# Почему не блок: язык живой, ложных срабатываний будет много, а блок научит обходить замок
# (building-enforcement.md, правило 4). Предупреждение — повод перечитать фразу, не приговор.
#
# Почему окно ±1 строка, а не вся фраза: исторический дефект 15.10.2026 («…выше, посчитав по
# копии 14.10…») стоял во фразе, которая двумя строками ниже кончалась «проект поправку
# подтвердил» — про ДРУГОЕ утверждение. По всей фразе замок счёл бы её подтверждённой.
#
# Запуск из хука репозитория (корень — текущий репозиторий):
#   bash <мозг>/scripts/check-causal-provenance.sh [--rev <коммит>] [шаблон пути…]
# Шаблоны по умолчанию: 'inventory/*.md' 'incidents/*.md' (git pathspec, `*` идёт и через `/`).
# CAUSAL_LINT_PYTHON — явный интерпретатор (для теста «python сломан»).
#
# ГРАНИЦА (что замок НЕ проверяет): верна ли сама причина; относится ли найденная рядом пометка
# к этому утверждению; причины без слов-маркеров («ждал X, а пришло Y» без «потому что»);
# текст вне шаблонов путей. Это сито для одного класса ошибки, не проверка истинности.

set -u

PY="${CAUSAL_LINT_PYTHON:-}"
if [ -z "$PY" ]; then
  for c in python3 python; do
    if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
  done
fi
# Правило 3д: интерпретатор может быть, но быть сломан (заглушка Microsoft Store) — сверяем по
# выводу, а не по `command -v`.
if [ -z "$PY" ] || [ "$("$PY" -c 'print("ok")' 2>/dev/null)" != "ok" ]; then
  echo "⚠️  проверка причин без источника (ADR-0046) не выполнена: нет рабочего python. Коммит не остановлен." >&2
  exit 0
fi

"$PY" -I - "$@" <<'PY'
import re, subprocess, sys

for s in (sys.stdout, sys.stderr):
    try:
        s.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

args = sys.argv[1:]
rev = None
if len(args) >= 2 and args[0] == "--rev":
    rev, args = args[1], args[2:]
paths = args or ["inventory/*.md", "incidents/*.md"]

# Причинные слова — канон замка. Тест проверяет, что список не выродился (ассерт на текст правила).
CAUSAL = [
    r"потому\s+что", r"оттого\s+что", r"так\s+как", r"т\.\s?к\.", r"из-за", r"поскольку",
    # «вызван» — только «вызвано тем»: голое «вызван агентом» значит «запущен» (ложное
    # срабатывание на первом же живом прогоне, 16.10.2026).
    r"по\s+причине", r"\bпричин[аыуеой]", r"\bвызван[аоы]?\s+тем\b", r"посчитав", r"решив,",
    r"\bиз\s+чего\s+следует",
]
# Пометки источника — откуда взялась причина.
PROVENANCE = [
    r"сверено", r"сверил", r"по\s+словам", r"со\s+слов", r"гипотез", r"предполож",
    r"подтвержд", r"подтвердил", r"по\s+коду", r"по\s+исходник", r"по\s+журналу",
    r"по\s+выводу", r"из\s+чтения\s+кода", r"не\s+проверял", r"не\s+проверен",
    r"живь[её]м\s+не", r"чем\s+подтверждено", r"источник", r"\bHIGH\b", r"\bMEDIUM\b",
    r"\bLOW\b",
    # Честное «не знаю» — тоже пометка: «причина не установлена» (ложное срабатывание на
    # живом прогоне по истории infra, 16.10.2026).
    r"не\s+установлен", r"неизвестн",
]
cre = re.compile("|".join(CAUSAL), re.I)
pre = re.compile("|".join(PROVENANCE), re.I)

def norm(s):  # ё→е, неразрывный и прочие дефисы → обычный
    return s.replace("ё", "е").replace("Ё", "Е").translate({0x2011: "-", 0x2010: "-", 0x2012: "-"})

cmd = (["git", "show", "--format=", "--no-color", "-U1", rev, "--"] if rev
       else ["git", "diff", "--cached", "--no-color", "-U1", "--"]) + paths
try:
    out = subprocess.run(cmd, capture_output=True, check=True).stdout.decode("utf-8", "replace")
except Exception as e:
    print(f"⚠️  проверка причин без источника (ADR-0046) не выполнена: {e}. Коммит не остановлен.",
          file=sys.stderr)
    sys.exit(0)

hunks, cur, fname, n = [], None, None, 0
for line in out.splitlines():
    if line.startswith("+++ "):
        fname = line[6:] if line.startswith("+++ b/") else None
        continue
    if line.startswith("--- ") or line.startswith("diff ") or line.startswith("index "):
        continue
    m = re.match(r"@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@", line)
    if m:
        cur = []; hunks.append((fname, cur)); n = int(m.group(1)); continue
    if cur is None or fname is None:
        continue
    if line.startswith("+"):
        cur.append((n, True, norm(line[1:]))); n += 1
    elif line.startswith(" "):
        cur.append((n, False, norm(line[1:]))); n += 1
    # строки «-» в новом файле места не занимают

found = []
for fname, rows in hunks:
    for i, (num, added, text) in enumerate(rows):
        if not added or not cre.search(text):
            continue
        window = [rows[j][2] for j in (i - 1, i, i + 1) if 0 <= j < len(rows)]
        if not any(pre.search(w) for w in window):
            found.append(f"  {fname}:{num}: {text.strip()[:160]}")

if found:
    print("⚠️  Причина без пометки источника (ADR-0046) — перечитай, откуда она:", file=sys.stderr)
    print("\n".join(found), file=sys.stderr)
    print("   Впиши «(сверено: код/конфиг/вывод)», «(по словам <кого>, <когда>)» или «(гипотеза)».",
          file=sys.stderr)
    print("   Это предупреждение — коммит НЕ остановлен.", file=sys.stderr)
sys.exit(0)
PY
exit 0
