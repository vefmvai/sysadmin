#!/usr/bin/env bash
# security-audit.sh — security-аудит сервера по чек-листу.
#
# Read-only — только проверки, ничего не меняет на сервере.
#
# Использование:
#   bash security-audit.sh \
#       --server <user>@<your-server> \
#       --scope all \
#       --domains-file inventory/shared/domains.md \
#       --output inventory/audits/$(date +%Y-%m-%d).md

set -uo pipefail

SERVER=""
SCOPE="all"
DOMAINS_FILE=""
OUTPUT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --server) SERVER="$2"; shift 2 ;;
        --scope) SCOPE="$2"; shift 2 ;;
        --domains-file) DOMAINS_FILE="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        *) echo "Неизвестный аргумент: $1"; exit 2 ;;
    esac
done

if [ -z "$SERVER" ]; then
    echo "Использование: $0 --server user@host [--scope host|docker|git|tls|all] [--domains-file ...] [--output report.md]"
    exit 2
fi

PASS=0; WARN=0; FAIL=0
RESULTS_HOST=()
RESULTS_DOCKER=()
RESULTS_GIT=()
RESULTS_TLS=()
RECOMMENDATIONS=()

# add_result CATEGORY STATUS CHECK_NAME DETAILS
add_result() {
    local CAT="$1" STATUS="$2" NAME="$3" DETAILS="$4"
    local LINE="| $NAME | $STATUS | $DETAILS |"
    case "$CAT" in
        host) RESULTS_HOST+=("$LINE") ;;
        docker) RESULTS_DOCKER+=("$LINE") ;;
        git) RESULTS_GIT+=("$LINE") ;;
        tls) RESULTS_TLS+=("$LINE") ;;
    esac
    case "$STATUS" in
        PASS) PASS=$((PASS + 1)) ;;
        WARN) WARN=$((WARN + 1)) ;;
        FAIL) FAIL=$((FAIL + 1)) ;;
    esac
}

# add_recommendation MESSAGE
add_recommendation() {
    RECOMMENDATIONS+=("$1")
}

# === HOST scope ===
if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "host" ]; then
    echo "[host] Проверка UFW, SSH, fail2ban, портов..."

    # UFW активен
    if ssh "$SERVER" "ufw status verbose 2>/dev/null | grep -q 'Status: active'"; then
        if ssh "$SERVER" "ufw status verbose 2>/dev/null | grep -q 'Default: deny (incoming)'"; then
            add_result host PASS "UFW активен и default deny" "Status: active, Default: deny incoming"
        else
            add_result host WARN "UFW активен, но default не deny" "Проверь Default policy"
            add_recommendation "[WARN] UFW Default policy не deny incoming — \`ufw default deny incoming\` (Yellow Zone)"
        fi
    else
        add_result host FAIL "UFW активен" "Status: inactive"
        add_recommendation "[FAIL] UFW неактивен — критичный риск, \`ufw enable\` после allow 22/80/443 (Yellow Zone)"
    fi

    # UFW allow только публичные порты
    EXTRA_PORTS=$(ssh "$SERVER" "ufw status numbered 2>/dev/null | grep 'ALLOW IN' | grep -vE '\(22|80|443)/(tcp|udp)' | grep -vE 'OpenSSH|Anywhere'" 2>/dev/null || echo "")
    if [ -z "$EXTRA_PORTS" ]; then
        add_result host PASS "UFW allow только 22/80/443" "Без неожиданных allow rules"
    else
        add_result host WARN "UFW allow содержит дополнительные порты" "$(echo "$EXTRA_PORTS" | head -1)"
        add_recommendation "[WARN] UFW открыты неожиданные порты — проверь, нужны ли они: $EXTRA_PORTS"
    fi

    # SSH PasswordAuthentication
    SSH_PWD=$(ssh "$SERVER" "grep -E '^PasswordAuthentication' /etc/ssh/sshd_config 2>/dev/null | tail -1" || echo "")
    if echo "$SSH_PWD" | grep -qiE 'no$'; then
        add_result host PASS "SSH PasswordAuthentication" "no"
    else
        add_result host FAIL "SSH PasswordAuthentication" "${SSH_PWD:-не задан явно (default может быть yes)}"
        add_recommendation "[FAIL] SSH разрешает пароли — \`sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config && sshd -t && systemctl reload ssh\` (Yellow Zone)"
    fi

    # SSH PermitRootLogin
    SSH_ROOT=$(ssh "$SERVER" "grep -E '^PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null | tail -1" || echo "")
    if echo "$SSH_ROOT" | grep -qiE '(no|prohibit-password)$'; then
        add_result host PASS "SSH PermitRootLogin" "${SSH_ROOT##*PermitRootLogin }"
    else
        add_result host WARN "SSH PermitRootLogin" "${SSH_ROOT:-default (может быть yes)}"
        add_recommendation "[WARN] SSH PermitRootLogin не ограничен — \`PermitRootLogin prohibit-password\` или \`no\` (Yellow Zone)"
    fi

    # fail2ban
    if ssh "$SERVER" "systemctl is-active fail2ban 2>/dev/null" | grep -q "^active$"; then
        if ssh "$SERVER" "fail2ban-client status sshd 2>/dev/null" | grep -q "Currently banned"; then
            BANNED=$(ssh "$SERVER" "fail2ban-client status sshd 2>/dev/null | grep 'Currently banned' | awk '{print \$NF}'" || echo "?")
            add_result host PASS "fail2ban active + sshd jail" "$BANNED IP сейчас в бане"
        else
            add_result host WARN "fail2ban active, но sshd jail отсутствует" "fail2ban-client status sshd → не отвечает"
            add_recommendation "[WARN] fail2ban активен, но sshd jail не настроен — добавь /etc/fail2ban/jail.d/sshd.conf"
        fi
    else
        add_result host FAIL "fail2ban active" "не запущен"
        add_recommendation "[FAIL] fail2ban не запущен — \`apt install fail2ban && systemctl enable --now fail2ban\` (Yellow Zone)"
    fi

    # unattended-upgrades — нет auto-reboot
    if ssh "$SERVER" "test -f /etc/apt/apt.conf.d/50unattended-upgrades"; then
        if ssh "$SERVER" "grep -E 'Unattended-Upgrade::Automatic-Reboot' /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null | grep -qE '\"false\"'"; then
            add_result host PASS "unattended-upgrades без auto-reboot" "Automatic-Reboot \"false\""
        else
            add_result host WARN "unattended-upgrades с auto-reboot или не задан" "проверь Automatic-Reboot"
            add_recommendation "[WARN] unattended-upgrades с auto-reboot — \`Automatic-Reboot \"false\"\` (внезапный ребут не нужен)"
        fi
    else
        add_result host WARN "unattended-upgrades" "не настроен"
        add_recommendation "[WARN] unattended-upgrades не настроен — security обновления не приходят автоматически"
    fi

    # Открытые внешние порты
    EXTERNAL_PORTS=$(ssh "$SERVER" "ss -tlnp 2>/dev/null | awk '\$4 ~ /^(0.0.0.0|\\*):/ && \$4 !~ /:(22|80|443)\$/ {print \$4}' | head -5" || echo "")
    if [ -z "$EXTERNAL_PORTS" ]; then
        add_result host PASS "Открытые внешние порты" "только 22/80/443"
    else
        add_result host WARN "Открытые внешние порты" "$(echo $EXTERNAL_PORTS | head -3)"
        add_recommendation "[WARN] Дополнительные порты слушают на 0.0.0.0 — проверь $EXTERNAL_PORTS, перевести на 127.0.0.1 если возможно"
    fi
