#!/usr/bin/env bash
# deploy-remote.sh (скилл-копия) — pre-flight + SSH-триггер серверного deploy.sh.
#
# Это self-contained копия scripts/deploy/deploy-remote.sh для случаев, когда нужно
# запустить деплой из скилла без зависимости от структуры репо. В рабочем процессе
# предпочтительнее использовать оригинал scripts/deploy/deploy-remote.sh — этот файл
# поддерживается как страховка.
#
# Паттерн: push-to-pull manual deploy — ADR 0015 проекта-носителя
# или эквивалентное решение.

set -euo pipefail

# SERVER — SSH-алиас сервера из ~/.ssh/config (имя оператор выбирает сам:
# `prod`, `production`, `infra` и т.п.); REMOTE_DIR — путь к инфра-репо
# (стандартное соглашение `/opt/infra/`, конфигурируется через env).
SERVER="${SERVER:?SERVER не задан — укажите SSH-алиас из ~/.ssh/config (например, prod)}"
REMOTE_DIR="${REMOTE_DIR:-/opt/infra}"

echo "[deploy-remote-skill] Pre-flight: проверка синхронизации с GitHub..."
git fetch origin main --quiet

LOCAL_HEAD=$(git rev-parse main)
ORIGIN_HEAD=$(git rev-parse origin/main)

if [ "$LOCAL_HEAD" != "$ORIGIN_HEAD" ]; then
    echo ""
    echo "ERROR: local main ($LOCAL_HEAD) != origin/main ($ORIGIN_HEAD)." >&2
    echo "Сначала: git push origin main" >&2
    echo "Затем повторить деплой." >&2
    exit 1
fi

# Working tree чистый
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "ERROR: есть незакоммиченные изменения. Сначала git commit + push." >&2
    git status --short >&2
    exit 1
fi

echo "[deploy-remote-skill] Локальный main синхронизирован: ${LOCAL_HEAD:0:8}"
echo "[deploy-remote-skill] Триггер на $SERVER:$REMOTE_DIR ..."
echo ""

ssh "$SERVER" "cd $REMOTE_DIR && ./deploy.sh"

echo ""
echo "[deploy-remote-skill] Готово. Запусти smoke-test (см. SKILL.md Шаг 6)."