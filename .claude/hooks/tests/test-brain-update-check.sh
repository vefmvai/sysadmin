#!/usr/bin/env bash
# Тесты проверки обновлений мозга (ADR-0040).
# Прогон: bash .claude/hooks/tests/test-brain-update-check.sh
#
# Вызов параметризован, чтобы тест можно было испытать на исторической и на испорченной
# версии, а не только на исправной (персона §3.11; свод замков, правила 3г и 3д):
#   CHECKER=<скрипт>          что проверяем (по умолчанию — хук из репозитория);
#   SETTINGS=<settings.json>  откуда берём подключение хука (по умолчанию — из репозитория).
#
# НЕ покрыто, и почему: ветка «вход — терминал, не читаем» (`[ -p /dev/stdin ]`) —
# терминал в неинтерактивном прогоне не воспроизвести; SSH-remote; git, не знающий
# `credential.interactive`, — на машине автора такого нет, от него страхует
# `GIT_ASKPASS=false`, наличие которого проверяет секция [9] по тексту хука.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
CHECKER="${CHECKER:-$REPO/.claude/hooks/brain-update-check.sh}"
SETTINGS="${SETTINGS:-$REPO/.claude/settings.json}"
PASS=0; FAIL=0; SRV=""; OUT=""; RC=0

TMP="$(mktemp -d)"
trap 'if [ -n "$SRV" ]; then kill "$SRV" 2>/dev/null; fi; rm -rf "$TMP"' EXIT
# Фикстуры — под путём с пробелом и кириллицей: так выглядят реальные пути операторов
# (…/Claude Code/sysadmin), и на таких путях замки уже ломались (свод замков, чек-лист).
W="$TMP/мозг с пробелом"
mkdir -p "$W"

# Фикстура не должна зависеть от глобальной настройки git машины (url.insteadOf, чужой
# sysadmin.updateRemote, autocrlf и менеджер учётных данных из системного конфига Git for
# Windows). Это окружение фикстуры: проверяемое поведение хука от него не зависит —
# независимая проверка 15.09.2026 прогнала хук на реальном конфиге машины, итог тот же.
export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.name test
git config --global user.email test@example.invalid
git config --global init.defaultBranch main

ok()  { PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$1"; }

# Удалённый репозиторий: mk_remote <имя> <тег>... → путь к bare-репозиторию.
# Тег с префиксом «a:» — аннотированный: так выпускаются настоящие релизы, и у ls-remote
# у них другая форма вывода, чем у лёгкого тега (перепись форм, правило 3в).
mk_remote() {
    local name="$1"; shift
    local seed="$W/seed-$name" bare="$W/$name.git" t
    git init -q "$seed"
    git -C "$seed" commit -q --allow-empty -m seed
    for t in "$@"; do
        case "$t" in
            a:*) git -C "$seed" tag -a -m "release ${t#a:}" "${t#a:}" ;;
            *)   git -C "$seed" tag "$t" ;;
        esac
    done
    git init -q --bare "$bare"
    git -C "$seed" push -q "$bare" --tags >/dev/null 2>&1
    printf '%s\n' "$bare"
}

# Мозг: mk_brain <имя> <VERSION с экранированными байтами для printf %b> → путь к каталогу
mk_brain() {
    local dir="$W/$1"
    git init -q "$dir"
    printf '%b' "$2" > "$dir/VERSION"
    git -C "$dir" add VERSION >/dev/null 2>&1
    git -C "$dir" commit -q -m init >/dev/null 2>&1
    printf '%s\n' "$dir"
}

# call <корень> [флаги] — запуск подопечного; вывод в OUT, код в RC.
call() {
    local dir="$1"; shift
    OUT="$(bash "$CHECKER" --root "$dir" "$@" </dev/null 2>/dev/null)"; RC=$?
}

# «Сообщает» = код 0 И вывод называет версию. Код обязателен: по документации движок берёт
# вывод SessionStart в контекст при коде 0. Прежняя версия теста смотрела только на вывод,
# и хук с `exit 1` в конце проходил её целиком (независимая проверка 15.09.2026).
expect_says() { # $1 описание, $2 версия
    if [ "$RC" -eq 0 ] && [ -n "$OUT" ] && printf '%s' "$OUT" | grep -qF "$2"; then ok "$1"
    else bad "$1 — ожидали код 0 и сообщение про $2; код $RC, вывод: ${OUT:-пусто}"; fi
}
expect_silent() { # $1 описание: молчание И код 0
    if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "$1"
    else bad "$1 — ожидали молчание с кодом 0; код $RC, вывод: ${OUT:-пусто}"; fi
}

echo "── Тесты проверки обновлений мозга (ADR-0040) ─────────────"

