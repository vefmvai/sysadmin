#!/usr/bin/env bash
# .claude/hooks/brain-update-check.sh — SessionStart-хук: вышел ли релиз мозга новее
# установленного (Cold Start, Шаг 5.5; ADR-0040).
#
# ЗАЧЕМ. Шаг 5.5 до этого был прозой: алгоритм в cold-start.md с заглушкой на месте
# запуска («: # placeholder»). Исполнять его было некому, и на машине оператора метка
# проверки не появилась ни разу (найдено 15.09.2026). Вторая дыра сидела в самом
# алгоритме: он спрашивал `origin`, а у того, кто ведёт свою копию мозга (личный origin +
# upstream автора), релизные теги живут у `upstream` — проверка честно отвечала «новых
# версий нет». Хук делает проверку механической.
#
# ПОВЕДЕНИЕ:
#   с прошлой проверки меньше суток          → молча выходим, сеть не трогаем
#   релиз строго новее VERSION               → печатаем уведомление с кодом 0: движок
#                                               кладёт вывод SessionStart в контекст, агент
#                                               передаёт его оператору одной строкой
#   релиз тот же или VERSION впереди (dev)   → молча
#   нет git / сети / remote / VERSION        → молча, код 0: проверка опциональна
#
# Ничего не обновляет и не меняет в репозитории: теги читаются `git ls-remote` прямо с
# удалённого, без fetch — локальные теги (в том числе тег-двойник) не трогаются и не
# участвуют. Единственная запись — метка `.update-check` (в .gitignore).
#
# Флаги:
#   --root DIR  корень мозга (по умолчанию — два уровня над этим файлом);
#   --force     без суточного лимита, метку не трогает (ручная проверка «прямо сейчас»);
#   --status    печатает REMOTE= LOCAL= LATEST= NEWER= для процедуры «обнови sysadmin»;
#               без лимита и метки; код 1, если последний релиз узнать не удалось.
#
# Ручная проверка: bash .claude/hooks/tests/test-brain-update-check.sh

set -u

ROOT=""; FORCE=0; STATUS=0
while [ $# -gt 0 ]; do
    case "$1" in
        --root)   ROOT="${2:-}"; shift 2 2>/dev/null || shift ;;
        --force)  FORCE=1; shift ;;
        --status) STATUS=1; FORCE=1; shift ;;
        *)        shift ;;
    esac
done

# Движок подаёт на вход JSON события. Он не нужен, но канал дочитываем, чтобы запись
# движка не упёрлась в закрытый конец. Только канал: терминал или /dev/null не читаем,
# иначе ручной запуск ждал бы ввода.
if [ -p /dev/stdin ]; then cat >/dev/null 2>&1; fi

# В режиме хука любой сбой — молчание с кодом 0; в режиме --status — код 1, чтобы
# процедура обновления остановилась, а не пошла дальше с пустыми значениями.
bail() { exit "$STATUS"; }

if [ -z "$ROOT" ]; then
    ROOT="$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)" || bail
fi
command -v git >/dev/null 2>&1 || bail
[ -f "$ROOT/VERSION" ] || bail
git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || bail

# VERSION на Windows может прийти с CRLF и с меткой порядка байт (BOM — её дописывают
# Блокнот и PowerShell 5.1). И то и другое ломало бы проверку формата, и хук молчал бы при
# вышедшем релизе (BOM найден независимой проверкой 15.09.2026). tr удаляет байты по
# одному; в строке X.Y.Z их быть не может, так что лишнего не срежет.
LOCAL="$(LC_ALL=C tr -d '\357\273\277 \t\r\n' < "$ROOT/VERSION")"
printf '%s' "$LOCAL" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || bail

# Откуда брать релизы: явная настройка → upstream → origin. Порядок не случаен: upstream
# по общему соглашению — репозиторий автора, origin у своей копии — личный.
resolve_remote() {
    local r
    r="$(git -C "$ROOT" config --get sysadmin.updateRemote 2>/dev/null)"
    if [ -n "$r" ] && git -C "$ROOT" remote get-url "$r" >/dev/null 2>&1; then
        printf '%s\n' "$r"; return 0
    fi
    for r in upstream origin; do
        if git -C "$ROOT" remote get-url "$r" >/dev/null 2>&1; then
            printf '%s\n' "$r"; return 0
        fi
    done
    return 1
}
REMOTE="$(resolve_remote)" || bail

