#!/usr/bin/env bash
# Регрессионный тест: пути на ЧУЖОМ сервере не портятся конверсией путей Git Bash/MSYS.
#
# Исторический дефект (аудит 2026-10-14): под Git Bash на Windows нативные программы (jq,
# Windows-овый ssh) получают аргументы вида «/путь» переписанными в «C:/Program Files/Git/…».
# Так в разобранной подписке провайдера два пути ws/xhttp стали «C:/Program Files/Git/api/v1/stream»,
# spiderX «/» становился «C:/Program Files/Git/», команда «/usr/local/x-ui/x-ui …» уходила на
# сервер путём Windows. Правила и замер — knowledge/agent-runtime/_reference/msys-path-conversion.md.
#
# ⚠️ Секции 1–2 доказывают что-то ТОЛЬКО под Git Bash/MSYS: на Linux/macOS конверсии нет, и
# они зелёные и на сломанном коде. Секция 0 проверяет, что среда вообще переписывает пути, —
# иначе печатает предупреждение, а не ложную уверенность. Секция 3 (статическая) работает везде.
#
# Прогон: bash scripts/test-msys-path-conversion.sh
# Офлайновый и read-only: сеть и сервер не нужны, библиотека API подменена заглушкой.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✅ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ❌ $1"; }

echo "── 0. Переписывает ли среда пути вообще ──"
PROBE="$(jq -n -r '$ARGS.positional[0]' --args -- /root/x 2>/dev/null)"
if [ "$PROBE" = "/root/x" ]; then
    echo "  ⚠️  среда пути не переписывает (Linux/macOS или jq — MSYS-сборка): секции 1–2 здесь"
    echo "     ничего не доказывают, проверять под Git Bash на Windows"
    MSYS_ENV=0
else
    echo "  ℹ️  среда переписывает: «/root/x» → «$PROBE» — секции 1–2 значимы"
    MSYS_ENV=1
fi

echo "── 1. Разбор ссылок: пути и секреты чужого сервера доходят как есть ──"
LINK='vless://00000000-0000-0000-0000-000000000000@vpn.example.com:443?type=ws&security=reality&sni=vpn.example.com&pbk=AAAA&sid=ab&spx=%2F&path=%2Fapi%2Fv1%2Fstream#t'
for P in .claude/skills/configure-vpn-routing/scripts/parse-vless-link.sh \
         .claude/skills/extract-subscription-servers/scripts/parse-vless-link.sh; do
    J="$(bash "$ROOT/$P" "$LINK" 2>/dev/null)"
    if [ "$(printf '%s' "$J" | jq -r '.spx')" = "/" ] && [ "$(printf '%s' "$J" | jq -r '.path')" = "/api/v1/stream" ]; then
        ok "$P: spx «/» и path «/api/v1/stream» не переписаны"
    else no "$P: spx=$(printf '%s' "$J" | jq -c '.spx') path=$(printf '%s' "$J" | jq -c '.path')"; fi
done
HY='hysteria2://%2Fsecret@vpn.example.com:443?sni=vpn.example.com&obfs=salamander&obfs-password=%2Fobfs#t'
J="$(bash "$ROOT/.claude/skills/extract-subscription-servers/scripts/parse-hysteria2-link.sh" "$HY" 2>/dev/null)"
if [ "$(printf '%s' "$J" | jq -r '.password')" = "/secret" ] && [ "$(printf '%s' "$J" | jq -r '.obfs_password')" = "/obfs" ]; then
    ok "parse-hysteria2-link.sh: секреты, начинающиеся с «/», не переписаны"
else no "parse-hysteria2-link.sh: password=$(printf '%s' "$J" | jq -c '.password') obfs_password=$(printf '%s' "$J" | jq -c '.obfs_password')"; fi

echo "── 2. Исходящий Reality на заглушке API: spiderX остаётся «/» ──"
mkdir -p "$WORK/.claude/skills/x/scripts" "$WORK/scripts/lib-api"
cp "$ROOT/.claude/skills/configure-vpn-routing/scripts/add-outbound-from-vless.sh" "$WORK/.claude/skills/x/scripts/"
cat > "$WORK/scripts/lib-api/3xui.sh" <<'LIB'
api_login() { :; }
api_get_xray_config() {
    if [ -f "$STUB_OUT" ]; then printf '{"obj":%s}' "$(cat "$STUB_OUT")"
    else echo '{"obj":{"outbounds":[]}}'; fi
}
api_update_xray_config() { printf '%s' "$1" > "$STUB_OUT"; }
LIB
VJ='{"uuid":"00000000-0000-0000-0000-000000000000","host":"vpn.example.com","port":"443","security":"reality","sni":"vpn.example.com","fp":"chrome","pbk":"AAAA","sid":"ab","spx":"/","flow":"","tag":"t","type":"tcp"}'
STUB_OUT="$WORK/xray.json" PANEL_DOMAIN=x PANEL_PORT=1 WEB_BASE_PATH=/x ADMIN_LOGIN=a PASSWORD_REF=env:X \
    VLESS_JSON="$VJ" bash "$WORK/.claude/skills/x/scripts/add-outbound-from-vless.sh" >/dev/null 2>&1
SPX="$(jq -r '.outbounds[0].streamSettings.realitySettings.spiderX // "НЕТ"' "$WORK/xray.json" 2>/dev/null)"
if [ "$SPX" = "/" ]; then ok "spiderX в конфиге панели — «/»"
else no "spiderX в конфиге панели — «$SPX»"; fi

echo "── 3. Статика: удалённая команда ssh, начинающаяся с «/», без защиты ──"
# Под Windows-овым ssh строка, НАЧИНАЮЩАЯСЯ с «/», переписывается целиком, даже с пробелами
# внутри («/usr/local/x-ui/x-ui setting -show true» → «C:/Program Files/Git/usr/…»). Ищем такие
# вызовы в скриптах и в командах документации скиллов; защищённые префиксом — пропускаем.
HITS="$(cd "$ROOT" && grep -rnE "\bssh[[:space:]]+(-[a-zA-Z][^[:space:]]*[[:space:]]+)*\"?\\\$[{]?[A-Za-z_]+[}]?\"?[[:space:]]+[\"']/" \
          --include='*.sh' --include='*.md' .claude/skills scripts .claude/hooks 2>/dev/null \
        | grep -v 'MSYS_NO_PATHCONV' | grep -v '/tests/' || true)"
if [ -z "$HITS" ]; then ok "незащищённых «ssh <хост> '/…'» нет"
else no "незащищённые вызовы:"; printf '%s\n' "$HITS" | sed 's/^/       /'; fi
# Вакуумность: шаблон обязан находить заведомо плохую строку.
printf '%s\n' "x=\"\$(ssh \"\$SSH_TARGET\" \"/usr/local/x-ui/x-ui setting -show true\")\"" > "$WORK/bad.sh"
if grep -qE "\bssh[[:space:]]+(-[a-zA-Z][^[:space:]]*[[:space:]]+)*\"?\\\$[{]?[A-Za-z_]+[}]?\"?[[:space:]]+[\"']/" "$WORK/bad.sh"; then
    ok "шаблон статической проверки ловит образец дефекта (проверка не вакуумная)"
else no "шаблон НЕ ловит образец дефекта — секция 3 ничего не доказывает"; fi

echo
[ "$MSYS_ENV" -eq 0 ] && echo "⚠️  секции 1–2 выполнены вне MSYS — их зелень ничего не доказывает"
echo "Итог: пройдено $PASS, провалено $FAIL"
[ "$FAIL" -eq 0 ]
