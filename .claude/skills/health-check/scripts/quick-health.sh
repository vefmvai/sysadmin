#!/usr/bin/env bash
# quick-health.sh — smoke-режим скилла health-check (~10 секунд).
#
# Покрывает: docker ps, диск, RAM, возраст бэкапа (restic), HTTP-checks основных доменов.
# Не делает изменений на сервере — Green Zone.
#
# Параметры (через env):
#   MODE      = smoke | specific (full делегирует full-health.sh)
#   TARGET    = имя контейнера (для specific)
#   OUTPUT    = human | json
#   SSH_TARGET = SSH-алиас или user@ip; если пусто — выполняется локально
#
# Использование:
#   bash quick-health.sh
#   MODE=specific TARGET=<container-name> bash quick-health.sh
#   OUTPUT=json bash quick-health.sh

set -u  # без -e — даже если check упал, остальные продолжаем

MODE="${MODE:-smoke}"
TARGET="${TARGET:-all}"
OUTPUT="${OUTPUT:-human}"
SSH_TARGET="${SSH_TARGET:-}"

# Утилита запуска команды локально или по SSH
run() {
    if [ -n "$SSH_TARGET" ]; then
        ssh -o ConnectTimeout=5 -o BatchMode=yes "$SSH_TARGET" "$1" 2>/dev/null
    else
        bash -c "$1" 2>/dev/null
    fi
}

# Накопитель результатов: name|status|value
RESULTS=()

add_result() {
    RESULTS+=("$1|$2|$3")
}

# --- Pre-flight: SSH доступен? ---
if [ -n "$SSH_TARGET" ]; then
    if ! run "echo ok" >/dev/null; then
        echo "ERROR: не удалось подключиться к ${SSH_TARGET} (SSH timeout/refused)" >&2
        echo "Проверь VPN, IP в inventory/hosts/, ssh-ключ." >&2
        exit 1
    fi
fi

# --- Specific mode: фокус на одном контейнере ---
if [ "$MODE" = "specific" ]; then
    if [ "$TARGET" = "all" ]; then
        echo "ERROR: MODE=specific требует TARGET=<имя контейнера>" >&2
        echo "Список контейнеров:" >&2
        run "docker ps --format '{{.Names}}'" >&2
        exit 1
    fi
    if ! run "docker inspect $TARGET" >/dev/null; then
        echo "ERROR: контейнера '$TARGET' нет" >&2
        echo "Доступны:" >&2
        run "docker ps --format '{{.Names}}'" >&2
        exit 1
    fi
    STATE=$(run "docker inspect --format '{{.State.Status}}' $TARGET")
    HEALTH=$(run "docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' $TARGET")
    RESTARTS=$(run "docker inspect --format '{{.RestartCount}}' $TARGET")
    case "$STATE" in
        running)
            if [ "$HEALTH" = "unhealthy" ]; then
                add_result "container-$TARGET" "red" "running но unhealthy ($RESTARTS restarts)"
            elif [ "$RESTARTS" -gt 3 ] 2>/dev/null; then
                add_result "container-$TARGET" "yellow" "running, $RESTARTS restarts"
            else
                add_result "container-$TARGET" "green" "running, health=$HEALTH"
            fi
            ;;
        restarting)
            add_result "container-$TARGET" "red" "restart loop ($RESTARTS restarts)"
            ;;
        *)
            add_result "container-$TARGET" "red" "state=$STATE"
            ;;
    esac
fi

# --- Smoke checks (всегда) ---

# 1. docker ps — все ли контейнеры Up
PS_LINE=$(run "docker ps --format '{{.Names}}\t{{.Status}}'")
TOTAL_CT=$(echo "$PS_LINE" | grep -c .)
NOT_UP=$(echo "$PS_LINE" | grep -vE 'Up |^$' | grep -c . || true)
if [ "$TOTAL_CT" -eq 0 ]; then
    add_result "docker-ps" "red" "docker не отвечает или контейнеров нет"
elif [ "$NOT_UP" -eq 0 ]; then
    add_result "docker-ps" "green" "$TOTAL_CT/$TOTAL_CT running"
elif [ "$NOT_UP" -le 1 ]; then
    add_result "docker-ps" "yellow" "$((TOTAL_CT - NOT_UP))/$TOTAL_CT running, $NOT_UP problem"
else
    add_result "docker-ps" "red" "$((TOTAL_CT - NOT_UP))/$TOTAL_CT running, $NOT_UP problem"
fi

# 2. Disk
DISK_PCT=$(run "df -h / | awk 'NR==2 {gsub(\"%\",\"\",\$5); print \$5}'")
if [ -n "$DISK_PCT" ]; then
    if [ "$DISK_PCT" -lt 70 ]; then
        add_result "disk" "green" "${DISK_PCT}%"
    elif [ "$DISK_PCT" -lt 85 ]; then
        add_result "disk" "yellow" "${DISK_PCT}%"
    else
        add_result "disk" "red" "${DISK_PCT}%"
    fi
else
    add_result "disk" "red" "не удалось прочитать df"
fi

# 3. RAM
RAM_PCT=$(run "free -m | awk '/Mem:/ {print int(\$3*100/\$2)}'")
if [ -n "$RAM_PCT" ]; then
    if [ "$RAM_PCT" -lt 70 ]; then
        add_result "ram" "green" "${RAM_PCT}%"
    elif [ "$RAM_PCT" -lt 90 ]; then
        add_result "ram" "yellow" "${RAM_PCT}%"
    else
        add_result "ram" "red" "${RAM_PCT}%"
    fi
else
    add_result "ram" "red" "не удалось прочитать free"
fi

