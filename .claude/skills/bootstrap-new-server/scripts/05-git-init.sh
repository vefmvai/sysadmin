#!/usr/bin/env bash
# 05-git-init.sh — создаёт структуру /opt/, инициализирует git-репозиторий в $INFRA_DIR
# с .gitignore, pre-commit hook gitleaks, шаблонами ADR/runbook/incident, заглушкой inventory/.
# Идемпотентный — повторный запуск не пересоздаёт уже существующие файлы.
#
# Запуск:
#   ADMIN_USER=deploy INFRA_DIR=/opt/infra bash 05-git-init.sh
#
# Скрипт сам найдёт templates/ рядом со своим расположением (если запускается из скилла напрямую),
# либо примет встроенные fallback-шаблоны из heredoc'ов внутри.

set -euo pipefail

: "${ADMIN_USER:?ADMIN_USER required}"
: "${INFRA_DIR:=/opt/infra}"

echo "[05-git-init] ADMIN_USER=$ADMIN_USER  INFRA_DIR=$INFRA_DIR"

# --- 1. /opt/ структура ---
echo "[05] Создаю структуру /opt/"
sudo install -d -m 0755 -o "$ADMIN_USER" -g "$ADMIN_USER" \
    /opt/monitoring \
    /opt/admin-panel \
    /opt/shared-db \
    /opt/apps

# --- 2. INFRA_DIR ---
sudo install -d -m 0755 -o "$ADMIN_USER" -g "$ADMIN_USER" "$INFRA_DIR"

# --- 3. git init (если ещё нет) ---
if [ ! -d "$INFRA_DIR/.git" ]; then
    cd "$INFRA_DIR"
    git init -q -b main
    echo "[05] git init выполнен в $INFRA_DIR"
else
    echo "[05] $INFRA_DIR уже git-репозиторий — пропускаю init"
fi

# --- 4. .gitignore ---
GITIGNORE="$INFRA_DIR/.gitignore"
if [ ! -f "$GITIGNORE" ]; then
    cat > "$GITIGNORE" <<'EOF'
# Секреты — НИКОГДА в git
.env
.env.local
.env.production
*.key
*.pem
*.crt
authorized_keys
id_rsa*
id_ed25519*

# Снимки сервера — большие, локальные, генерируются скриптом
inventory/snapshots/

# OS / IDE
.DS_Store
Thumbs.db
.vscode/
.idea/
*.swp
*~

# Логи
*.log
logs/

# Бэкапы из инструментов
*.bak
*.backup
EOF
    echo "[05] $GITIGNORE создан"
else
    echo "[05] $GITIGNORE уже есть — пропускаю"
fi

# --- 5. pre-commit hook gitleaks ---
HOOK="$INFRA_DIR/.git/hooks/pre-commit"
if [ ! -f "$HOOK" ]; then
    cat > "$HOOK" <<'EOF'
#!/usr/bin/env bash
# pre-commit hook: блокирует коммит, если gitleaks нашёл секреты.
# Если gitleaks не установлен — выводит warning, но НЕ блокирует коммит
# (чтобы новый оператор не застрял на старте).

set -e

if ! command -v gitleaks &>/dev/null; then
    echo "[pre-commit] WARNING: gitleaks не установлен. Пропускаю проверку."
    echo "[pre-commit] Установи: https://github.com/gitleaks/gitleaks#installing"
    exit 0
fi

echo "[pre-commit] gitleaks: проверяю staged-файлы..."
gitleaks protect --staged --redact -v
EOF
    chmod +x "$HOOK"
    echo "[05] pre-commit hook gitleaks установлен в $HOOK"
else
    echo "[05] $HOOK уже есть — пропускаю"
fi

# --- 6. Шаблоны: decisions/, incidents/, runbooks/, inventory/ ---
mkdir -p "$INFRA_DIR/decisions" "$INFRA_DIR/incidents" "$INFRA_DIR/runbooks" "$INFRA_DIR/inventory"

if [ ! -f "$INFRA_DIR/decisions/0000-template.md" ]; then
    cat > "$INFRA_DIR/decisions/0000-template.md" <<'EOF'
