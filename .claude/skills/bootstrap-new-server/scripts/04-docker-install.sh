#!/usr/bin/env bash
# 04-docker-install.sh — ставит Docker CE из официального APT-репозитория Docker.
# Удаляет старые версии (docker.io, docker-engine), добавляет admin в группу docker.
# Идемпотентный — повторный запуск не ломает существующую установку.
#
# Запуск (через sudo):
#   ADMIN_USER=deploy sudo -E bash 04-docker-install.sh

set -euo pipefail

: "${ADMIN_USER:?ADMIN_USER required}"

echo "[04-docker] ADMIN_USER=$ADMIN_USER"

# --- 1. Если Docker уже стоит — проверить версию и выйти ---
if command -v docker &>/dev/null; then
    DOCKER_VER=$(docker --version | awk '{print $3}' | tr -d ',')
    echo "[04] Docker уже установлен (версия $DOCKER_VER)"
    # Убеждаемся, что admin в группе docker
    if ! groups "$ADMIN_USER" | grep -qE '\bdocker\b'; then
        usermod -aG docker "$ADMIN_USER"
        echo "[04] $ADMIN_USER добавлен в группу docker (нужен relogin)"
    fi
    docker --version
    docker compose version 2>/dev/null || echo "[04] docker-compose-plugin не найден — будет установлен ниже"
fi

# --- 2. Удалить старые версии (если есть) ---
echo "[04] Удаляю старые версии Docker (если установлены)"
DEBIAN_FRONTEND=noninteractive apt-get remove -y \
    docker docker-engine docker.io containerd runc 2>/dev/null || true

# --- 3. Установить зависимости ---
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl gnupg lsb-release

# --- 4. Добавить GPG-ключ Docker ---
install -m 0755 -d /etc/apt/keyrings

# Определить дистрибутив (debian / ubuntu)
. /etc/os-release
DISTRO_ID="${ID}"
if [ "$DISTRO_ID" != "ubuntu" ] && [ "$DISTRO_ID" != "debian" ]; then
    echo "[04] ERROR: дистрибутив '$DISTRO_ID' не поддерживается этим скриптом (только ubuntu/debian)"
    exit 1
fi

curl -fsSL "https://download.docker.com/linux/${DISTRO_ID}/gpg" \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# --- 5. Добавить APT-репозиторий ---
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${DISTRO_ID} \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list

# --- 6. Установить Docker CE + plugins ---
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

# --- 7. Добавить admin в группу docker ---
usermod -aG docker "$ADMIN_USER"

# --- 8. Включить и запустить ---
systemctl enable docker
systemctl start docker

# --- 9. Verify ---
echo ""
echo "[04] Версии:"
docker --version
docker compose version
echo ""
echo "[04] Тест hello-world:"
docker run --rm hello-world | head -5

cat <<EOF

[04] ============================================================
[04] OK — Docker CE установлен, admin в группе docker.
[04]
[04] ВНИМАНИЕ: Чтобы использовать docker без sudo для $ADMIN_USER,
[04] нужен RELOGIN (или \`newgrp docker\`):
[04]
[04]   exit
[04]   ssh -p \$SSH_PORT $ADMIN_USER@<server-ip>
[04]   docker ps   # должно работать без sudo
[04] ============================================================
EOF