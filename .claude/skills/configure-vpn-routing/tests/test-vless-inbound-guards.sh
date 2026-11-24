#!/usr/bin/env bash
# Регрессионный тест ADR-0045: VLESS без TLS не создаётся без подтверждения, вход
# vless-tls собирается с путями сертификата НА СЕРВЕРЕ.
#
# Исторический дефект (2026-10-13, приватная инфраструктура оператора): канон мозга для
# ru-server выпускал вход VLESS без TLS; клиенты на Xray-core 26.7.11+ такие ссылки к
# публичному адресу не собирают, серверное ядро тот же конфиг принимало. Исходящее без
# TLS из ссылки (add-outbound-from-vless.sh) после обновления xray на сервере не дало бы
# ядру запуститься целиком.
# Второй дефект, пойман этим тестом при написании (2026-10-14): Git Bash/MSYS на Windows
# переписывал аргумент jq «/root/cert/…» в «C:/Program Files/Git/root/cert/…» — в панель
# ушёл бы несуществующий путь сертификата.
#
# Прогон: bash .claude/skills/configure-vpn-routing/tests/test-vless-inbound-guards.sh
# Офлайновый и read-only: панель — несуществующий адрес (замки) или заглушка библиотеки
# API (сборка входа). Сервер не трогается.

set -uo pipefail
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
S="$SKILL_DIR/scripts"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✅ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ❌ $1"; }

