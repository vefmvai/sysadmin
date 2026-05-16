#!/usr/bin/env bash
# rollback.sh — откат сервиса на предыдущий git ref за <5 мин.
#
# Паттерн: тот же push-to-pull (ADR 0015 проекта-носителя или эквивалент),
# но вместо `git pull --ff-only` делаем
# `git checkout <prev-sha>` на сервере, затем `docker compose up -d <service>`.
#
# Использование:
#   bash .claude/skills/deploy-service/scripts/rollback.sh <SERVICE_NAME> <PREV_SHA>
#
# Пример:
#   bash .claude/skills/deploy-service/scripts/rollback.sh my-dashboard a1b2c3d
#
# Перед запуском оператор должен подтвердить через type-to-confirm в чате.

set -euo pipefail

SERVICE_NAME="${1:-}"
PREV_SHA="${2:-}"
# SERVER — SSH-алиас сервера из ~/.ssh/config (например, `prod`).
# REMOTE_DIR — путь к инфра-репо (стандартное соглашение `/opt/infra/`).
SERVER="${SERVER:?SERVER не задан — укажите SSH-алиас из ~/.ssh/config}"
REMOTE_DIR="${REMOTE_DIR:-/opt/infra}"

if [ -z "$SERVICE_NAME" ] || [ -z "$PREV_SHA" ]; then
    echo "Использование: $0 <SERVICE_NAME> <PREV_SHA>" >&2
    echo "" >&2
    echo "Чтобы найти PREV_SHA — последние 10 коммитов сервиса:" >&2
    echo "  git log --oneline -10 -- services/<SERVICE_NAME>/" >&2
    exit 1
fi

# Валидация: SHA выглядит как git ref (минимум 7 hex)
if ! [[ "$PREV_SHA" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
    echo "ERROR: PREV_SHA '$PREV_SHA' не похож на git SHA (нужно 7-40 hex символов)." >&2
    exit 1
fi

# Валидация: SHA существует в репо
if ! git cat-file -e "$PREV_SHA^{commit}" 2>/dev/null; then
    echo "ERROR: коммит $PREV_SHA не найден локально." >&2
    echo "Запусти: git fetch origin main, затем повтори." >&2
    exit 1
fi

echo "[rollback] Откат сервиса '$SERVICE_NAME' на $PREV_SHA"
echo "[rollback] Текущий HEAD на сервере → этот SHA"
echo ""

# Текущий ref для возможного дальнейшего отката
CURRENT_HEAD=$(ssh "$SERVER" "cd $REMOTE_DIR && git rev-parse HEAD")
echo "[rollback] Записываю текущий HEAD как страховку: ${CURRENT_HEAD:0:8}"
echo ""

# Выполняем rollback на сервере.
# Heredoc намеренно без кавычек на EOF: переменные $REMOTE_DIR, $PREV_SHA,
# $SERVICE_NAME раскрываются ЛОКАЛЬНО перед отправкой по SSH (на сервере
# их нет в окружении). Это безопасно: значения провалидированы выше
# (regex для PREV_SHA, обязательность SERVER/SERVICE_NAME).
# shellcheck disable=SC2087
ssh "$SERVER" bash -s <<EOF
set -euo pipefail
cd "$REMOTE_DIR"

# Detach HEAD на нужный коммит — без force и без потери истории
git fetch origin main --quiet
git checkout "$PREV_SHA"

# Селективный up -d только для нужного сервиса
if [ -d "services/$SERVICE_NAME" ]; then
    cd "services/$SERVICE_NAME"
    docker compose up -d "$SERVICE_NAME" || docker compose up -d
else
    echo "WARN: services/$SERVICE_NAME не существует на этом ref — возможно, сервис добавили позже"
    exit 1
fi
EOF

echo ""
echo "[rollback] Команда выполнена."
echo "[rollback] СЕЙЧАС: запусти smoke-test для $SERVICE_NAME (Шаг 6 SKILL.md)."
echo "[rollback] Если откат удался → коммит revert в репо:"
echo "           git revert <SHA-плохого-коммита> && git push"
echo "[rollback] Если откат не помог → дальнейший откат на ${CURRENT_HEAD:0:8}+1 (предыдущий) либо forward-fix."