echo "[1] Сравнение версий"
R="$(mk_remote rel v2.12.2 a:v2.13.0)"
B="$(mk_brain b1 '2.12.2\n')"; git -C "$B" remote add origin "$R"
call "$B"; expect_says   "аннотированный релиз новее VERSION — сообщает" "2.13.0"
RL="$(mk_remote rel-lw v2.12.2 v2.13.0)"
B="$(mk_brain b1l '2.12.2\n')"; git -C "$B" remote add origin "$RL"
call "$B"; expect_says   "лёгкий тег новее VERSION — сообщает" "2.13.0"
B="$(mk_brain b2 '2.13.0\n')"; git -C "$B" remote add origin "$R"
call "$B"; expect_silent "та же версия — молчит"
B="$(mk_brain b3 '2.14.0\n')"; git -C "$B" remote add origin "$R"
call "$B"; expect_silent "dev-версия впереди релиза — молчит, откат не предлагает"

echo "[2] Перепись форм: CRLF и BOM в VERSION, порядок по числам, нерелизные теги"
B="$(mk_brain b4 '2.13.0\r\n')"; git -C "$B" remote add origin "$R"
call "$B"; expect_silent "VERSION с CRLF, та же версия — молчит"
B="$(mk_brain b5 '2.12.2\r\n')"; git -C "$B" remote add origin "$R"
call "$B"; expect_says   "VERSION с CRLF, релиз новее — сообщает" "2.13.0"
B="$(mk_brain b6 '2.12.2')"; git -C "$B" remote add origin "$R"
call "$B"; expect_says   "VERSION без перевода строки — сообщает" "2.13.0"
# BOM дописывают Блокнот и PowerShell 5.1; .gitattributes его не снимает.
B="$(mk_brain b6b '\xEF\xBB\xBF2.12.2\r\n')"; git -C "$B" remote add origin "$R"
call "$B"; expect_says   "VERSION с BOM, релиз новее — сообщает" "2.13.0"
B="$(mk_brain b6c '\xEF\xBB\xBF2.13.0\n')"; git -C "$B" remote add origin "$R"
call "$B"; expect_silent "VERSION с BOM, та же версия — молчит"
R2="$(mk_remote rel-num v2.9.0 v2.10.0)"
B="$(mk_brain b7 '2.9.0\n')"; git -C "$B" remote add origin "$R2"
call "$B"; expect_says   "v2.10.0 новее v2.9.0 (по числам, не по строкам)" "2.10.0"
R3="$(mk_remote rel-rc v2.12.2 v3.0.0-rc1 latest)"
B="$(mk_brain b8 '2.12.2\n')"; git -C "$B" remote add origin "$R3"
call "$B"; expect_silent "тег-кандидат и нерелизный тег релизом не считаются"

echo "[3] Источник релизов: upstream важнее origin (дефект найден 15.09.2026)"
# Своя копия мозга: origin — личный репозиторий без новых тегов, релизы живут у upstream.
PRIV="$(mk_remote priv v2.12.2)"
UP="$(mk_remote up v2.12.2 a:v2.13.0)"
B="$(mk_brain b9 '2.12.2\n')"
git -C "$B" remote add origin "$PRIV"; git -C "$B" remote add upstream "$UP"
call "$B"; expect_says   "origin без нового релиза, upstream с новым — сообщает" "2.13.0"
B="$(mk_brain b10 '2.12.2\n')"
git -C "$B" remote add origin "$UP"; git -C "$B" remote add upstream "$PRIV"
git -C "$B" config sysadmin.updateRemote origin
call "$B"; expect_says   "явная настройка sysadmin.updateRemote важнее upstream" "2.13.0"

echo "[4] Локальный тег-двойник не обманывает (случай 06.08.2026)"
# Локально стоит свой v2.13.0, у удалённого последний релиз — v2.12.2.
R4="$(mk_remote rel-twin v2.12.2)"
B="$(mk_brain b11 '2.12.2\n')"; git -C "$B" remote add origin "$R4"; git -C "$B" tag v2.13.0
call "$B"; expect_silent "локальный тег новее релиза — молчит"