# 4. Возраст бэкапа (restic)
if run "command -v restic" >/dev/null && [ -n "${RESTIC_REPOSITORY:-}" ]; then
    LAST_BACKUP_ISO=$(run "restic snapshots --latest 1 --json 2>/dev/null | jq -r '.[0].time // empty'")
    if [ -n "$LAST_BACKUP_ISO" ]; then
        BACKUP_AGE_HOURS=$(run "echo \$(( ( \$(date -u +%s) - \$(date -u -d '$LAST_BACKUP_ISO' +%s) ) / 3600 ))")
        if [ "$BACKUP_AGE_HOURS" -lt 12 ]; then
            add_result "backup" "green" "${BACKUP_AGE_HOURS}ч назад"
        elif [ "$BACKUP_AGE_HOURS" -lt 36 ]; then
            add_result "backup" "yellow" "${BACKUP_AGE_HOURS}ч назад"
        else
            add_result "backup" "red" "${BACKUP_AGE_HOURS}ч назад"
        fi
    else
        add_result "backup" "yellow" "restic есть, но snapshots не читаются"
    fi
else
    add_result "backup" "yellow" "restic не настроен — см. setup-backups"
fi

# 5. HTTP-checks основных доменов из inventory/shared/domains.md (если файл локально)
DOMAINS_FILE="inventory/shared/domains.md"
if [ -f "$DOMAINS_FILE" ]; then
    # Берём первые 5 доменов вида `example.com` из файла (грубое извлечение)
    DOMAINS=$(grep -oE '[a-z0-9][a-z0-9.-]+\.[a-z]{2,}' "$DOMAINS_FILE" | sort -u | head -5)
    for D in $DOMAINS; do
        CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "https://$D" 2>/dev/null || echo "000")
        case "$CODE" in
            2*|3*) add_result "http-$D" "green" "$CODE" ;;
            4*)    add_result "http-$D" "yellow" "$CODE" ;;
            5*|000) add_result "http-$D" "red" "$CODE" ;;
            *)     add_result "http-$D" "yellow" "$CODE" ;;
        esac
    done
fi

# --- Output ---

# Подсчёт overall: red если хоть один red, иначе yellow если хоть один yellow, иначе green
overall_status() {
    local has_red=0 has_yellow=0
    for R in "${RESULTS[@]}"; do
        case "$(echo "$R" | cut -d'|' -f2)" in
            red)    has_red=1 ;;
            yellow) has_yellow=1 ;;
        esac
    done
    if [ $has_red -eq 1 ]; then echo "red"
    elif [ $has_yellow -eq 1 ]; then echo "yellow"
    else echo "green"
    fi
}

OVERALL=$(overall_status)
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

if [ "$OUTPUT" = "json" ]; then
    printf '{\n'
    printf '  "timestamp": "%s",\n' "$TS"
    printf '  "mode": "%s",\n' "$MODE"
    printf '  "overall": "%s",\n' "$OVERALL"
    printf '  "checks": [\n'
    local_first=1
    for R in "${RESULTS[@]}"; do
        NAME=$(echo "$R" | cut -d'|' -f1)
        STATUS=$(echo "$R" | cut -d'|' -f2)
        VALUE=$(echo "$R" | cut -d'|' -f3)
        if [ $local_first -eq 1 ]; then local_first=0; else printf ',\n'; fi
        printf '    {"name": "%s", "status": "%s", "value": "%s"}' "$NAME" "$STATUS" "$VALUE"
    done
    printf '\n  ]\n}\n'
else
    DATE_HUMAN=$(date '+%Y-%m-%d %H:%M')
    case "$OVERALL" in
        green)  echo "=== Health Check (${MODE}) — ${DATE_HUMAN} ===" ;;
        yellow) echo "=== Health Check (${MODE}) — ${DATE_HUMAN} === [YELLOW]" ;;
        red)    echo "=== Health Check (${MODE}) — ${DATE_HUMAN} === [RED]" ;;
    esac
    for R in "${RESULTS[@]}"; do
        NAME=$(echo "$R" | cut -d'|' -f1)
        STATUS=$(echo "$R" | cut -d'|' -f2)
        VALUE=$(echo "$R" | cut -d'|' -f3)
        case "$STATUS" in
            green)  ICON="GREEN " ;;
            yellow) ICON="YELLOW" ;;
            red)    ICON="RED   " ;;
        esac
        printf '%s | %-25s %s\n' "$ICON" "$NAME" "$VALUE"
    done
    echo ""
    if [ "$OVERALL" != "green" ]; then
        echo "Рекомендации:"
        for R in "${RESULTS[@]}"; do
            NAME=$(echo "$R" | cut -d'|' -f1)
            STATUS=$(echo "$R" | cut -d'|' -f2)
            VALUE=$(echo "$R" | cut -d'|' -f3)
            case "$NAME:$STATUS" in
                disk:red)    echo "- diskFull: см. runbooks/disk-full.md (Yellow Zone)" ;;
                ram:red)     echo "- ramEmergency: см. runbooks/ram-emergency.md" ;;
                backup:red)  echo "- бэкап несвежий: проверь cron 'backup-all-dbs' и логи restic" ;;
                http-*:red)  echo "- ${NAME#http-}: HTTP $VALUE — проверь nginx + контейнер сервиса" ;;
                container-*:red) echo "- ${NAME#container-}: $VALUE — 'docker logs --tail=200 \"${NAME#container-}\"'" ;;
            esac
        done
    fi
fi

# Exit code: 0 если green, 1 если yellow, 2 если red — удобно для cron/CI
case "$OVERALL" in
    green)  exit 0 ;;
    yellow) exit 1 ;;
    red)    exit 2 ;;
esac
