#!/usr/bin/env bash
# detect-defaults.sh — собирает defaults для интервью /sysadmin-init.
#
# Печатает на stdout JSON со следующими ключами:
#   {
#     "os":                       "Darwin" | "Linux" | "FreeBSD" | ...,
#     "docker":                   true | false,
#     "jq_version":               "1.7" | "missing",
#     "check_jsonschema_available": true | false,
#     "ssh_aliases":              ["alias1", "alias2", ...],   // из ~/.ssh/config, без wildcard *
#     "timezone":                 "MSK" | "UTC" | ...,         // из date +%Z
#     "user":                     "alice"
#   }
#
# Использование (скилл /sysadmin-init):
#   bash detect-defaults.sh > /tmp/sysadmin-defaults.json
#   jq '.ssh_aliases' /tmp/sysadmin-defaults.json
#
# NEVER: эти скрипты не запускают SSH, не делают сетевых операций. Только локальное
# чтение ~/.ssh/config и вызовы локальных утилит (which, uname, date).

set -u

OS=$(uname -s)

DOCKER=false
command -v docker >/dev/null 2>&1 && DOCKER=true

JQ_VERSION="missing"
if command -v jq >/dev/null 2>&1; then
    JQ_VERSION=$(jq --version 2>&1 | sed 's/jq-//')
fi

CHECK_JSONSCHEMA=false
command -v check-jsonschema >/dev/null 2>&1 && CHECK_JSONSCHEMA=true

# SSH-алиасы из ~/.ssh/config (исключаем wildcard '*')
SSH_ALIASES="[]"
if [ -f "$HOME/.ssh/config" ] && command -v jq >/dev/null 2>&1; then
    SSH_ALIASES=$(grep -iE '^[[:space:]]*Host[[:space:]]+' "$HOME/.ssh/config" 2>/dev/null \
        | awk '{for (i=2; i<=NF; i++) print $i}' \
        | grep -v '\*' \
        | jq -R . \
        | jq -s . 2>/dev/null \
        || echo "[]")
    # На случай если pipe выдал пустую строку
    [ -z "$SSH_ALIASES" ] && SSH_ALIASES="[]"
fi

TIMEZONE=$(date +%Z 2>/dev/null || echo "UTC")
USER_NAME="${USER:-$(whoami)}"

# Финальная сборка JSON через jq
if command -v jq >/dev/null 2>&1; then
    jq -n \
      --arg os "$OS" \
      --argjson docker "$DOCKER" \
      --arg jq_version "$JQ_VERSION" \
      --argjson cjs "$CHECK_JSONSCHEMA" \
      --argjson aliases "$SSH_ALIASES" \
      --arg tz "$TIMEZONE" \
      --arg user "$USER_NAME" \
      '{
         os: $os,
         docker: $docker,
         jq_version: $jq_version,
         check_jsonschema_available: $cjs,
         ssh_aliases: $aliases,
         timezone: $tz,
         user: $user
       }'
else
    # Fallback без jq — собираем JSON вручную (минимально)
    printf '{"os":"%s","docker":%s,"jq_version":"%s","check_jsonschema_available":%s,"ssh_aliases":[],"timezone":"%s","user":"%s"}\n' \
        "$OS" "$DOCKER" "$JQ_VERSION" "$CHECK_JSONSCHEMA" "$TIMEZONE" "$USER_NAME"
fi