echo "[5] Суточный лимит и метка"
NOW="$(date -u +%s)"
B="$(mk_brain b12 '2.12.2\n')"; git -C "$B" remote add origin "$R"
printf '%s\n' "$((NOW - 100))" > "$B/.update-check"
call "$B"; expect_silent "проверка была 100 с назад — молчит"
m="$(tr -d '\r\n' < "$B/.update-check")"
if [ "$m" = "$((NOW - 100))" ]; then ok "под лимитом метку не переписывает (вышел до сети)"
else bad "под лимитом метка переписана: $m"; fi
printf '%s\n' "$((NOW - 90000))" > "$B/.update-check"
call "$B"; expect_says   "проверка была больше суток назад — сообщает" "2.13.0"
m="$(tr -d '\r\n' < "$B/.update-check")"
if [ -n "$m" ] && [ "$m" -ge "$NOW" ] 2>/dev/null; then ok "после проверки метка обновлена"
else bad "после проверки метка не обновлена: ${m:-пусто}"; fi
call "$B"; expect_silent "повторный старт в тот же день — молчит"
B="$(mk_brain b13 '2.12.2\n')"; git -C "$B" remote add origin "$R"
printf '2026-09-15T16:10:26Z\n' > "$B/.update-check"
call "$B"; expect_says   "метка прежнего формата (дата ISO) считается давней" "2.13.0"
printf '%s\n' "$((NOW + 999999))" > "$B/.update-check"
call "$B"; expect_says   "метка из будущего считается давней" "2.13.0"
printf '%s\n' "$((NOW - 100))" > "$B/.update-check"
call "$B" --force; expect_says "--force обходит суточный лимит" "2.13.0"

echo "[6] Сбои — молча и с кодом 0"
B="$(mk_brain b14 '2.12.2\n')"; git -C "$B" remote add origin "$W/нет-такого.git"
call "$B"; expect_silent "remote недоступен"
if [ -f "$B/.update-check" ]; then ok "метка записана и при недоступном remote (повтор завтра, не на каждом старте)"
else bad "после недоступного remote метки нет — проверка будет ходить в сеть на каждом старте"; fi
B="$(mk_brain b15 '2.12.2\n')"
call "$B"; expect_silent "нет ни одного remote"
B="$W/b16"; git init -q "$B"; git -C "$B" remote add origin "$R"
call "$B"; expect_silent "нет файла VERSION"
B="$W/b17"; mkdir -p "$B"; printf '2.12.2\n' > "$B/VERSION"
call "$B"; expect_silent "каталог не под git"
B="$(mk_brain b18 'не версия\n')"; git -C "$B" remote add origin "$R"
call "$B"; expect_silent "VERSION не в формате X.Y.Z"

echo "[7] Режим --status для процедуры «обнови sysadmin»"
B="$(mk_brain b19 '\xEF\xBB\xBF2.12.2\r\n')"
git -C "$B" remote add origin "$PRIV"; git -C "$B" remote add upstream "$UP"
call "$B" --status
want="$(printf 'REMOTE=upstream\nLOCAL=2.12.2\nLATEST=2.13.0\nNEWER=1')"
if [ "$RC" -eq 0 ] && [ "$OUT" = "$want" ]; then ok "печатает remote, установленную и последнюю версии, NEWER=1"
else bad "--status — код $RC, вывод: ${OUT:-пусто}"; fi
if [ ! -f "$B/.update-check" ]; then ok "--status метку не пишет"
else bad "--status записал метку и съел сегодняшнюю проверку при старте"; fi
B="$(mk_brain b19d '2.14.0\n')"; git -C "$B" remote add origin "$R"
call "$B" --status
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qx 'NEWER=0'; then ok "мозг впереди релиза — NEWER=0 (процедура не откатит)"
else bad "мозг впереди релиза — ожидали NEWER=0 с кодом 0; код $RC, вывод: ${OUT:-пусто}"; fi
B="$(mk_brain b20 '2.12.2\n')"; git -C "$B" remote add origin "$W/нет-такого.git"
call "$B" --status
if [ "$RC" -ne 0 ]; then ok "релиз узнать не удалось — код не 0, процедура остановится"
else bad "--status при недоступном remote вернул 0, вывод: ${OUT:-пусто}"; fi

echo "[8] Подключение: хук стоит в settings.json и срабатывает так, как его зовёт движок"
# Команда берётся из самого settings.json, а не переписывается в тесте: иначе тест
# проверял бы свою копию подключения, а не ту, что едет пользователю.
HOOKDEF="$(python3 - "$SETTINGS" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for block in d.get("hooks", {}).get("SessionStart", []):
    matcher = block.get("matcher", "")
    if matcher and "startup" not in matcher:
        continue
    for h in block.get("hooks", []):
        if "brain-update-check.sh" in h.get("command", ""):
            print(h.get("timeout", 0))
            print(h["command"])
            sys.exit(0)
sys.exit(1)
PY
)"
if [ -z "$HOOKDEF" ]; then
    bad "в settings.json нет хука SessionStart на startup с brain-update-check.sh (или нет python3 для разбора)"
