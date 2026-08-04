#!/usr/bin/env bash
# .claude/hooks/inventory-sync-guard.sh — Stop-хук: инвентарь не отстаёт от реальности (§3.2).
#
# ЗАЧЕМ. Персона §3.2 требует: изменил инфраструктуру → в том же ответе обнови текстовый
# inventory (и освежи дашборд-зеркало, если он развёрнут). Правило нарушается ТИХО — агент
# рапортует «Готово», а карта расходится с сервером; следующая сессия читает устаревшее и
# принимает решения по нему. В бэклоге /retro такая находка уже есть (2026-06-15).
#
# ЧТО ДЕЛАЕТ. В момент, когда агент хочет закончить ответ, смотрит текущий ход: были ли
# команды, меняющие инфраструктуру, и обновлялся ли inventory. Меняли, но не обновляли —
# не даёт закончить и напоминает. Это не запрет: если обновлять нечего, агент говорит об
# этом оператору явно и завершает — повторно хук не остановит (см. предохранитель).
#
# ПРЕДОХРАНИТЕЛЬ ОТ ЗАЦИКЛИВАНИЯ (важно). Останавливаем МАКСИМУМ ОДИН раз на ход:
#   1) поле stop_hook_active (движок сообщает, что Stop-хук уже отработал);
#   2) собственная метка в TMPDIR по (сессия + хеш текущего хода) — работает, даже если
#      поля из п.1 не будет. Второй механизм полностью под нашим контролем, поэтому
#      бесконечный цикл «блок → ответ → блок» невозможен.
#
# FAIL-OPEN, в отличие от замка красной зоны. Здесь цена ошибки — расхождение документа,
# а не потеря данных. Нет python3, нет транскрипта, что-то непонятно → молча пропускаем:
# мешать работе ученика из-за дисциплинарной проверки неправильно.
#
# Ручная проверка: bash .claude/hooks/tests/test-inventory-sync-guard.sh

set -uo pipefail
RAW="$(cat)"

command -v python3 >/dev/null 2>&1 || exit 0   # fail-open

python3 - "$RAW" <<'PY'
import sys, json, os, re, hashlib, tempfile

try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)                      # непонятный вход — не мешаем

if d.get("stop_hook_active"):        # предохранитель 1: движок уже звал нас в этом ходе
    sys.exit(0)

transcript = d.get("transcript_path") or ""
if not transcript or not os.path.isfile(transcript):
    session = d.get("session_id") or ""
    cwd = d.get("cwd") or os.getcwd()
    slug = re.sub(r"[^a-zA-Z0-9]", "-", cwd)
    transcript = os.path.expanduser(f"~/.claude/projects/{slug}/{session}.jsonl")
if not os.path.isfile(transcript):
    sys.exit(0)

