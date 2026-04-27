#!/usr/bin/env bash
# .claude/skills/inventory-scan/scripts/dump-snapshot.sh
#
# Bundled-копия v2 dump-скрипта инвентаризации сервера. Снимает read-only снимок
# состояния: контейнеры, compose-файлы, сети, тома, ресурсы хоста, cron, nginx,
# TLS-сертификаты, host-scripts, .env (redacted), systemd-юниты, доступные апдейты.
#
# Использование:
#   bash dump-snapshot.sh <SERVER> [DATE] [INVENTORY_DIR]
#
# SERVER — обязательный параметр (защита от случайного захода на чужой сервер):
#   user@host  или  SSH-алиас из ~/.ssh/config  или  `local`.
#
# Примеры:
#   bash dump-snapshot.sh local                          # локальная машина (без SSH)
#   bash dump-snapshot.sh root@<your-server-ip>          # по IP
#   bash dump-snapshot.sh prod                           # SSH-алиас из ~/.ssh/config
#   bash dump-snapshot.sh root@10.0.0.1 2026-01-01       # произвольный сервер и дата
#   bash dump-snapshot.sh prod today /tmp/inv            # альтернативный INVENTORY_DIR
#
# Создаёт ~14 файлов в ${INVENTORY_DIR}/hosts/<HOST_DIR>/snapshots/<DATE>/
# (containers, networks, volumes, host-resources, crontab, nginx-sites, tls-certs,
#  host-scripts-list, host-scripts-content, host-env-redacted, cron-d-content,
#  systemd-enabled, compose-files, containers-inspect.json, meta.txt).

set -euo pipefail

# SERVER — обязательный аргумент. Без него — fail-fast с подсказкой,
# чтобы ученик случайно не пошёл на чужой сервер.
if [ "$#" -lt 1 ]; then
    echo "ERROR: SERVER не задан." >&2
    echo "Использование: bash dump-snapshot.sh <SERVER> [DATE] [INVENTORY_DIR]" >&2
    echo "  SERVER — user@host / SSH-алиас / 'local'." >&2
    exit 2
fi

SERVER="$1"
DATE="${2:-$(date +%Y-%m-%d)}"
INVENTORY_DIR="${3:-${INVENTORY_DIR:-inventory}}"

# === Определение имени хоста для пути ===
if [ "$SERVER" = "local" ]; then
    HOST_DIR="local-$(hostname -s)"
else
    # user@1.2.3.4   -> prod-1.2.3.4
    # user@hostname  -> prod-hostname
    # ssh-alias      -> prod-ssh-alias
    HOST_IP="${SERVER#*@}"
    HOST_DIR="prod-${HOST_IP}"
fi

SNAPSHOT_DIR="${INVENTORY_DIR}/hosts/${HOST_DIR}/snapshots/${DATE}"

echo "======================================================"
echo "dump-snapshot.sh — снимок сервера (bundled v2)"
echo "Сервер:        ${SERVER}"
echo "Хост-dir:      ${HOST_DIR}"
echo "Inventory dir: ${INVENTORY_DIR}"
echo "Папка снимка:  ${SNAPSHOT_DIR}"
echo "======================================================"

# === Блок проверки предусловий ===
echo ""
echo "Проверка предусловий..."

if [ "$SERVER" = "local" ]; then
    # Локальный режим — без SSH
    if ! command -v docker &>/dev/null; then
        echo ""
        echo "ОШИБКА: Docker не найден на локальной машине."
        echo "Установи Docker: https://docs.docker.com/engine/install/"
        exit 1
    fi
    echo "  [OK] Docker доступен локально"
    echo "  [OK] Режим: локальный (без SSH)"
    run_cmd() { eval "$1"; }