# Суточный лимит. Метка — секунды эпохи: `date -u +%s` одинаков в GNU и BSD, а разбор
# даты ISO — нет. Метку прежнего формата (ISO) и метку «из будущего» считаем давними.
# Пишем ДО сетевого запроса: упавшая проверка повторится завтра, а не на каждом старте.
if [ "$FORCE" -eq 0 ]; then
    MARK="$ROOT/.update-check"
    NOW="$(date -u +%s)"
    LAST=""
    [ -f "$MARK" ] && LAST="$(tr -d ' \t\r\n' < "$MARK")"
    case "$LAST" in
        ''|*[!0-9]*) ;;
        *)
            if [ "$LAST" -le "$NOW" ] 2>/dev/null && [ $((NOW - LAST)) -lt 86400 ] 2>/dev/null; then
                exit 0
            fi
            ;;
    esac
    printf '%s\n' "$NOW" > "$MARK" 2>/dev/null || true
fi

# Теги — прямо с удалённого. Никакого ввода: запрос пароля или окно менеджера учётных
# данных на старте сессии повесили бы её до таймаута хука. Строки закрывают разные пути
# и друг друга не заменяют: credential.interactive=never глушит менеджер учётных данных и
# askpass на свежем git (на git 2.55 askpass не глушит больше ничто из списка — проверено
# 15.09.2026), GIT_ASKPASS=false — askpass на git, который этой настройки не знает,
# GIT_TERMINAL_PROMPT=0 — запрос в терминале, http.lowSpeed* — зависшую передачу.
TAGS="$(GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never GIT_ASKPASS=false SSH_ASKPASS=false \
        git -C "$ROOT" -c credential.interactive=never \
            -c http.lowSpeedLimit=1 -c http.lowSpeedTime=10 \
            ls-remote --tags --refs "$REMOTE" 2>/dev/null)" || bail

# Только релизные теги vX.Y.Z (без -rc и прочего), порядок — по числам, а не по строкам:
# строкой v2.9.0 «больше» v2.10.0.
LATEST="$(printf '%s\n' "$TAGS" \
    | awk '{ print $2 }' \
    | sed -n 's#^refs/tags/v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$#\1#p' \
    | sort -t. -k1,1n -k2,2n -k3,3n \
    | tail -1)"
[ -n "$LATEST" ] || bail

# Строго новее, по числам. Равенство и «dev впереди релиза» — не повод говорить.
newer() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        split(a, x, "."); split(b, y, ".")
        for (i = 1; i <= 3; i++) {
            if (x[i] + 0 > y[i] + 0) exit 0
            if (x[i] + 0 < y[i] + 0) exit 1
        }
        exit 1
    }'
}
NEWER=0
if newer "$LATEST" "$LOCAL"; then NEWER=1; fi

if [ "$STATUS" -eq 1 ]; then
    printf 'REMOTE=%s\nLOCAL=%s\nLATEST=%s\nNEWER=%s\n' "$REMOTE" "$LOCAL" "$LATEST" "$NEWER"
    exit 0
fi
[ "$NEWER" -eq 1 ] || exit 0

cat <<EOF
[brain-update-check] Вышла новая версия мозга sysadmin: v$LATEST (установлена v$LOCAL; релизы берутся из remote «$REMOTE»).
Cold Start, Шаг 5.5: сообщи оператору ОДНОЙ строкой в самом начале первого ответа, выше резюме —
«Доступна новая версия sysadmin: v$LATEST (твоя — v$LOCAL). Скажи «обнови sysadmin» — покажу, что изменилось, и применю только после подтверждения; данные в infra/ не затрагиваются.»
Сам не обновляй: применение — только по явной команде оператора, процедура — .claude/agents/references/cold-start.md, раздел «Когда оператор говорит «обнови sysadmin»».
EOF
exit 0
