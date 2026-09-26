#!/usr/bin/env bash
# test-assemble-configs.sh — тест сборщика конфигов скилла sysadmin-init.
#
# ЗАЧЕМ. `assemble-configs.sh` — единственное место, где рождается содержимое обоих
# конфигов оператора, и результат его работы пишется ПОВЕРХ живых файлов. Пока теста не
# было, режим `--reconfigure` молча уничтожал всё, чего не касалось интервью: паспорт
# состояния `state`, второй сервер в `servers[]`, блок `vpn`, `monitoring.kind`, лишние
# записи в `projects[]`, `meta` мозга (аудит 2026-09-24, ADR-0042). Дефект выглядел как
# успех: скрипт печатал «собраны draft'ы», валидация проходила, самопроверка рапортовала
# «✅ проверено» — потому что урезанный файл остаётся валидным по схеме.
#
# Случаи, помеченные [дефект], на ПРЕЖНЕЙ версии сборщика падают. Проверять так:
#   git stash / git show <старый>:...assemble-configs.sh > /tmp/old.sh — и прогнать тест на ней.
# Если тест зелен на обеих версиях — он ничего не проверяет.
#
# Запуск из корня репо:  bash scripts/test-assemble-configs.sh
# Требует: bash, jq. Возврат: 0 — все случаи как задумано, 1 — есть расхождения.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
ASM="${ASSEMBLE_SH:-$ROOT/.claude/skills/sysadmin-init/scripts/assemble-configs.sh}"

# ВНИМАНИЕ. Здесь намеренно НЕ выставляется MSYS_NO_PATHCONV/MSYS2_ARG_CONV_EXCL: на Windows
# они ломают сам jq (он программа Windows и перестаёт открывать пути вида /tmp/...).
# Подмену POSIX-путей в аргументах jq лечит сам сборщик — он передаёт такие значения через
# окружение (env.VAR). Случай «путь приёмника дошёл без искажений» ниже это и проверяет.

command -v jq >/dev/null 2>&1 || { echo "ОТКАЗ: нет jq — проверить нечем."; exit 2; }
[ -f "$ASM" ] || { echo "ОТКАЗ: не найден сборщик: $ASM"; exit 2; }

# Свой временный каталог: mktemp + trap, уборка только своего (ADR-0038).
TMP="$(mktemp -d 2>/dev/null || mktemp -d -t asmtest)"
[ -d "$TMP" ] || { echo "ОТКАЗ: не создался временный каталог"; exit 2; }
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  ❌ $1"; echo "      $2"; }
check() {  # $1=описание  $2=jq-выражение (true/false)  $3=файл
    local got; got="$(jq -r "$2" "$3" 2>/dev/null)"
    [ "$got" = "true" ] && ok "$1" || bad "$1" "ожидалось true, получено: '${got:-<пусто>}'"
}

# ── Фикстуры: живые конфиги «как у оператора» ────────────────────────────────
mk_infra() {
cat > "$1" <<'JSON'
{
  "$schema": "../sysadmin/infra-config.schema.json",
  "version": "1.0",
  "state": {
    "mode": "rebuild",
    "digest_cmd": "ssh SRV cat /opt/infra/digest.md",
    "manual_rules": ["правило один", "правило два"]
  },
  "map": { "vpn": "inventory/hosts/SRV/vpn.md" },
  "monitoring": { "enabled": true, "kind": "custom" },
  "backups": { "enabled": false },
  "notifications": { "telegram": { "enabled": true, "bot_username": "alerts_bot", "chat_type": "personal" } },
  "servers": [
    { "alias": "SRV1", "ssh_alias": "SRV1", "role": "production" },
    { "alias": "SRV2", "ssh_alias": "SRV2", "role": "production" }
  ],
  "vpn": {
    "enabled": true,
    "panel_url": "https://vpn.example.com:35784",
    "panel_web_base_path": "see-manager:panel",
    "server_role": "foreign-server",
    "upstream_kind": "self-foreign",
    "default_reality_dest": "www.google.com"
  }
}
JSON
}
mk_agent() {
cat > "$1" <<'JSON'
{
  "version": "1.0",
  "operator": { "name": "Оператор", "language": "ru", "timezone": "Asia/Almaty" },
  "secrets": { "manager": "keepassxc", "cli_available": true },
  "projects": [
    { "id": "alpha", "infra_root": "C:/work/alpha" },
    { "id": "beta",  "infra_root": "C:/work/beta" }
  ],
  "default_project": "alpha",
  "interaction": {},
  "meta": { "onboarding_completed": true, "onboarding_completed_at": "2026-06-26T07:17:33Z" }
}
JSON
}