else
    # Удалённый режим — через SSH

    # 1. Проверка SSH-доступа
    if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "$SERVER" 'echo ok' >/dev/null 2>&1; then
        echo ""
        echo "ОШИБКА: Не удалось подключиться к ${SERVER} по SSH."
        echo ""
        echo "Проверь:"
        echo "  1. Сервер включён и доступен по сети"
        echo "  2. SSH-ключ настроен: ssh-copy-id ${SERVER}"
        echo "  3. Нет блокировки по firewall (порт 22 открыт)"
        echo "  4. Правильный пользователь в адресе (root@...)"
        exit 1
    fi
    echo "  [OK] SSH-доступ к ${SERVER} есть"

    # 2. Проверка Docker на сервере
    if ! ssh -o ConnectTimeout=10 "$SERVER" 'command -v docker' >/dev/null 2>&1; then
        echo ""
        echo "ОШИБКА: Docker не найден на сервере ${SERVER}."
        echo "Docker не установлен — снимок контейнеров невозможен."
        echo "Установи Docker: https://docs.docker.com/engine/install/"
        exit 1
    fi
    echo "  [OK] Docker найден на сервере"

    # 3. Проверка версии bash на сервере (мягкое предупреждение)
    REMOTE_BASH_VER=$(ssh -o ConnectTimeout=10 "$SERVER" \
        'bash --version 2>/dev/null | head -1 | grep -oE "version [0-9]+" | grep -oE "[0-9]+"' \
        2>/dev/null || echo "0")
    if [ "${REMOTE_BASH_VER:-0}" -lt 4 ] 2>/dev/null; then
        echo "  [WARN] bash < 4 на сервере (версия: ${REMOTE_BASH_VER}). Скрипт продолжит."
    else
        echo "  [OK] bash >= 4 на сервере"
    fi

    echo "  [OK] Предусловия пройдены. Режим: SSH"
    run_cmd() { ssh -o ConnectTimeout=10 "$SERVER" "$1"; }
fi

# === Создаём папку снимка ===
mkdir -p "$SNAPSHOT_DIR"

# === Вспомогательная функция записи секции ===
# run_remote <имя_файла> <команда>
run_remote() {
    local label="$1"
    local cmd="$2"
    local outfile="${SNAPSHOT_DIR}/${label}"
    echo "  -> ${label}..."
    if ! run_cmd "$cmd" > "$outfile" 2>&1; then
        echo "     ПРЕДУПРЕЖДЕНИЕ: не удалось выполнить ${label}"
        echo "ERROR: ${cmd}" >> "$outfile"
    fi
}

# === Заголовочный файл meta.txt ===
echo "  -> meta.txt..."
cat > "${SNAPSHOT_DIR}/meta.txt" <<METATXT
snapshot_date: ${DATE}
snapshot_time: $(date -u +%Y-%m-%dT%H:%M:%SZ)
server: ${SERVER}
host_dir: ${HOST_DIR}
inventory_dir: ${INVENTORY_DIR}
taken_by: $(whoami)
script_version: bundled-v2
METATXT

# === 14 контентных файлов снимка ===

# 1. Список контейнеров
run_remote "containers.txt" \
    "docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'"

# 2. Полный inspect всех контейнеров (env, mounts, networks)
run_remote "containers-inspect.json" \
    "docker ps -a -q | xargs docker inspect 2>/dev/null || echo '[]'"

# 3. Список compose-файлов на сервере
run_remote "compose-files.txt" \
    "find /opt -name 'docker-compose.yml' -o -name 'docker-compose.yaml' 2>/dev/null | sort"

# 4. Docker-сети
run_remote "networks.txt" \
    "docker network ls && echo '---' && docker network ls -q | xargs docker network inspect --format '{{.Name}}: {{.IPAM.Config}}' 2>/dev/null"

# 5. Docker-тома
run_remote "volumes.txt" \
    "docker volume ls && echo '---' && docker system df -v 2>/dev/null"

