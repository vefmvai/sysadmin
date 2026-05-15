#!/usr/bin/env bash
# invoke-claude.sh — один вызов claude -p для определения подходящего скилла.
#
# Использование:
#   ./invoke-claude.sh "<фраза оператора>"
#
# Вывод (stdout, одна строка):
#   <skill-name>|<cost-usd>|<duration-ms>
#   где skill-name — имя скилла (без префикса /) или "none"; cost — стоимость
#   в USD как число с точкой; duration — wall-clock мс.
#
# В случае ошибки (timeout, claude отвалился, не распарсился ответ) — выход 1,
# stderr с диагностикой.
#
# Запускать строго из корня репо sysadmin/ — иначе claude не увидит локальные
# скиллы.

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 \"<phrase>\"" >&2
    exit 2
fi

phrase="$1"

# Проверка инструментов
command -v claude >/dev/null 2>&1 || { echo "error: claude CLI not in PATH" >&2; exit 1; }
command -v jq >/dev/null 2>&1     || { echo "error: jq not installed" >&2; exit 1; }

# Жёсткий системный промпт. Цель: модель отвечает ровно одной строкой,
# содержащей "SKILL: <name>" или "SKILL: none". Парсим эту строку из
# поля .result JSON-ответа.
system_prompt='Ты диспетчер скиллов агента-сисадмина для репо sysadmin/. На фразу оператора выбери ровно один скилл из доступных в .claude/skills/ этого репо, который должен быть активирован. Если ни один не подходит семантически — ответь "SKILL: none". Если подошли бы несколько — выбери самый точный по доминирующему намерению. Не выполняй ничего, не вызывай инструменты, не объясняй выбор. Ответ строго одной строкой формата: SKILL: <имя-скилла-без-слэша> (или SKILL: none). Никакого markdown, никакого текста до и после.'

# Вызов headless, без сохранения сессии. Игнорируем stdin, чтобы не висеть.
response=$(claude -p "$phrase" \
    --output-format json \
    --no-session-persistence \
    --disable-slash-commands \
    --append-system-prompt "$system_prompt" \
    </dev/null 2>/dev/null) || {
        echo "error: claude -p failed for phrase: $phrase" >&2
        exit 1
    }

# Извлекаем поля. .result — строка модели, .total_cost_usd — стоимость,
# .duration_ms — wall-clock.
result=$(echo "$response" | jq -r '.result // ""')
cost=$(echo "$response"   | jq -r '.total_cost_usd // 0')
duration=$(echo "$response" | jq -r '.duration_ms // 0')

# Парсим "SKILL: <name>". Принимаем варианты с пробелами вокруг :.
skill=$(echo "$result" | grep -oE 'SKILL[[:space:]]*:[[:space:]]*[a-zA-Z0-9_-]+' | head -1 | sed -E 's/SKILL[[:space:]]*:[[:space:]]*//')

if [[ -z "$skill" ]]; then
    echo "error: could not parse SKILL: <name> from response: $result" >&2
    exit 1
fi

# Если модель ответила «несколько через запятую» вопреки промпту —
# возьмём первый. Грубо, но в edge-cases видно по полю result в логе.
echo "$skill|$cost|$duration"