fi

# === DOCKER scope ===
if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "docker" ]; then
    echo "[docker] Проверка daemon.json, .env permissions, внутренних UI..."

    # daemon.json
    if ssh "$SERVER" "test -f /etc/docker/daemon.json"; then
        if ssh "$SERVER" "grep -q 'insecure-registries' /etc/docker/daemon.json 2>/dev/null"; then
            add_result docker WARN "daemon.json без insecure-registries" "Содержит insecure-registries"
            add_recommendation "[WARN] Docker daemon.json содержит insecure-registries — проверь, нужно ли это (если внутренний registry — задокументируй в inventory/server.md)"
        else
            add_result docker PASS "daemon.json без insecure-registries" "OK"
        fi
    else
        add_result docker PASS "daemon.json" "default config (без insecure-registries)"
    fi

    # .env permissions
    BAD_ENV=$(ssh "$SERVER" "find /opt -maxdepth 3 -name '.env' -exec stat -c '%a %n' {} \; 2>/dev/null | grep -vE '^600 '" || echo "")
    if [ -z "$BAD_ENV" ]; then
        add_result docker PASS ".env permissions" "Все /opt/*/.env mode 600"
    else
        BAD_COUNT=$(echo "$BAD_ENV" | wc -l)
        add_result docker WARN ".env permissions" "$BAD_COUNT файлов с mode != 600"
        add_recommendation "[WARN] .env с лишними правами:\n$BAD_ENV\nИсправление: \`chmod 600 <file>\` (Yellow Zone, после backup)"
    fi
fi