# 6. Ресурсы хоста (uptime, память, диск, порты, обновления APT)
run_remote "host-resources.txt" \
    "echo '=== uptime ===' && uptime && echo '=== память ===' && free -h && echo '=== диск ===' && df -h && echo '=== открытые порты ===' && (ss -tulpn 2>/dev/null || netstat -tulpn 2>/dev/null || echo 'ss/netstat не найден') && echo '=== доступные обновления APT ===' && (apt list --upgradable 2>/dev/null | head -50 || echo 'apt не найден')"

# 7. Cron-задачи
run_remote "crontab.txt" \
    "echo '=== crontab root ===' && (crontab -l 2>/dev/null || echo 'пусто') && echo '=== /etc/cron.d/ ===' && (ls -la /etc/cron.d/ 2>/dev/null || echo 'пусто') && (cat /etc/cron.d/* 2>/dev/null || echo 'пусто')"

# 8. Nginx-конфигурация
run_remote "nginx-sites.txt" \
    "nginx -T 2>/dev/null || (echo '--- sites-enabled ---' && ls -la /etc/nginx/sites-enabled/ 2>/dev/null && cat /etc/nginx/sites-enabled/* 2>/dev/null) || echo 'nginx не найден'"

# 9. TLS-сертификаты Let's Encrypt и их даты — с set +e вокруг openssl
#    (фикс v2: v1 валился на специальных символах в путях)
run_remote "tls-certs.txt" \
    "set +e; find /etc/letsencrypt/live -name 'cert.pem' 2>/dev/null | while read f; do echo \"=== \$f ===\"; openssl x509 -in \"\$f\" -noout -subject -dates 2>/dev/null; done; ls -la ~/.acme.sh/*/fullchain.cer 2>/dev/null | head -50; true"

# 10. Список хостовых скриптов (метаданные, без содержимого)
run_remote "host-scripts-list.txt" \
    "ls -la /opt/*.sh /opt/*.py /opt/*.yml 2>/dev/null; ls -la /usr/local/bin/*.sh /usr/local/sbin/*.sh 2>/dev/null; ls -la /root/bin/ 2>/dev/null"

# 11. Содержимое хостовых скриптов в /opt (.sh)
run_remote "host-scripts-content.txt" \
    'for f in /opt/*.sh; do
  [ -f "$f" ] || continue
  echo "=== $f ==="
  echo "--- metadata ---"
  stat -c "%a %U:%G %s bytes modified %y" "$f"
  echo "--- content ---"
  cat "$f"
  echo ""
done'

# 12. Структура .env файлов на хосте (имена переменных, значения redacted)
run_remote "host-env-redacted.txt" \
    'for f in /opt/*.env; do
  [ -f "$f" ] || continue
  echo "=== $f ==="
  echo "--- metadata ---"
  stat -c "%a %U:%G %s bytes modified %y" "$f"
  echo "--- variable names (values redacted) ---"
  sed "s/=.*/=<HIDDEN>/" "$f"
  echo ""
done'

# 13. Содержимое /etc/cron.d/ и периодических директорий
run_remote "cron-d-content.txt" \
    'for f in /etc/cron.d/* /etc/cron.daily/* /etc/cron.hourly/* /etc/cron.weekly/* /etc/cron.monthly/*; do
  [ -f "$f" ] || continue
  echo "=== $f ==="
  cat "$f"
  echo ""
done'

# 14. Включённые systemd-юниты (без штатных system-юнитов)
run_remote "systemd-enabled.txt" \
    "systemctl list-unit-files --type=service --state=enabled 2>/dev/null | grep -vE '^(UNIT|[0-9]+ unit|systemd-|sys-|snap\\.)' | head -50"

# === Итог ===
FILE_COUNT=$(ls -1 "$SNAPSHOT_DIR" | wc -l)
echo ""
echo "======================================================"
echo "Снимок сохранён в ${SNAPSHOT_DIR}"
echo "Файлов: ${FILE_COUNT}"
echo "======================================================"