echo "── test-assemble-configs ──────────────────────────"
echo "сборщик: $ASM"
echo

# ── Случай 1 [дефект]: слияние карты — меняем только бэкапы ──────────────────
W="$TMP/c1"; mkdir -p "$W"; mk_infra "$W/live-infra.json"; mk_agent "$W/live-agent.json"
AGENT_CURRENT="$W/live-agent.json" INFRA_CURRENT="$W/live-infra.json" \
BACKUPS_ENABLED=true BACKUPS_DESTINATION=sftp \
BACKUPS_RETENTION_JSON='{"daily":7,"weekly":4,"monthly":6}' \
BACKUPS_SFTP_HOST=backup-host BACKUPS_SFTP_PATH=/data/srv1 \
bash "$ASM" "$W" "$ROOT" >/dev/null 2>&1
D="$W/infra-config-draft.json"
if [ -f "$D" ]; then
    echo "[дефект] слияние карты: меняем только блок бэкапов"
    check "паспорт state сохранён целиком"        '(.state.mode=="rebuild") and (.state.manual_rules|length==2)' "$D"
    check "оглавление map сохранено"              '.map.vpn != null' "$D"
    check "оба сервера на месте"                  '(.servers|length)==2' "$D"
    check "блок vpn не тронут"                    '(.vpn.panel_url=="https://vpn.example.com:35784") and (.vpn.server_role=="foreign-server") and (.vpn.default_reality_dest=="www.google.com")' "$D"
    check "monitoring.kind=custom сохранён"       '(.monitoring.kind=="custom") and (.monitoring.enabled==true)' "$D"
    check "канал Telegram сохранён"               '.notifications.telegram.bot_username=="alerts_bot"' "$D"
    check "бэкапы включены и приёмник записан"    '(.backups.enabled==true) and (.backups.destination=="sftp") and (.backups.sftp.host=="backup-host")' "$D"
    # Отдельно и явно: путь приёмника — POSIX-абсолютный, и на Windows его молча
    # подменял MSYS при вызове jq (см. шапку). Проверяем посимвольное совпадение.
    check "путь приёмника дошёл без искажений"    '.backups.sftp.path=="/data/srv1"' "$D"
    check "retention записан объектом"            '.backups.retention.daily==7' "$D"
else
    bad "слияние карты: сборщик не создал draft" "нет файла $D"
fi
echo

# ── Случай 2 [дефект]: слияние мозга — реестр проектов и meta ────────────────
A="$W/agent-config-draft.json"
if [ -f "$A" ]; then
    echo "[дефект] слияние мозга: ничего не просили менять"
    check "оба проекта на месте"                  '(.projects|length)==2' "$A"
    check "активный проект не подменён"           '.default_project=="alpha"' "$A"
    check "meta знакомства сохранена"             '.meta.onboarding_completed==true' "$A"
    check "менеджер паролей сохранён"             '.secrets.manager=="keepassxc"' "$A"
else
    bad "слияние мозга: сборщик не создал draft" "нет файла $A"
fi
echo

