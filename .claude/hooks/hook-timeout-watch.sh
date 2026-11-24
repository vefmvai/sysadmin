#!/usr/bin/env bash
# .claude/hooks/hook-timeout-watch.sh — SessionStart-хук: раз в неделю ищет в транскриптах
# этой машины хуки, прерванные движком по таймауту (ADR-0044).
#
# ЗАЧЕМ. Хук, не уложившийся в таймаут, движок прерывает и продолжает без него: для
# PreToolUse это «разрешаю» (документация: «не рассчитывайте на зависший хук как на
# затвор»), для Stop — «проверено». Снаружи прерванный замок неотличим от исправного.
# 18–26.09.2026 замок красной зоны на Windows прерывался 99 раз, и восемь дней этого никто
# не видел — нашлось случайно (ADR-0043). Хук делает прерывания видимыми.
#
# ПОВЕДЕНИЕ:
#   с прошлой проверки меньше 7 суток   → молча выходим
#   проверка прошла                     → ОДНА строка итога ВСЕГДА, в том числе «прерываний
#                                          нет»: молчание не должно означать порядок
#                                          (решение оператора 26.09.2026)
#   проверить не удалось                → строка «проверка не выполнена» с причиной — в том
#                                          числе python3 сломан или не уложился в бюджет
# Вывод SessionStart с кодом 0 движок кладёт в контекст; агент передаёт итог оператору.
#
# ВРЕМЯ (ADR-0044, дополнение 2026-10-06). Бюджет — от старта хука, не от старта python:
# раньше `cat`, `date`, `tr` и запуск python3 (на Windows — заглушка Microsoft Store, под
# нагрузкой десятки секунд) не считал никто, а сломанный python3 давал тишину — и раз метка
# уже записана, сводка молча пропадала на неделю. Теперь «пора ли проверять» решается
# встроенными средствами (в неделю, когда не пора, python3 не запускается вовсе), а сама
# проверка идёт в фоне под сторожем времени в конце файла.
#
# Где ищем: ~/.claude/projects/*/*.jsonl — только файлы, изменённые после прошлой проверки
# (первый раз — за 7 суток); событие — `attachment.type == "hook_cancelled"`.
# Метка — `.hook-timeout-check` в корне мозга (в .gitignore), секунды эпохи. Пишется ДО
# поиска: неудачная проверка повторится через неделю, а не на каждом старте.
#
# Флаги (для ручного запуска и тестов):
#   --root DIR      корень мозга (метка); по умолчанию — два уровня над этим файлом;
#   --projects DIR  где искать транскрипты; по умолчанию ~/.claude/projects;
#   --force         без недельного лимита, метку не трогает.
#
# Ручная проверка: bash .claude/hooks/tests/test-hook-timeout-watch.sh

set -u
export PYTHONIOENCODING=utf-8

ROOT=""; PROJECTS=""; FORCE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --root)     ROOT="${2:-}"; shift 2 2>/dev/null || shift ;;
        --projects) PROJECTS="${2:-}"; shift 2 2>/dev/null || shift ;;
        --force)    FORCE=1; shift ;;
        *)          shift ;;
    esac
done

# Вход движка не нужен, но канал дочитываем (как в brain-update-check.sh) — встроенным
# read, не `cat`: до сторожа времени процессов не порождаем.
if [ -p /dev/stdin ]; then IFS= read -r -d '' _ || true; fi

TAG="[hook-timeout-watch]"
say_failed() {
    printf '%s Еженедельная проверка прерываний хуков не выполнена: %s.\n' "$TAG" "$1"
    printf 'Сообщи оператору одной строкой в начале первого ответа. Повтор — через неделю или вручную: bash .claude/hooks/hook-timeout-watch.sh --force\n'
    exit 0
}

