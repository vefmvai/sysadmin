#!/usr/bin/env bash
# parse-triggers.sh — извлекает фразы из evals/triggers.md в plain-text формат.
#
# Использование:
#   ./parse-triggers.sh <path-to-triggers.md>
#
# Вывод:
#   TSV-строки: <kind>\t<phrase>
#   где kind = positive | negative | edge
#   phrase — текст без кавычек-ёлочек, без буллита, без «→ ...» (для negative
#   режется только до стрелки, ожидаемое поведение в TSV не идёт — оно
#   справочное для человека).
#
# Дизайн: парсер — простой awk, без зависимостей. Формат triggers.md по
# ADR-0004 §2 предсказуем: H2-заголовки маркируют секции, каждая фраза —
# буллит-строка вида `- «фраза»` или `- «фраза» — пояснение → альтернатива`.

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <path-to-triggers.md>" >&2
    exit 2
fi

file="$1"
if [[ ! -f "$file" ]]; then
    echo "error: file not found: $file" >&2
    exit 1
fi

awk '
    BEGIN { section = "" }

    # Маркеры секций — H2 заголовки
    /^## ДОЛЖНО триггерить/      { section = "positive"; next }
    /^## НЕ ДОЛЖНО триггерить/   { section = "negative"; next }
    /^## Edge-cases/              { section = "edge"; next }

    # Игнорируем не-буллит строки и пустые
    /^[[:space:]]*$/ { next }
    !/^- / { next }

    {
        if (section == "") next

        # Удалить начальный "- "
        line = substr($0, 3)

        # Извлечь содержимое первых кавычек «...»
        # Шаблон: «...» — всё, что между первой парой ёлочек
        if (match(line, /«[^»]+»/)) {
            phrase = substr(line, RSTART + 2, RLENGTH - 4)
            print section "\t" phrase
        }
    }
' "$file"