# ADR 0000: Шаблон architectural decision record

## Status
Template (не реальное решение)

## Context
Что заставило принять это решение? Какие силы действовали?

## Decision
Что решили?

## Consequences
- (+) Что выигрывает.
- (-) Что теряем / какие риски.
- (?) Что ещё непонятно — и когда вернёмся проверить.

## Альтернативы (если рассматривали)
- Вариант A — почему отвергли.
- Вариант B — почему отвергли.
EOF
    echo "[05] decisions/0000-template.md создан"
fi

if [ ! -f "$INFRA_DIR/incidents/_template.md" ]; then
    cat > "$INFRA_DIR/incidents/_template.md" <<'EOF'
# Инцидент YYYY-MM-DD: <короткое описание>

## Что произошло
<факты: что сломалось, когда, какие сервисы затронуты, длительность>

## Что сделали
1. <шаг 1>
2. <шаг 2>

## Урок
<что изменим в персоне / runbook / мониторинге, чтобы не повторилось>
EOF
    echo "[05] incidents/_template.md создан"
fi

if [ ! -f "$INFRA_DIR/runbooks/00-template.md" ]; then
    cat > "$INFRA_DIR/runbooks/00-template.md" <<'EOF'
# Runbook 00: <название процедуры>

**Когда запускать:** <триггер>
**Кто запускает:** <agent / оператор / cron>
**Зона риска:** Зелёная / Жёлтая / Красная

## Pre-conditions
- [ ] ...

## Шаги
1. ...
2. ...

## Verify
- ...

## Rollback (если что-то пошло не так)
- ...

**Last verified:** YYYY-MM-DD
EOF
    echo "[05] runbooks/00-template.md создан"
fi

if [ ! -f "$INFRA_DIR/inventory/README.md" ]; then
    cat > "$INFRA_DIR/inventory/README.md" <<'EOF'
# Inventory

Здесь живёт документация по живой инфраструктуре сервера.

Файлы заполняются по мере обнаружения скиллом `inventory-scan` или вручную.

- `hosts/` — описание физических/виртуальных серверов.
- `services.md` — список запущенных сервисов и контейнеров.
- `databases.md` — БД, их версии, пользователи (без паролей!).
- `domains.md` — домены и куда они резолвятся.
- `networks.md` — Docker-сети, изоляция, кто куда подключён.
- `volumes.md` — Docker volumes и куда монтируются.
- `cron.md` — задачи cron на хосте и в контейнерах.
- `host-scripts.md` — скрипты на хосте (вне контейнеров).
- `access.md` — реестр секретов (только имена и где лежат, БЕЗ значений).

Снимки сервера (`snapshots/`) НЕ коммитятся — генерируются локально dump-скриптом.
EOF
    echo "[05] inventory/README.md создан"
fi

# --- 7. Первый коммит (если ещё нет коммитов) ---
cd "$INFRA_DIR"
chown -R "$ADMIN_USER:$ADMIN_USER" "$INFRA_DIR"

if ! git log --oneline -1 &>/dev/null 2>&1; then
    sudo -u "$ADMIN_USER" git -C "$INFRA_DIR" config user.email "${ADMIN_USER}@$(hostname)"
    sudo -u "$ADMIN_USER" git -C "$INFRA_DIR" config user.name "$ADMIN_USER"
    sudo -u "$ADMIN_USER" git -C "$INFRA_DIR" add .
    sudo -u "$ADMIN_USER" git -C "$INFRA_DIR" commit -q -m "chore: bootstrap infra repo (gitignore + hooks + templates)"
    echo "[05] Первичный коммит создан"
else
    echo "[05] В $INFRA_DIR уже есть коммиты — пропускаю"
fi

# --- 8. Verify ---
echo ""
echo "[05] Содержимое $INFRA_DIR:"
ls -la "$INFRA_DIR"
echo ""
echo "[05] Git log:"
git -C "$INFRA_DIR" log --oneline -5 2>/dev/null || echo "(пусто)"
echo ""
echo "[05] OK — $INFRA_DIR готов: .gitignore + pre-commit hook + шаблоны + первый коммит."