else
    ok "SessionStart на startup подключает brain-update-check.sh"
    TIMEOUT="$(printf '%s\n' "$HOOKDEF" | head -1)"
    CMD="$(printf '%s\n' "$HOOKDEF" | tail -n +2)"
    # Без явного таймаута движок ждёт хук до 10 минут: зависшая сеть держала бы старт сессии.
    if [ "$TIMEOUT" -gt 0 ] 2>/dev/null && [ "$TIMEOUT" -le 30 ]; then ok "таймаут хука задан и не больше 30 с ($TIMEOUT)"
    else bad "таймаут хука не задан или больше 30 с: ${TIMEOUT:-нет}"; fi
    P="$W/проект"
    mkdir -p "$P/.claude/hooks"
    cp "$CHECKER" "$P/.claude/hooks/brain-update-check.sh"
    git init -q "$P"; printf '2.12.2\n' > "$P/VERSION"; git -C "$P" remote add origin "$R"
    OUT="$(printf '{"hook_event_name":"SessionStart","source":"startup"}' \
           | CLAUDE_PROJECT_DIR="$P" bash -c "$CMD" 2>/dev/null)"; RC=$?
    expect_says "команда из settings.json со входом движка — сообщает, корень находит сама" "2.13.0"
fi

echo "[9] Старт сессии не ждёт ввода учётных данных"
# По тексту (правило 3г): каждая строка закрывает свой путь к вводу, и поведенческий
# случай ниже доказывает только тот путь, что есть на этой машине. Комментарии не в счёт.
CODE="$(grep -v '^[[:space:]]*#' "$CHECKER")"
for needle in 'credential.interactive=never' 'GIT_TERMINAL_PROMPT=0' 'GIT_ASKPASS=false' 'http.lowSpeedTime='; do
    if printf '%s\n' "$CODE" | grep -qF -- "$needle"; then ok "в вызове git есть $needle"
    else bad "в хуке нет $needle — старт сессии может ждать ввода"; fi
done
# По поведению: remote отвечает 401 и просит пароль, в окружении подопечного задан askpass,
# который пишет журнал вызовов. Навязываем его именно хуку через env (правило 3д).
if ! command -v python3 >/dev/null 2>&1; then
    bad "нет python3 — поведенческий случай с запросом пароля не прогнан"
else
    PORTFILE="$TMP/port"; ASKLOG="$TMP/askpass.log"; ASK="$TMP/askpass.sh"
    printf '#!/bin/sh\necho called >> "%s"\necho x\n' "$ASKLOG" > "$ASK"; chmod +x "$ASK"
    python3 - "$PORTFILE" >/dev/null 2>&1 <<'PY' &
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="brain"')
        self.send_header("Content-Length", "0")
        self.end_headers()
    def log_message(self, *args):
        pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
with open(sys.argv[1], "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
PY
    SRV=$!
    i=0; while [ ! -s "$PORTFILE" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
    if [ ! -s "$PORTFILE" ]; then
        bad "локальный сервер 401 не поднялся — случай не прогнан"
    else
        B="$(mk_brain b22 '2.12.2\n')"
        git -C "$B" remote add origin "http://127.0.0.1:$(cat "$PORTFILE")/brain.git"
        started="$(date +%s)"
        OUT="$(env GIT_ASKPASS="$ASK" SSH_ASKPASS="$ASK" NO_PROXY=127.0.0.1 no_proxy=127.0.0.1 \
               bash "$CHECKER" --root "$B" --force </dev/null 2>/dev/null)"; RC=$?
        took=$(( $(date +%s) - started ))
        expect_silent "remote просит пароль — молча, код 0"
        if [ ! -s "$ASKLOG" ]; then ok "askpass из окружения не вызван (${took} с)"
        else bad "хук вызвал askpass $(wc -l < "$ASKLOG" | tr -d ' ') раз — на старте сессии это ожидание ввода пароля (${took} с)"; fi
    fi
fi

echo "[Вывод] Уведомление читаемо и адресовано агенту"
B="$(mk_brain b21 '2.12.2\n')"; git -C "$B" remote add origin "$R"
call "$B"
if printf '%s' "$OUT" | head -1 | grep -q '^\[brain-update-check\]'; then ok "первая строка помечена источником"
else bad "первая строка не помечена [brain-update-check]: ${OUT:-пусто}"; fi
if printf '%s' "$OUT" | grep -q 'обнови sysadmin'; then ok "называет команду «обнови sysadmin», кириллица цела"
else bad "нет команды «обнови sysadmin» или текст искажён"; fi
if printf '%s' "$OUT" | grep -q 'Сам не обновляй'; then ok "запрещает агенту обновляться без команды"
else bad "нет запрета обновляться без команды оператора"; fi
# Локаль навязывается именно подопечному через env, а не всему тесту (правило 3д).
OUT="$(env LC_ALL=C LANG=C bash "$CHECKER" --root "$B" --force </dev/null 2>/dev/null)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'обнови sysadmin'; then ok "при LC_ALL=C уведомление доходит целиком"
else bad "при LC_ALL=C уведомление пустое или искажено; код $RC: ${OUT:-пусто}"; fi

echo "────────────────────────────────────────────────────"
echo "Итог: пройдено $PASS, провалено $FAIL"
[ "$FAIL" -eq 0 ]