# Замок сработал = код 3 и строка «СТОП». Всё остальное — замок пропустил (дальше скрипт
# падает на входе в несуществующую панель — это ожидаемо, проверяем только замок).
verdict() { # $1 имя, $2 ожидание stop|pass, остальное — команда
    local name="$1" want="$2"; shift 2
    local out rc got=pass
    out="$("$@" 2>&1)"; rc=$?
    if [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q "СТОП"; then got=stop; fi
    if [ "$got" = "$want" ]; then ok "$name: $got (rc=$rc)"
    else no "$name: ждали $want, получили $got (rc=$rc)"; printf '%s\n' "$out" | tail -3; fi
}

export PANEL_DOMAIN=127.0.0.1 PANEL_PORT=9 WEB_BASE_PATH=/x ADMIN_LOGIN=a PASSWORD_REF=env:NO_SUCH_VAR_ADR0045
IN="$S/create-vless-inbound.sh"
echo "── 1. Замок входа: vless-tcp без TLS ──"
verdict "vless-tcp без подтверждения"          stop env INBOUND_PROTOCOL=vless-tcp bash "$IN"
verdict "vless-tcp + CONFIRM_PLAIN_VLESS=yes"  pass env INBOUND_PROTOCOL=vless-tcp CONFIRM_PLAIN_VLESS=yes bash "$IN"
verdict "по умолчанию (vless-tls)"             pass env -u INBOUND_PROTOCOL bash "$IN"
verdict "Reality на ru-server без подтверждения (прежний замок цел)" stop \
    env INBOUND_PROTOCOL=vless-reality SERVER_ROLE=ru-server bash "$IN"
# Защита от вакуума: «pass» должен означать «дошли до входа в панель», а не «упали раньше».
# Вывод сначала в переменную: при pipefail конвейер «скрипт | grep -q» получает код
# упавшего скрипта (1), даже когда grep строку нашёл.
LOGIN_OUT="$(env -u INBOUND_PROTOCOL bash "$IN" 2>&1)"
if printf '%s' "$LOGIN_OUT" | grep -q "NO_SUCH_VAR_ADR0045"; then
    ok "пропущенный случай дошёл до входа в панель (тест не вакуумный)"
else no "пропущенный случай не дошёл до входа в панель — проверка замка ничего не доказывает"; fi

echo "── 2. Замок исходящего: ссылка без TLS (исторический дефект) ──"
# Адреса — документационные (TEST-NET-3, example.com).
OLD='vless://00000000-0000-0000-0000-000000000000@203.0.113.10:443?type=tcp&security=none#old'
TLS='vless://00000000-0000-0000-0000-000000000000@vpn.example.com:443?type=tcp&security=tls&sni=vpn.example.com&fp=chrome#new'
J_OLD="$(bash "$S/parse-vless-link.sh" "$OLD" 2>/dev/null)"
J_TLS="$(bash "$S/parse-vless-link.sh" "$TLS" 2>/dev/null)"
OUT="$S/add-outbound-from-vless.sh"
verdict "ссылка security=none"                  stop env VLESS_JSON="$J_OLD" bash "$OUT"
verdict "security=none + CONFIRM_PLAIN_VLESS"   pass env VLESS_JSON="$J_OLD" CONFIRM_PLAIN_VLESS=yes bash "$OUT"
verdict "ссылка security=tls"                   pass env VLESS_JSON="$J_TLS" bash "$OUT"

echo "── 3. Сборка vless-tls на заглушке API ──"
mkdir -p "$WORK/.claude/skills/x/scripts" "$WORK/scripts/lib-api"
cp "$IN" "$WORK/.claude/skills/x/scripts/"
cat > "$WORK/scripts/lib-api/3xui.sh" <<'LIB'
_3XUI_API_VARIANT=legacy
api_login() { :; }
api_logout() { :; }
api_restart_xray() { :; }
api_gen_uuid() { echo 00000000-0000-0000-0000-000000000000; }
api_call() {
    if [ "$2" = "/panel/setting/all" ]; then
        [ -n "${STUB_NO_SETTINGS:-}" ] && return 1
        echo '{"success":true,"obj":{"webCertFile":"/root/cert/vpn.example.com/fullchain.pem","webKeyFile":"/root/cert/vpn.example.com/privkey.pem"}}'
    fi
}
api_add_inbound() { printf '%s' "$1" > "$STUB_OUT"; echo '{"success":true,"obj":{"id":7,"tag":"inbound-443"}}'; }
api_get_inbound() { echo '{"obj":{"port":443}}'; }
LIB
CP="$WORK/.claude/skills/x/scripts/create-vless-inbound.sh"
export PANEL_DOMAIN=vpn.example.com SERVER_ROLE=ru-server

STUB_OUT="$WORK/a.json" bash "$CP" >/dev/null 2>&1
if jq -e '(.streamSettings|fromjson) as $s | $s.security=="tls"
      and $s.tlsSettings.serverName=="vpn.example.com"
      and $s.tlsSettings.certificates[0].certificateFile=="/root/cert/vpn.example.com/fullchain.pem"
      and $s.tlsSettings.certificates[0].keyFile=="/root/cert/vpn.example.com/privkey.pem"
      and $s.tlsSettings.alpn==["http/1.1"] and $s.tlsSettings.settings.fingerprint=="chrome"
      and ((.settings|fromjson).decryption=="none")' "$WORK/a.json" >/dev/null 2>&1; then
    ok "пути сертификата из настроек панели, путь не переписан (MSYS)"
else no "TLS-блок не тот: $(jq -c '.streamSettings|fromjson|.tlsSettings.certificates' "$WORK/a.json" 2>/dev/null)"; fi

STUB_OUT="$WORK/b.json" STUB_NO_SETTINGS=1 TLS_CERT_FILE=/etc/c.pem TLS_KEY_FILE=/etc/k.pem \
    TLS_SERVER_NAME=other.example.com bash "$CP" >/dev/null 2>&1
if jq -e '(.streamSettings|fromjson).tlsSettings | .serverName=="other.example.com"
      and .certificates[0].certificateFile=="/etc/c.pem" and .certificates[0].keyFile=="/etc/k.pem"' \
      "$WORK/b.json" >/dev/null 2>&1; then
    ok "явные TLS_CERT_FILE/TLS_KEY_FILE/TLS_SERVER_NAME при недоступных настройках панели"
else no "явные пути не применены"; fi

STUB_OUT="$WORK/c.json" STUB_NO_SETTINGS=1 bash "$CP" >/dev/null 2>"$WORK/c.err"; rc=$?
if [ "$rc" -eq 2 ] && [ ! -f "$WORK/c.json" ] && grep -q "нет путей к сертификату" "$WORK/c.err"; then
    ok "без сертификата вход не создаётся (rc=2, в панель ничего не ушло)"
else no "ветка без сертификата: rc=$rc"; fi

echo
echo "Итог: пройдено $PASS, провалено $FAIL"
[ "$FAIL" -eq 0 ]