# === GIT scope ===
if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "git" ]; then
    echo "[git] Проверка gitleaks и .gitignore..."

    # gitleaks (запускается локально на репо, не на сервере)
    if command -v gitleaks >/dev/null 2>&1; then
        if gitleaks detect --no-banner --log-opts='--all' >/dev/null 2>&1; then
            add_result git PASS "gitleaks scan (working tree + history)" "0 findings"
        else
            FINDINGS=$(gitleaks detect --no-banner --log-opts='--all' 2>&1 | grep -cE 'leaks found' || echo "?")
            add_result git FAIL "gitleaks scan" "Найдены утечки"
            add_recommendation "[FAIL] gitleaks нашёл секреты — запусти \`gitleaks detect --no-banner --log-opts='--all' --report-path report.json\` для деталей. Исправление: ротировать утёкшие секреты + git filter-repo для истории"
        fi
    else
        add_result git WARN "gitleaks scan" "gitleaks не установлен локально"
        add_recommendation "[WARN] gitleaks не установлен — \`brew install gitleaks\` или \`apt install gitleaks\` для возможности скана"
    fi

    # .gitignore
    if [ -f .gitignore ]; then
        MISSING=""
        for pattern in '\.env$' '\*\.key' '\*\.pem' 'secrets/'; do
            if ! grep -qE "$pattern" .gitignore; then
                MISSING="$MISSING $pattern"
            fi
        done
        if [ -z "$MISSING" ]; then
            add_result git PASS ".gitignore содержит security patterns" ".env, *.key, *.pem, secrets/"
        else
            add_result git WARN ".gitignore" "Отсутствуют:$MISSING"
            add_recommendation "[WARN] В .gitignore отсутствуют:$MISSING — добавь"
        fi
    fi
fi

# === TLS scope ===
if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "tls" ]; then
    echo "[tls] Проверка сертификатов..."

    if [ -n "$DOMAINS_FILE" ] && [ -f "$DOMAINS_FILE" ]; then
        DOMAINS=$(grep -oE '\b[a-z0-9.-]+\.(ru|com|tech|io|net|org)\b' "$DOMAINS_FILE" | sort -u)
        for domain in $DOMAINS; do
            EXPIRY=$(echo | openssl s_client -connect "$domain:443" -servername "$domain" 2>/dev/null \
                | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || echo "")
            if [ -z "$EXPIRY" ]; then
                add_result tls FAIL "$domain" "TLS не отвечает или сертификат битый"
                add_recommendation "[FAIL] $domain — TLS не работает, проверь nginx и acme.sh"
                continue
            fi

            EXPIRY_TS=$(date -j -f "%b %d %T %Y %Z" "$EXPIRY" +%s 2>/dev/null \
                || date -d "$EXPIRY" +%s 2>/dev/null || echo "0")
            NOW_TS=$(date +%s)
            DAYS=$(( (EXPIRY_TS - NOW_TS) / 86400 ))

            if [ "$DAYS" -lt 14 ]; then
                add_result tls FAIL "$domain" "$EXPIRY ($DAYS дней)"
                add_recommendation "[FAIL] $domain истекает через $DAYS дней — \`acme.sh --renew -d $domain --force\` срочно"
            elif [ "$DAYS" -lt 30 ]; then
                add_result tls WARN "$domain" "$EXPIRY ($DAYS дней)"
                add_recommendation "[WARN] $domain истекает через $DAYS дней — acme.sh должен обновить, проверь cron"
            else
                add_result tls PASS "$domain" "$EXPIRY ($DAYS дней)"
            fi
        done
    else
        echo "  (DOMAINS_FILE не задан или не существует — TLS-проверки пропущены)"
    fi
fi

# === Сборка отчёта ===
TS=$(date +%Y-%m-%d)
REPORT_FILE="${OUTPUT:-/tmp/security-audit-${TS}.md}"

{
    echo "# Security Audit — $TS"
    echo ""
    echo "**Сервер:** $SERVER"
    echo "**Scope:** $SCOPE"
    echo "**Сводка:** $PASS PASS / $WARN WARN / $FAIL FAIL"
    echo ""

    if [ ${#RESULTS_HOST[@]} -gt 0 ]; then
        echo "## Host"
        echo "| Проверка | Статус | Детали |"
        echo "|----------|--------|--------|"
        printf '%s\n' "${RESULTS_HOST[@]}"
        echo ""
    fi
    if [ ${#RESULTS_DOCKER[@]} -gt 0 ]; then
        echo "## Docker"
        echo "| Проверка | Статус | Детали |"
        echo "|----------|--------|--------|"
        printf '%s\n' "${RESULTS_DOCKER[@]}"
        echo ""
    fi
    if [ ${#RESULTS_GIT[@]} -gt 0 ]; then
        echo "## Git"
        echo "| Проверка | Статус | Детали |"
        echo "|----------|--------|--------|"
        printf '%s\n' "${RESULTS_GIT[@]}"
        echo ""
    fi
    if [ ${#RESULTS_TLS[@]} -gt 0 ]; then
        echo "## TLS"
        echo "| Домен | Статус | Дата истечения |"
        echo "|-------|--------|----------------|"
        printf '%s\n' "${RESULTS_TLS[@]}"
        echo ""
    fi
    if [ ${#RECOMMENDATIONS[@]} -gt 0 ]; then
        echo "## Рекомендации"
        local i=1
        for r in "${RECOMMENDATIONS[@]}"; do
            echo "$i. $r"
            i=$((i + 1))
        done
        echo ""
    fi
} > "$REPORT_FILE"

echo ""
echo "=== Аудит завершён ==="
echo "Сводка: $PASS PASS / $WARN WARN / $FAIL FAIL"
echo "Отчёт: $REPORT_FILE"
echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "ВНИМАНИЕ: найдены FAIL'ы — рассмотри как incident."
    exit 1
fi