# ── Разбираем транскрипт: нас интересует только ТЕКУЩИЙ ход ───────────────────
# Ход = всё, что случилось после последней настоящей реплики оператора. Вставки движка
# (isMeta / sourceToolUseID / isSidechain) репликой не считаем — те же фильтры, что в
# замке красной зоны (C.11).
records = []
try:
    with open(transcript, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                records.append(json.loads(line))
            except Exception:
                continue
except Exception:
    sys.exit(0)

def is_real_user(rec):
    if rec.get("type") != "user":
        return False
    if rec.get("isMeta") or rec.get("sourceToolUseID") or rec.get("isSidechain"):
        return False
    m = rec.get("message") or {}
    if m.get("role") != "user":
        return False
    c = m.get("content")
    if isinstance(c, list):
        if any(isinstance(b, dict) and b.get("type") == "tool_result" for b in c):
            return False
        c = " ".join(b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text")
    if not isinstance(c, str) or not c.strip():
        return False
    return not c.lstrip().startswith(("<command-name>", "<local-command-", "<command-message>",
                                      "<system-reminder>", "Base directory for this skill"))

start = 0
last_user_text = ""
for i, rec in enumerate(records):
    if is_real_user(rec):
        start = i + 1
        m = rec.get("message") or {}
        c = m.get("content")
        last_user_text = c if isinstance(c, str) else json.dumps(c, ensure_ascii=False)
turn = records[start:]

# ── Что в этом ходе делали ────────────────────────────────────────────────────
# Меняющие инфраструктуру команды. Только глаголы изменения: read-only (ps/status/df)
# сюда не попадает намеренно, иначе хук ругался бы на обычную диагностику.
CHANGE_RE = re.compile(
    r"docker\s+(compose\s+)?(up|down|restart|stop|start|rm|create|pull\s+.*&&)"
    r"|docker\s+(network|volume)\s+(create|rm|connect|disconnect)"
    r"|systemctl\s+(restart|start|stop|reload|enable|disable|daemon-reload)"
    r"|nginx\s+-s\s+reload"
    r"|(certbot|acme\.sh)\s+"
    r"|ufw\s+(allow|deny|delete|limit)"
    r"|crontab\s+"
    r"|ln\s+-s.*sites-enabled"
    r"|(tee|sed\s+-i)\s+.*(nginx|compose|\.env|\.conf|crontab)"
    # Скрипты-обёртки выкатки. Ожог 2026-08-04: перечислялись только ПРЯМЫЕ команды, а
    # весь IaC-контур устроен обёрткой — настоящие `git pull` и `docker compose up -d`
    # живут ВНУТРИ скрипта на сервере, в ход попадает только его вызов. Класс операций,
    # ради которых замок и ставился, проходил мимо: выкатка пересоздала контейнер, ответ
    # закончился словами «инфраструктуру это не меняло», замок промолчал, отставание
    # снимка заметил оператор. При этом на безобидное `crontab -l` замок срабатывал.
    # Голого имени достаточно: read-only обёртки (`cat`, `grep`) отсеяны выше в
    # READONLY_LEAD, а ложное срабатывание на упоминании — осознанная цена (правило 4
    # в knowledge/agent-runtime/_reference/building-enforcement.md).
    r"|deploy(-remote)?\.sh"
    r"|update\.sh",
    re.IGNORECASE)

INVENTORY_RE = re.compile(r"inventory[/\\]|/infra/.*\.md$|refresh\.sh|dump-snapshot", re.IGNORECASE)

# Сегменты, начинающиеся с read-only утилиты, изменением не считаются: их аргументы —
# данные, а не команды. Без этого `grep -n "crontab" file` числился правкой инфраструктуры
# (холостая остановка в разборе 2026-07-24, F4+).
READONLY_LEAD = re.compile(
    r"^(grep|egrep|fgrep|rg|ag|echo|printf|cat|bat|less|more|head|tail|wc|jq|yq|sort|uniq"
    r"|column|diff|comm|man|which|type|file|stat|basename|dirname)(\s|$)", re.IGNORECASE)
PREFIX_RE = re.compile(r"^\s*(sudo\s+(-\w+\s+)*)?(\w+=\S+\s+)*", re.IGNORECASE)

def changes_infra(cmd):
    """Ищет изменяющую команду посегментно, пропуская read-only обёртки."""
    for seg in re.split(r"\|\||&&|;|\||\n", cmd):
        probe = PREFIX_RE.sub("", seg).strip()
        if not probe or READONLY_LEAD.match(probe):
            continue
        if CHANGE_RE.search(probe):
            return probe
    return None

changed, updated = [], False
for rec in turn:
    if rec.get("type") != "assistant":
        continue
    for block in (rec.get("message") or {}).get("content") or []:
        if not isinstance(block, dict) or block.get("type") != "tool_use":
            continue
        name = block.get("name") or ""
        inp = block.get("input") or {}
        if name == "Bash":
            cmd = str(inp.get("command", ""))
            hit = changes_infra(cmd)
            if hit:
                changed.append(hit.splitlines()[0][:90])
            if INVENTORY_RE.search(cmd):       # обновление снимка/дашборда скриптом — тоже засчитываем
                updated = True
        elif name in ("Write", "Edit", "NotebookEdit"):
            if INVENTORY_RE.search(str(inp.get("file_path", ""))):
                updated = True

if not changed or updated:
    sys.exit(0)

# ── Предохранитель 2: один блок на ход, даже без stop_hook_active ─────────────
key = hashlib.sha256((str(d.get("session_id", "")) + last_user_text[:400]).encode()).hexdigest()[:16]
tmpdir = tempfile.gettempdir()
mark = os.path.join(tmpdir, f"sysadmin-inv-guard-{key}")

# Убираем за собой: метки старше двух суток (§3.10) — иначе TMPDIR копит мусор.
import time
try:
    cutoff = time.time() - 2 * 86400
    for name in os.listdir(tmpdir):
        if name.startswith("sysadmin-inv-guard-"):
            p = os.path.join(tmpdir, name)
            if os.path.getmtime(p) < cutoff:
                os.remove(p)
except Exception:
    pass

if os.path.exists(mark):
    sys.exit(0)
try:
    open(mark, "w").close()
except Exception:
    sys.exit(0)                      # не смогли поставить метку — лучше пропустить, чем зациклить

sample = "\n".join(f"  • {c}" for c in changed[:3])
reason = f"""§3.2 — инфраструктура изменилась, inventory не обновлён.

В этом ответе были команды, меняющие инфраструктуру:
{sample}

А правок в inventory/ и обновления снимка не было. Правило §3.2: изменение на сервере и
запись в текстовом inventory происходят в ОДНОМ ответе — иначе карта тихо расходится с
реальностью, и следующая сессия примет решение по устаревшему (уровень C.2).

Сделай одно из двух:
  1) обнови соответствующий документ inventory (и освежи дашборд-зеркало, если развёрнут);
  2) если обновлять нечего — состав, конфиги и связи не менялись — скажи это оператору
     одной строкой прямо в отчёте.

Останавливаю только один раз за ответ: закончишь снова — пропущу."""

print(json.dumps({"decision": "block", "reason": reason}, ensure_ascii=False))
PY
