#!/usr/bin/env bash
# test-route-targets.sh — тест замка маршрутов.
#
# Правило 2 из `building-enforcement.md`: тест обязан брать проверочные данные ИЗ
# ИСТОЧНИКА, а не из головы автора, иначе замок и тест ошибаются согласованно и
# зелёный цвет ничего не значит. Поэтому секция [1] достаёт **настоящую** дефектную
# строку из истории репозитория (коммит 761366c, где маршрут про DNS отправлял в файл
# без единого упоминания DNS), а не сочиняет похожую.
#
# Запуск: bash scripts/test-route-targets.sh

set -u

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || ROOT="$(pwd)"
cd "$ROOT" || exit 2

LINT="$ROOT/scripts/check-route-targets.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/route-test.XXXXXX")"
PASS=0
FAIL=0

cleanup() {
    # Точечно, без rm -rf: в репозитории замок красной зоны, он остановит рекурсивное
    # удаление и тест встанет на ровном месте (building-enforcement.md, границы).
    find "$TMP" -type f -exec rm -f {} \; 2>/dev/null
    find "$TMP" -depth -type d -exec rmdir {} \; 2>/dev/null
}
trap cleanup EXIT

# Плацдарм: копия дерева знаний, чтобы относительные пути резолвились как в бою.
FIX="$TMP/.claude/knowledge/networking"
mkdir -p "$FIX/_reference" "$FIX/_live" "$FIX/_meta"

ok()   { PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$1"; }

# Ожидаем: замок ЗАБЛОКИРОВАЛ (rc=1)
expect_block() {
    local file="$1" what="$2"
    if bash "$LINT" "$file" >/dev/null 2>&1; then
        bad "$what — ПРОПУЩЕНО, а должно было заблокировать"
    else
        ok "$what — заблокировано"
    fi
}

# Ожидаем: замок ПРОПУСТИЛ (rc=0)
expect_pass() {
    local file="$1" what="$2"
    if bash "$LINT" "$file" >/dev/null 2>&1; then
        ok "$what — пропущено"
    else
        bad "$what — ЛОЖНОЕ СРАБАТЫВАНИЕ, замок парализует работу"
    fi
}

echo "═══ [1] Настоящий дефект из истории git (не выдумка) ═══"

HIST_REF="761366c"
REAL_ROW="$(git show "$HIST_REF:.claude/knowledge/networking/README.md" 2>/dev/null \
    | grep -F 'DoU' | head -1)"

if [ -z "$REAL_ROW" ]; then
    bad "потерян источник: в $HIST_REF нет строки с DoU — тест недействителен"
else
    # Целевой файл копируем настоящий: важно, что в нём реально нет слова DNS.
    cp .claude/knowledge/networking/_reference/routing-server-3xui.md "$FIX/_reference/"
    cp .claude/knowledge/networking/_reference/fronting-strategies.md "$FIX/_reference/"
    {
        printf '# фикстура\n\n| Вопрос / симптом | Открыть |\n|---|---|\n'
        printf '%s\n' "$REAL_ROW"
    } > "$FIX/README.md"
    expect_block "$FIX/README.md" "историческая строка про DNS → файл без DNS"

    # Контроль источника: убеждаемся, что цель действительно без DNS, иначе секция
    # проверяет не то, что думает.
    if grep -qi 'dns' "$FIX/_reference/routing-server-3xui.md"; then
        bad "источник изменился: в routing-server-3xui.md появился DNS — секцию [1] пересобрать"
    else
        ok "контроль источника: в целевом файле по-прежнему ноль упоминаний DNS"
    fi
fi

echo "═══ [2] Фикстура обхода — то, что замок ОБЯЗАН ловить ═══"

printf 'x\n' > "$FIX/_reference/пустышка.md"

mk() { printf '# фикстура\n\n| Вопрос / симптом | Открыть |\n|---|---|\n%s\n' "$1" > "$FIX/README.md"; }

mk '| Настройка XHTTP-транспорта и mKCP | `_reference/пустышка.md` |'
expect_block "$FIX/README.md" "термины есть, в целевом файле их нет"

mk '| Что-то про CSRF | `_reference/nonexistent-file.md` |'
expect_block "$FIX/README.md" "путь ведёт в несуществующий файл"

mk '| Реестр правил | `_reference/routing-server-3xui.md` §999 |'
expect_block "$FIX/README.md" "номер раздела §999 не существует"

mk '| Правила и порядок | `_reference/routing-server-3xui.md` §4-§999 |'
expect_block "$FIX/README.md" "диапазон: второй конец не существует"

mk '| **XHTTP** и `mKCP` в жирном и кавычках | `_reference/пустышка.md` |'
expect_block "$FIX/README.md" "разметка не прячет термины от проверки"

echo "═══ [3] Обратная сторона — заведомо корректный вход ═══"

mk '| Cloudflare-fronting, WARP, uTLS | `_reference/fronting-strategies.md` |'
expect_pass "$FIX/README.md" "термины есть в целевом файле"

mk '| DNS как рубеж блокировок, DoH и DoT | `_reference/fronting-strategies.md` §8 |'
expect_pass "$FIX/README.md" "существующий §8 плюс совпадающие термины"

mk '| Порядок правил и sniffing | `_reference/routing-server-3xui.md` §4 |'
expect_pass "$FIX/README.md" "существующий §4"

mk '| Что прямо сейчас блокируют и что живёт | `_reference/routing-server-3xui.md` |'
expect_pass "$FIX/README.md" "русская строка без терминов — непроверяемо, но не блок"

echo "═══ [4] Парсер: строки, которые НЕ должны разбираться как маршрут ═══"

printf '# фикстура\n\n| Файл | Что внутри |\n|---|---|\n| `_reference/пустышка.md` | Описание файла про XHTTP и mKCP |\n' > "$FIX/README.md"
expect_pass "$FIX/README.md" "строка каталога (путь в первой ячейке) не проверяется словарём"

printf '# фикстура\n\nОбычный текст со ссылкой `_reference/пустышка.md` про XHTTP.\n' > "$FIX/README.md"
expect_pass "$FIX/README.md" "не-табличная строка не разбирается"

printf '# фикстура\n\n| Задача | Скилл |\n|---|---|\n| Поставить панель | `/setup-vpn-panel` |\n' > "$FIX/README.md"
expect_pass "$FIX/README.md" "таблица скиллов без путей .md не ломает замок"

echo "═══ [5] Границы и отказы ═══"

printf '' > "$FIX/README.md"
expect_pass "$FIX/README.md" "пустой файл не роняет замок"

if bash "$LINT" "$TMP/нет-такого-файла.md" >/dev/null 2>&1; then
    bad "несуществующий аргумент даёт код 0 — опечатка неотличима от чистой проверки"
else
    ok "несуществующий аргумент даёт ненулевой код"
fi

# Путь оператора содержит пробел («…/Claude Code/sysadmin») — та же грабля, что уронила
# первую версию линтера переносимости 25.07.2026.
SPACED="$TMP/каталог с пробелом и кириллицей"
mkdir -p "$SPACED/_reference"
printf 'x\n' > "$SPACED/_reference/пустышка.md"
printf '# ф\n\n| Вопрос | Открыть |\n|---|---|\n| XHTTP и mKCP | `_reference/пустышка.md` |\n' > "$SPACED/README.md"
expect_block "$SPACED/README.md" "путь с пробелом и кириллицей разбирается корректно"

echo ""
echo "─────────────────────────────────────────────"
echo "Пройдено: $PASS, провалено: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
