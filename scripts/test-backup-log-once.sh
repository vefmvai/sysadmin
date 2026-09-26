#!/usr/bin/env bash
# Тест: скрипты скилла setup-backups пишут каждую строку журнала РОВНО ОДИН раз и не портят
# чужие строки журнала.
# Прогон: bash scripts/test-backup-log-once.sh
#
# Дефект (боевой журнал сервера оператора, разбор 25.09.2026): log() делал `tee -a "$LOG_FILE"`, а
# cron-строка того же скилла (templates/backup-cron-d) направляет вывод скрипта в тот же
# файл — каждая строка журнала стояла дважды. Лечение — log() смотрит, не идёт ли вывод
# уже в журнал (`[ /dev/stdout -ef "$LOG_FILE" ]`), и тогда пишет в журнал по имени и на
# дозапись, а в stdout не пишет.
#
# Как проверяем: скрипт запускается с нечитаемым конфигом — он пишет одну строку FATAL и
# выходит. Считаем эту строку при четырёх способах запуска:
#   cron     — вывод дописывается в журнал (`>> log 2>&1`), ровно как в templates/backup-cron-d;
#   kanal    — вывод уходит в канал (агент по ssh, ручной запуск в терминале с `| less`);
#   drugoy   — вывод в ДРУГОЙ файл (`> /tmp/run.txt`): журнал и файл получают по строке;
#   bez_dozapisi — журнал открыт БЕЗ дозаписи (`1<> log`, так открывает systemd
#              StandardOutput=file:): старые строки журнала обязаны уцелеть.
# Без двух последних способов тест проходило любое условие «stdout — файл, а не канал»
# (проверено мутантами при независимой проверке 25.09.2026), а запись в stdout без
# дозаписи затирала начало журнала.
# Секция [2] гоняет cron-запуск по исторической версии (до починки): там обязаны быть ДВЕ
# строки. Иначе тест слеп — зелёный и на сломанном скрипте.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKRIPTY="${SKRIPTY_POD_TESTOM:-$ROOT/.claude/skills/setup-backups/scripts}"
HIST_REF="25424f7"          # релиз 2.12.2 — общий с upstream, задвоение в нём есть (tee -a поверх cron-перенаправления)
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$1"; }

# $1 = путь к скрипту, $2 = способ; печатает «<FATAL в журнале> <FATAL в выводе> <OLD в журнале>»
progon() {
  local skript="$1" sposob="$2" log="$TMP/log-$RANDOM$RANDOM" vyvod="$TMP/out-$RANDOM$RANDOM"
  local cfg="$TMP/net-takogo-konfiga"
  : > "$log"; : > "$vyvod"
  case "$sposob" in
    cron)   BACKUP_CONFIG="$cfg" BACKUP_LOG="$log" bash "$skript" >> "$log" 2>&1 ;;
    kanal)  BACKUP_CONFIG="$cfg" BACKUP_LOG="$log" bash "$skript" 2>&1 | cat > "$vyvod" ;;
    drugoy) BACKUP_CONFIG="$cfg" BACKUP_LOG="$log" bash "$skript" > "$vyvod" 2>&1 ;;
    bez_dozapisi)
      printf 'OLD-1 старая строка журнала\nOLD-2 старая строка журнала\n' > "$log"
      BACKUP_CONFIG="$cfg" BACKUP_LOG="$log" bash "$skript" 1<> "$log" 2>&1 ;;
  esac
  printf '%s %s %s\n' "$(grep -c 'FATAL' "$log")" "$(grep -c 'FATAL' "$vyvod")" "$(grep -c '^OLD-' "$log")"
}

echo "── Журнал бэкапа: строка ровно один раз ─────────────────"

echo "[1] Текущие скрипты"
for imya in backup-all.sh check-backup-age.sh; do
  s="$SKRIPTY/$imya"
  read -r vlog vvyv vold <<<"$(progon "$s" cron)"
  [ "$vlog" = 1 ] && ok "$imya, cron (>>): в журнале 1 строка" \
                  || fail "$imya, cron (>>): в журнале $vlog строк, ждали 1"
  read -r vlog vvyv vold <<<"$(progon "$s" kanal)"
  [ "$vlog" = 1 ] && [ "$vvyv" = 1 ] && ok "$imya, канал: 1 в журнале и 1 на экране" \
    || fail "$imya, канал: журнал $vlog, экран $vvyv — ждали 1 и 1"
  read -r vlog vvyv vold <<<"$(progon "$s" drugoy)"
  [ "$vlog" = 1 ] && [ "$vvyv" = 1 ] && ok "$imya, вывод в другой файл: 1 в журнале и 1 в файле" \
    || fail "$imya, вывод в другой файл: журнал $vlog, файл $vvyv — ждали 1 и 1"
  read -r vlog vvyv vold <<<"$(progon "$s" bez_dozapisi)"
  [ "$vlog" = 1 ] && [ "$vold" = 2 ] && ok "$imya, журнал без дозаписи (systemd file:): старые строки целы, новая одна" \
    || fail "$imya, журнал без дозаписи: новых $vlog, старых $vold из 2 — ждали 1 и 2 (строки затёрты)"
done

echo "[2] Историческая версия $HIST_REF обязана показать задвоение (тест не слеп)"
for imya in backup-all.sh check-backup-age.sh; do
  stariy="$TMP/stariy-$imya"
  # В папку — через cd, а не `git -C`: MSYS_NO_PATHCONV (без него Git Bash портит аргумент
  # «ревизия:путь») заодно запрещает переводить путь для -C, и git.exe не находит папку.
  if ! ( cd "$ROOT" && MSYS_NO_PATHCONV=1 git show "$HIST_REF:.claude/skills/setup-backups/scripts/$imya" ) > "$stariy" 2>/dev/null; then
    fail "$imya: потерян источник — нет $HIST_REF в истории"; continue
  fi
  read -r vlog vvyv vold <<<"$(progon "$stariy" cron)"
  [ "$vlog" = 2 ] && ok "$imya до починки: 2 строки — дефект воспроизводится" \
                  || fail "$imya до починки: $vlog строк — тест не видит дефект, которому посвящён"
done

echo "─────────────────────────────────────────────────────────"
printf 'Итог: %d прошло, %d провалено\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