# Корень мозга — встроенными средствами (`cd` в самом хуке, без `dirname` и подоболочки).
if [ -z "$ROOT" ]; then
    case "$0" in */*) d="${0%/*}" ;; *) d=. ;; esac
    cd "$d/../.." 2>/dev/null && ROOT="$PWD" || exit 0
fi
[ -n "$PROJECTS" ] || PROJECTS="$HOME/.claude/projects"

PERIOD=604800                                  # 7 суток
# Сейчас, в секундах эпохи: bash 5 — $EPOCHSECONDS, 4.2+ — printf %()T; только на bash 3.2
# (системный на macOS) остаётся `date`.
if [ -n "${EPOCHSECONDS:-}" ]; then NOW="$EPOCHSECONDS"
elif printf -v NOW '%(%s)T' -1 2>/dev/null && [[ $NOW =~ ^[0-9]+$ ]]; then :
else NOW="$(date -u +%s)"; fi
SINCE=$((NOW - PERIOD))
if [ "$FORCE" -eq 0 ]; then
    MARK="$ROOT/.hook-timeout-check"
    LAST=""
    if [ -f "$MARK" ]; then
        { IFS= read -r LAST < "$MARK" || true; } 2>/dev/null
        LAST="${LAST//[[:space:]]/}"
    fi
    case "$LAST" in
        ''|*[!0-9]*) ;;
        *)
            if [ "$LAST" -le "$NOW" ] 2>/dev/null && [ $((NOW - LAST)) -lt "$PERIOD" ] 2>/dev/null; then
                exit 0
            fi
            SINCE="$LAST"                      # всё, что случилось после прошлой проверки
            ;;
    esac
    printf '%s\n' "$NOW" > "$MARK" 2>/dev/null || true
fi

command -v python3 >/dev/null 2>&1 || say_failed "нет python3"
[ -d "$PROJECTS" ] || say_failed "нет каталога транскриптов $PROJECTS"

# Бюджет (ADR-0043, правило 3ж): таймаут этого хука в settings.json — 20 с. Весь разбор —
# один процесс python, без процессов на каждый файл; не уложился — честное «не выполнена».
# Переменная окружения может бюджет только уменьшить — для теста этой ветки.
BUDGET=10
if [[ "${HOOK_WATCH_BUDGET:-}" =~ ^[0-9]+$ ]] && [ "$HOOK_WATCH_BUDGET" -lt "$BUDGET" ]; then
    BUDGET="$HOOK_WATCH_BUDGET"
fi

# ── ПРОВЕРКА: python-часть, исполняется в фоне под сторожем времени (конец файла) ──
# В функции, а не прямо внутри `<( )`: bash 3.2 разбирает heredoc внутри `<( )` по скобкам.
proverit() {
python3 - "$PROJECTS" "$SINCE" "$NOW" "$BUDGET" "$TAG" <<'PY'
import collections, datetime, io, json, os, sys, time

projects, since, now, budget, tag = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
t0 = time.monotonic()

def failed(reason):
    print(f"{tag} Еженедельная проверка прерываний хуков не выполнена: {reason}.")
    print("Сообщи оператору одной строкой в начале первого ответа. Повтор — через неделю или "
          "вручную: bash .claude/hooks/hook-timeout-watch.sh --force")
    sys.exit(0)

def ts_epoch(s):
    try:
        return int(datetime.datetime.strptime(s[:19], "%Y-%m-%dT%H:%M:%S")
                   .replace(tzinfo=datetime.timezone.utc).timestamp())
    except Exception:
        return None

by_hook, by_proj, total = collections.Counter(), collections.Counter(), 0
try:
    dirs = [e for e in os.scandir(projects) if e.is_dir()]
except OSError as e:
    failed(f"не читается каталог транскриптов ({e.strerror})")

for d in dirs:
    try:
        files = [f for f in os.scandir(d.path) if f.name.endswith(".jsonl") and f.stat().st_mtime >= since]
    except OSError:
        continue
    for f in files:
        if time.monotonic() - t0 > budget:
            failed(f"не уложилась в {budget} с — транскриптов слишком много")
        try:
            with io.open(f.path, encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    if '"hook_cancelled"' not in line:      # дёшево отсекаем 99,9% строк
                        continue
                    try:
                        r = json.loads(line)
                    except Exception:
                        continue
                    a = r.get("attachment") or {}
                    if a.get("type") != "hook_cancelled":
                        continue
                    t = ts_epoch(r.get("timestamp") or "")
                    if t is None or t < since or t > now:
                        continue
                    total += 1
                    by_hook[a.get("hookName") or "?"] += 1
                    by_proj[d.name] += 1
        except OSError:
            continue

days = max(1, round((now - since) / 86400))
period = (f"{datetime.datetime.fromtimestamp(since, datetime.timezone.utc):%d.%m}–"
          f"{datetime.datetime.fromtimestamp(now, datetime.timezone.utc):%d.%m}")
if total == 0:
    print(f"{tag} Еженедельная проверка ({period}, {days} дн): хуки ни разу не прерывались по таймауту.")
    print("Сообщи оператору одной строкой в начале первого ответа: «Замки за неделю ни разу не прерывались по таймауту».")
    sys.exit(0)

def raz(n):                                         # «1 раз», «3 раза», «5 раз», «12 раз»
    if 11 <= n % 100 <= 14:
        return "раз"
    return "раза" if 2 <= n % 10 <= 4 else "раз"

hooks = ", ".join(f"{h} ×{n}" for h, n in by_hook.most_common())
projs = ", ".join(f"{p} ×{n}" for p, n in by_proj.most_common(3))
print(f"{tag} За {period} ({days} дн) хуки прерывались по таймауту {total} {raz(total)}: {hooks}. Проекты: {projs}.")
print("Прерванный хук движок читает как «разрешаю» (PreToolUse) или «проверено» (Stop) — такие действия прошли без проверки (ADR-0043); "
      "прерванный SessionStart ничего не пропускал — просто не дал своего сообщения. Счёт — по всем проектам этой машины, не только по этому.")
print(f"Сообщи оператору ОДНОЙ строкой в начале первого ответа: «За неделю хуки на этой машине прерывались по таймауту {total} {raz(total)} ({hooks}; проекты: {projs}); разобрать?». "
      "Разбор — события hook_cancelled в транскриптах; первым делом проверь, не откатилась ли правка замков (обновление мозга, другая машина).")
PY
}
# ── КОНЕЦ ПРОВЕРКИ ────────────────────────────────────────────────────────────

# ── Сторож времени: бюджет от старта хука (ADR-0044, дополнение 2026-10-06) ─────
# Как у замка красной зоны: python-часть в фоне, здесь только встроенный `read -t`. Не
# дождались или python3 не напечатал итог (сломан — на Windows заглушка Microsoft Store без
# Python падает сразу) — «проверка не выполнена» встроенным printf: строка итога есть ВСЕГДА,
# а не только когда python3 исправен. stderr фоновой части заменён насовсем (не держит
# трубы движка); завершение — по метке конца, номер — `${!:-}`: так работает и bash 3.2.
KONETS_PROVERKI='__KONETS_PROVERKI_SVODKI__'
OSTALOS=$(( BUDGET - SECONDS ))
(( OSTALOS > 0 )) || say_failed "не уложилась в ${BUDGET} с"
exec 3< <(exec 2>/dev/null; proverit; printf '%s' "$KONETS_PROVERKI")
PROVERKA_PID="${!:-}"
VERDIKT=""
IFS= read -r -d '' -t "$OSTALOS" VERDIKT <&3
case "$VERDIKT" in
  *"$KONETS_PROVERKI") VERDIKT="${VERDIKT%"$KONETS_PROVERKI"}" ;;
  *) [ -n "$PROVERKA_PID" ] && kill "$PROVERKA_PID" 2>/dev/null
     say_failed "не уложилась в ${BUDGET} с (запуск python3 или чтение транскриптов)" ;;
esac
case "$VERDIKT" in
  *"$TAG"*) printf '%s' "$VERDIKT" ;;
  *) say_failed "python3 не выполнил проверку (на Windows — заглушка Microsoft Store без Python?)" ;;
esac
exit 0
