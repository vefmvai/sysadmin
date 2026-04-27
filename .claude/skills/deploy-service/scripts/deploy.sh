#!/usr/bin/env bash
# deploy.sh — обёртка для запуска push-to-pull deploy из скилла deploy-service.
#
# Делегирует основной работе scripts/deploy/deploy-remote.sh инфра-репо
# (push-to-pull паттерн — ADR 0015 проекта-носителя или эквивалент).
# Этот файл в скилле — для self-contained вызова, чтобы агенту не приходилось
# помнить точный путь к рабочему скрипту.
#
# Использование:
#   bash .claude/skills/deploy-service/scripts/deploy.sh
#   SERVICE_NAME=my-app bash .claude/skills/deploy-service/scripts/deploy.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/deploy/deploy-remote.sh"

if [ ! -x "$TARGET_SCRIPT" ]; then
    echo "ERROR: $TARGET_SCRIPT не найден или не исполняемый." >&2
    echo "Проверь: репо infra клонировано полностью? scripts/deploy/deploy-remote.sh существует?" >&2
    exit 1
fi

cd "$REPO_ROOT"

echo "[deploy-service] Запускаю scripts/deploy/deploy-remote.sh..."
echo "[deploy-service] Подробности паттерна: ADR 0015 проекта-носителя"
echo "                 (decisions/0015-iac-deploy-model.md) или эквивалентное решение."
echo ""

exec "$TARGET_SCRIPT" "$@"