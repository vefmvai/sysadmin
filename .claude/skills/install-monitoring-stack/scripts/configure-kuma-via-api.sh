#!/usr/bin/env bash
# configure-kuma-via-api.sh — первичная настройка Uptime Kuma 2.x через socket.io API
#
# Использование:
#   KUMA_USERNAME=admin KUMA_PASSWORD=... \
#   TELEGRAM_BOT_TOKEN=... TELEGRAM_CHAT_ID=... \
#   ./configure-kuma-via-api.sh
#
# КРИТИЧНО: для Kuma 2.x работает ТОЛЬКО socket.io клиент. Python-библиотека
# uptime-kuma-api поддерживает только 1.x — для 2.x использует протокол, который
# изменился. Самый надёжный путь — Node.js socket.io-client изнутри контейнера Kuma
# (там Node.js уже установлен).
#
# Контейнер по умолчанию называется uptime-kuma. Если другой — задай KUMA_CONTAINER.

set -euo pipefail

KUMA_CONTAINER="${KUMA_CONTAINER:-uptime-kuma}"
KUMA_URL="${KUMA_URL:-http://localhost:3001}"
KUMA_USERNAME="${KUMA_USERNAME:?Set KUMA_USERNAME}"
KUMA_PASSWORD="${KUMA_PASSWORD:?Set KUMA_PASSWORD}"

if ! docker ps --format '{{.Names}}' | grep -qx "$KUMA_CONTAINER"; then
    echo "ERROR: контейнер $KUMA_CONTAINER не найден или не запущен" >&2
    exit 1
fi

# Установить socket.io-client внутри контейнера (если ещё не установлен)
docker exec "$KUMA_CONTAINER" sh -c '
    if [ ! -d /tmp/kuma-config/node_modules ]; then
        mkdir -p /tmp/kuma-config
        cd /tmp/kuma-config
        npm init -y > /dev/null
        npm install socket.io-client@4 > /dev/null 2>&1
    fi
'

# Готовим Node.js скрипт, который выполнит:
# 1. setup() — создание первичной учётки (только если ещё не настроен)
# 2. login() — логин под этой учёткой
# 3. addMonitorTag/setNotification — Telegram provider (если задан)
NODE_SCRIPT=$(cat <<'NODE_EOF'
const { io } = require("socket.io-client");

const url = process.env.KUMA_URL;
const username = process.env.KUMA_USERNAME;
const password = process.env.KUMA_PASSWORD;
const tgToken = process.env.TELEGRAM_BOT_TOKEN || "";
const tgChatId = process.env.TELEGRAM_CHAT_ID || "";

const socket = io(url, { transports: ["websocket"], reconnection: false });

function emit(event, ...args) {
  return new Promise((resolve, reject) => {
    socket.emit(event, ...args, (result) => {
      if (result && result.ok === false) {
        reject(new Error(`${event} failed: ${result.msg || JSON.stringify(result)}`));
      } else {
        resolve(result);
      }
    });
  });
}

socket.on("connect", async () => {
  try {
    // 1. Setup (создание первичной учётки) — может вернуть ошибку, если уже настроен
    try {
      await emit("setup", username, password);
      console.log("setup: created first user");
    } catch (e) {
      console.log("setup: skipped (already configured)");
    }

    // 2. Login
    await emit("login", { username, password, token: "" });
    console.log("login: ok");

    // 3. Telegram notification provider (если заданы переменные)
    if (tgToken && tgChatId) {
      const notif = {
        name: "telegram-default",
        type: "telegram",
        isDefault: true,
        applyExisting: true,
        telegramBotToken: tgToken,
        telegramChatID: tgChatId,
      };
      await emit("addNotification", notif, null);
      console.log("notification: telegram added");
    } else {
      console.log("notification: skipped (TELEGRAM_BOT_TOKEN/CHAT_ID не заданы)");
    }

    socket.disconnect();
    process.exit(0);
  } catch (err) {
    console.error("ERROR:", err.message);
    socket.disconnect();
    process.exit(1);
  }
});

socket.on("connect_error", (err) => {
  console.error("connect_error:", err.message);
  process.exit(2);
});

setTimeout(() => {
  console.error("timeout: socket.io не ответил за 30s");
  process.exit(3);
}, 30000);
NODE_EOF
)

# Запускаем Node.js скрипт внутри контейнера, передавая параметры через env
docker exec \
  -e KUMA_URL="$KUMA_URL" \
  -e KUMA_USERNAME="$KUMA_USERNAME" \
  -e KUMA_PASSWORD="$KUMA_PASSWORD" \
  -e TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}" \
  -e TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}" \
  -w /tmp/kuma-config \
  "$KUMA_CONTAINER" \
  node -e "$NODE_SCRIPT"

echo "OK: Kuma настроена"