# ── Случай 3 [дефект]: обновление существующего сервера по alias ─────────────
W2="$TMP/c2"; mkdir -p "$W2"; mk_infra "$W2/live-infra.json"; mk_agent "$W2/live-agent.json"
AGENT_CURRENT="$W2/live-agent.json" INFRA_CURRENT="$W2/live-infra.json" \
SRV_ALIAS=SRV2 SRV_SSH=SRV2 SRV_ROLE=personal SRV_DOMAIN=srv2.example.com \
bash "$ASM" "$W2" "$ROOT" >/dev/null 2>&1
D2="$W2/infra-config-draft.json"
echo "[дефект] правка одного сервера не сносит остальные"
check "серверов по-прежнему два"                  '(.servers|length)==2' "$D2"
check "роль SRV2 обновлена"                       '([.servers[]|select(.alias=="SRV2")]|first|.role)=="personal"' "$D2"
check "домен SRV2 добавлен"                       '([.servers[]|select(.alias=="SRV2")]|first|.domain)=="srv2.example.com"' "$D2"
check "SRV1 не тронут"                            '([.servers[]|select(.alias=="SRV1")]|first|.role)=="production"' "$D2"
check "state пережил правку сервера"              '.state.mode=="rebuild"' "$D2"
echo

# ── Случай 4: первичная настройка по-прежнему работает от skeleton ───────────
W3="$TMP/c3"; mkdir -p "$W3"
NAME=Оператор LANG=ru TIMEZONE=Asia/Almaty MANAGER=keepassxc PROJ_ID=proj PROJ_INFRA_ROOT=C:/work/proj \
SRV_ALIAS=SRV SRV_SSH=SRV SRV_ROLE=production \
bash "$ASM" "$W3" "$ROOT" >/dev/null 2>&1
echo "первичная настройка (без живых файлов)"
check "мозг собран, проект записан"               '(.projects|length)==1 and (.default_project=="proj")' "$W3/agent-config-draft.json"
check "карта собрана, сервер записан"             '(.servers|length)==1 and (.servers[0].alias=="SRV")' "$W3/infra-config-draft.json"
echo

# ── Случай 5: первичная настройка без обязательной переменной — отказ ────────
W4="$TMP/c4"; mkdir -p "$W4"
echo "отказы вместо тихой сборки мусора"
if NAME=Оператор LANG=ru TIMEZONE=Asia/Almaty MANAGER=keepassxc PROJ_ID=proj PROJ_INFRA_ROOT=C:/w \
   bash "$ASM" "$W4" "$ROOT" >/dev/null 2>&1; then
    bad "нет обязательной SRV_ALIAS → должен быть отказ" "скрипт вернул 0"
else
    ok "нет обязательной SRV_ALIAS → отказ"
fi

# ── Случай 6: битый *_CURRENT — громкий отказ, а не откат на skeleton ────────
W5="$TMP/c5"; mkdir -p "$W5"; printf 'не json' > "$W5/broken.json"
if INFRA_CURRENT="$W5/broken.json" SRV_ALIAS=SRV SRV_SSH=SRV SRV_ROLE=production \
   bash "$ASM" "$W5" "$ROOT" >/dev/null 2>&1; then
    bad "битый INFRA_CURRENT → должен быть отказ" "скрипт вернул 0 (молча собрал бы из skeleton)"
else
    ok "битый INFRA_CURRENT → отказ"
fi
if INFRA_CURRENT="$W5/нет-такого.json" SRV_ALIAS=SRV SRV_SSH=SRV SRV_ROLE=production \
   bash "$ASM" "$W5" "$ROOT" >/dev/null 2>&1; then
    bad "несуществующий INFRA_CURRENT → должен быть отказ" "скрипт вернул 0"
else
    ok "несуществующий INFRA_CURRENT → отказ"
fi

echo
echo "────────────────────────────────────────────────────"
if [ "$FAIL" -eq 0 ]; then
    echo "PASS — все $PASS проверок сошлись"
    exit 0
fi
echo "FAIL — расхождений: $FAIL (сошлось: $PASS)"
exit 1
