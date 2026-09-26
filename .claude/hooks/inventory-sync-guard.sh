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
# ЧТО СЧИТАЕТСЯ ПРАВКОЙ (с 25.09.2026): команды управления (docker/systemctl/ufw/nginx/certbot,
# пользователи, hostnamectl, x-ui), crontab кроме просмотра, запуск обёрток выкатки (имя со
# словом deploy/update, служебные скрипты в /usr/local/sbin), git, меняющий рабочую копию на
# сервере, и ЗАПИСЬ ФАЙЛА в настройки сервера любым способом — `>`, tee, cp/install/rsync/scp,
# sed -i, dd, tar -x, curl -o… — в /etc, /opt, /srv, /var/www, /usr/local, юниты systemd,
# скрытые файлы root и пользователей, а `.env` и compose — в любом серверном каталоге.
# НЕ правка: запись в /tmp, /var/lib, /var/log и на свой компьютер; копия-страховка рядом с
# оригиналом (кроме каталогов *-enabled/, откуда грузится всё); дампы и бэкапы в /opt/backups;
# тело heredoc, если его читает не оболочка (текст коммита, содержимое файла, код python).
#
# ГРАНИЦА — чего замок НЕ видит (не расширять до паралича, см. правило 4 свода замков):
#   - путь в переменной или цикле: `cp x "$CRON_D/y"`, `for f in /etc/cron.d/*; do sed -i …`
#     — разбор не исполняет команду и значений переменных не знает (относительный путь после
#     `cd /abs` — видит);
#   - `chmod`/`chown`, `mkdir`, редакторы (`vim -c`, `ex`), `python -c "open(…,'w')"`, команды,
#     переданные удалённому shell через echo (`echo "cp …" | ssh h bash`), `docker cp` в
#     контейнер (это не сервер) — сознательно вне охвата;
#   - слово-литерал внутри программы (`awk '$1=="crontab"'`) считается вызовом — цена правила 4;
#   - скрытый файл в /root считается настройкой, даже если это выгрузка (`nginx -T > /root/.x`);
#   - «записал, потом выполнил»: скрипт в файле или переменной, выполненный на сервере
#     (`ssh h 'bash -s' < fix.sh`, `ssh h "$SCRIPT"`, `ssh h 'sudo bash /tmp/fix.sh'`), и код
#     python, который сам ходит на сервер (subprocess, paramiko) — содержимого замок не знает.
# Проверено двумя раундами независимой проверки 25.09.2026: расписание (343 случая) и запись
# в настройки сервера (370 случаев, четыре атакующих и перепроверщика).
#
# Ручная проверка: bash .claude/hooks/tests/test-inventory-sync-guard.sh

set -uo pipefail

# Вывод хука читает движок, а не терминал: печатаем UTF-8 независимо от кодовой страницы
# консоли. Без этого на Windows (cp1252) python падает на первом же не-ASCII символе, а
# сообщения здесь русские — хук не печатает НИЧЕГО и выходит с кодом 0, что движок читает
# как «разрешаю»: замок молча пропускает то, ради чего поставлен (поймано 26.08.2026,
# 16 случаев теста из 16). Разбор — building-enforcement.md, правило «немой замок».
export PYTHONIOENCODING=utf-8
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
# Файлы и каталоги расписания cron — для старого правила sed/perl по «опасным словам».
CRON_PATH = (r"/etc/cron\.(d|daily|hourly|weekly|monthly)(/|(?![\w.-]))"
             r"|/etc/(ana)?crontab(?![\w.-])|/etc/crontabs/|/var/spool/cron/")

CHANGE_RE = re.compile("".join([
    r"docker\s+(compose\s+)?(up|down|restart|stop|start|rm|create|pull\s+.*&&)",
    r"|docker\s+(network|volume)\s+(create|rm|connect|disconnect)",
    r"|systemctl\s+(-\S+\s+)*(restart|start|stop|reload|enable|disable|daemon-reload|edit|mask|unmask"
    r"|set-property|link|revert|reenable|preset|set-default)",
    r"|nginx\s+-s\s+reload",
    # Просмотр сертификатов (`certbot certificates`, `acme.sh --list`, `--version`) и путь
    # `/etc/cron.d/certbot` правкой не считаем: холостые остановки на диагностике TLS
    # (независимая проверка 25.09.2026). `certbot renew --dry-run` оставлен правкой:
    # запускает ли он хуки развёртывания, не проверялось.
    r"|(?<![\w/.-])(certbot|acme\.sh)\s+(?!certificates\b|--list\b|--version\b)",
    r"|ufw\s+(--force\s+)?(allow|deny|delete|limit|reject|default|enable|disable|reset|route|insert|prepend)",
    r"|(hostnamectl|timedatectl|localectl)\s+(\S+\s+)*?set-",
    # Учётные записи — это доступ к серверу (inventory/access.md).
    r"|(?<![\w.-])(useradd|usermod|userdel|adduser|deluser|groupadd|groupdel|groupmod|gpasswd|chpasswd)\b",
    # Служебная команда панели 3X-UI: перезапуск, обновление, настройки.
    r"|(?<![\w.-])(\S*/)?x-ui\s+(start|stop|restart|restart-xray|enable|disable|update|install|uninstall|setting)\b",
    # Правка базы настроек на сервере (`sqlite3 /etc/x-ui/x-ui.db "UPDATE settings …"`); SELECT и .backup — чтение.
    r"|sqlite3\s.*?[\"']?/(etc|opt|srv|var/www|usr/local)/\S*\s.*\b(update\s+\S+\s+set|insert\s+(or\s+\w+\s+)?into"
    r"|delete\s+from|replace\s+into|alter\s+table|create\s+(table|index)|drop\s+(table|index))\b",
    # find, удаляющий в каталогах настроек (`find /etc/nginx/conf.d -name '*.bak' -delete`).
    r"|find\s+[\"']?/(etc|var/spool/cron|usr/lib/systemd|lib/systemd)/\S*\s.*-delete\b",
    r"|(?<![\w-])ssh-copy-id\b",
    r"|(?<![\w.-])visudo\b(?!.*\s-c\b)",
    # crontab здесь НЕТ — он разбирается по аргументам в crontab_changes(); запись файлов в
    # конфиги сервера — в pishet_v_konfig() и zapis_perenapravleniem(); запуск обёрток
    # выкатки — в zapusk_obertki(); git на сервере — в git_na_servere().
    r"|ln\s+-s.*sites-enabled",
    # sed -i / perl -pi по «опасным словам» в любом месте пути — ради относительных путей без
    # `cd` (в том числе локальные копии — осознанный шум). Флаг правки на месте у sed пишут
    # по-разному: -i, -i.bak, -Ei, «-e … -i», --in-place; у perl -M/-I/-e/-E/-x — не правка.
    r"|(sed\s+(\S+\s+)*?-([a-zA-Z]*i|-in-place)\S*|perl\s+(\S+\s+)*?-(?:(?![MmIeEx])[a-zA-Z0-9])*i\S*)\s+.*"
    r"(nginx|compose|\.env|\.conf|" + CRON_PATH + r")",
]), re.IGNORECASE)

# ── Запись файлов в конфиги сервера (с 25.09.2026) ─────────────────────────────
# Правка сервера — это и запись файла туда, где живут его настройки: `> /etc/nginx/…`,
# `| sudo tee /etc/systemd/system/x.service`, `install … /opt/infra/scripts/…`,
# `sed -i … /etc/…`, `dd of=/etc/…`, удаление или вынос конфига из /etc. Запись в /tmp,
# /var/lib, /var/log и на свой компьютер — не правка инфраструктуры.
SERVER_PATH = re.compile(r"^(/etc/|/opt/|/srv/|/var/www/|/var/spool/cron/|/usr/local/"
                         r"|/(usr/)?lib/systemd/system/|/root/\.(?!cache(/|$))|/home/[^/]+/\.(?!cache(/|$)))")
# Удаление — только настроек: rm в /opt, /srv, /var/www чистит кэши и выпуски приложений.
UDALENIE_PATH = re.compile(r"^(/etc/|/var/spool/cron/|/(usr/)?lib/systemd/system/|/root/\.(?!cache(/|$))"
                           r"|/home/[^/]+/\.(?!cache(/|$)))")
# Настройки приложения в ЛЮБОМ серверном каталоге (`/root/app-bot/.env`, `/opt/app/compose.yml`).
CONFIG_FILE = re.compile(r"(^|/)(\.env(\.(?!example|sample|template|dist)[\w-]+)?|(docker-)?compose[\w.-]*\.ya?ml)$",
                         re.IGNORECASE)
# Раздача ключей входа — всегда правка доступа, и через `~`.
KLYUCHI = re.compile(r"^(~|\$HOME|\$\{HOME\})/\.(ssh/(?!known_hosts)|bashrc$|profile$|bash_profile$|zshrc$"
                     r"|config/systemd(/|$))")
# Временное и чужое: /tmp, устройства, диск своего компьютера в Git Bash (/c/…).
VREMENNOE = re.compile(r"^/(tmp|var/tmp|dev|proc|sys|run|[a-z])(/|$)", re.IGNORECASE)
# Данные, а не настройки: снимки баз, архивы, логи, пробное восстановление (`/opt/backups/dbs`).
DANNYE = re.compile(r"^/(opt|srv)/((backups?|dumps?|snap(shots?)?|archives?|restore[\w-]*)(/|$)"
                    r"|[^/]+/(backups?|logs?)/)")
# Копия-страховка с хвостом-датой или меткой (`nginx.conf.bak`, `crontab.bak-2026-09-25`) — не правка.
# Метка — только в конце или перед датой: `my.old-site.kz` — не страховка, а новый сайт.
STRAHOVKA = re.compile(r"(\.bak|\.orig|\.old|\.save|\.dist|~)([._-]?\d[\w.:-]*)?$", re.IGNORECASE)
# Каталог, из которого загружается ВСЁ (`include sites-enabled/*`): копия `.bak` там — второй сайт.
VKLYUCHENO = re.compile(r"/[\w.-]*-enabled/")
# Программы, у которых следующее слово — подкоманда, а не наш глагол: `apt install x`,
# `pip install -r /opt/app/req.txt`, `git mv`, `docker cp` (контейнер, не сервер).
CHUZHIE = {"apt", "apt-get", "aptitude", "pip", "pip3", "pipx", "npm", "pnpm", "yarn", "dnf", "yum",
           "brew", "gem", "cargo", "go", "snap", "flatpak", "helm", "make", "docker", "podman",
           "kubectl", "git", "conda", "poetry", "uv", "composer", "bundle"}
ZAPUSKATELI = {"sudo", "doas", "env", "xargs", "nohup", "exec", "time", "nice", "ionice", "setsid", "stdbuf"}
GLAGOL_RE = re.compile(r"(?:^|[\s'\"(`;])\\?(?:(?:/usr)?/s?bin/)?(cp|mv|install|ln|rsync|scp|tee|dd|sed|perl|rm|unlink"
                       r"|touch|truncate|htpasswd|tar|curl|wget|yq|awk|unzip|openssl|gpg|patch|sponge)(?=\s)")
PERENAPR_RE = re.compile(r"(?:^|[^<\d&>])\d*(>>?|&>>?)\s*(\S+)")

def put(tok, cwd=None):
    t = tok.strip("'\"()`;")
    t = re.sub(r"^[\w.@-]+:(?=/)", "", t)            # `хост:` у scp и rsync
    if cwd and t and not t.startswith(("/", "~", "$", "-")) and not re.match(r"^[A-Za-z]:", t):
        t = cwd.rstrip("/") + "/" + (t[2:] if t.startswith("./") else t)   # после `cd /opt/app`
    return t.rstrip("/") or t

def v_konfig(tok, spisok=SERVER_PATH, cwd=None):
    t = put(tok, cwd)
    if KLYUCHI.match(t):
        return True
    if not t.startswith("/") or VREMENNOE.match(t):
        return False
    konfig = (bool(spisok.match(t + ("/" if t.count("/") == 1 else ""))) and not (DANNYE.match(t) and "/../" not in t)) \
        or bool(CONFIG_FILE.search(t))
    return konfig and (bool(VKLYUCHENO.search(t)) or not STRAHOVKA.search(t))

def kopiya_ryadom(src, dst, cwd=None):
    """`cp nginx.conf nginx.conf.backup.2026…`, `cp -a /opt/infra /opt/infra-backup-…`: цель —
    тот же путь с хвостом. Точка — всегда страховка (cron и run-parts такие имена не читают);
    дефис — только на втором уровне (`/etc/nginx-bak`): в `cron.d/` `backup-old` — второе задание."""
    s, d = put(src, cwd), put(dst, cwd)
    if not d.startswith(s) or len(d) == len(s) or VKLYUCHENO.search(d):
        return False
    hvost = d[len(s):]
    if "/" in hvost or hvost == ".d" or re.search(r"\.(conf|service|timer|socket|list|sources|local|json|ya?ml|env|ini|toml|sh)$", hvost):
        return False                                    # `x` → `x.conf`: копия стала загружаемой
    return hvost[0] in ".~" or (hvost[0] in "-_" and d.count("/") <= 2)

def zapis_perenapravleniem(seg, cwd=None):
    """`echo … > /etc/x`, `cat >> .env` после `cd /opt/app` — на СЫРОМ сегменте, до отсева
    read-only: echo и cat пишут здесь не на экран, а в конфиг."""
    return any(v_konfig(m.group(2), cwd=cwd) for m in PERENAPR_RE.finditer(seg))

def bez_kommentariya(s):
    """Отрезает `# комментарий` — но не `#` внутри кавычек (`sed 's/x/y # z/'`)."""
    kav = None
    for k, ch in enumerate(s):
        if kav:
            if ch == kav:
                kav = None
        elif ch in "'\"":
            kav = ch
        elif ch == "#" and (k == 0 or s[k - 1].isspace()):
            return s[:k]
    return s

def _argumenty(rest, s_znacheniem=()):
    rest = bez_kommentariya(rest)
    rest = re.sub(r"<<<\s*(\"[^\"]*\"|'[^']*'|\S+)", " ", rest)          # here-string — данные
    rest = re.sub(r"<<-?\s*['\"]?\w+['\"]?", " ", rest)                  # начало heredoc
    toks, args, i = rest.split(), [], 0
    while i < len(toks):
        t = toks[i]
        if re.match(r"^\d*(>>?|<<?|&>>?)", t):                          # перенаправления — не аргументы
            i += 2 if re.fullmatch(r"\d*(>>?|<<?|&>>?)", t) else 1
            continue
        if t.strip("'\"") in ("&", "\\;", ";", "+", ""):                 # фон, конец -exec, хвост кавычек
            i += 1
            continue
        if t in s_znacheniem:                                            # `-m 644`, `-e ssh` — значение флага
            i += 2
            continue
        b = re.fullmatch(r"(.*)\{([^{},]*),([^{},]*)\}(['\"]?)", t)      # `x{,.bak}` = `x x.bak`
        args += [b.group(1) + b.group(2) + b.group(4), b.group(1) + b.group(3) + b.group(4)] if b else [t]
        i += 1
    return args

def _znachenie(args, dlinnye, korotkie):
    """Значение флага: `-o X`, `-oX`, `--output X`, `--output=X`."""
    for j, a in enumerate(args):
        if a in dlinnye or a in korotkie:
            return args[j + 1] if j + 1 < len(args) else None
        for d in dlinnye:
            if a.startswith(d + "="):
                return a.split("=", 1)[1]
        for k in korotkie:
            if a.startswith(k) and len(a) > len(k) and not a.startswith("--"):
                return a[len(k):]
            if len(k) == 2 and re.fullmatch(r"-[a-zA-Z]+", a) and a.endswith(k[1]) and not a.startswith("--"):
                return args[j + 1] if j + 1 < len(args) else None   # `-qO X`, `-fsSLo X`
    return None

def pishet_v_konfig(probe, cwd=None):
    for m in GLAGOL_RE.finditer(probe):
        pered, kand, j = probe[:m.start(1)].split(), [], None
        j = len(pered) - 1
        while j >= 0 and len(kand) < 2:                 # два слова перед глаголом, без флагов
            w = pered[j].strip("'\"(`;\\")
            if not w or w.startswith("-"):
                j -= 1
                continue
            if j >= 1 and pered[j - 1] in ("-u", "-g", "--user", "--group"):
                j -= 2                                  # `sudo -u git cp` — git здесь пользователь
                continue
            kand.append(w.rsplit("/", 1)[-1].lower())
            j -= 1
        if kand and (kand[0] in CHUZHIE or (len(kand) > 1 and kand[1] in CHUZHIE and kand[0] not in ZAPUSKATELI)):
            continue                                    # `apt install`, `git mv`, `docker compose cp`
        glagol = m.group(1).lower()
        s_znach = {"cp": ("-S", "--suffix"), "mv": ("-S", "--suffix"), "ln": ("-S", "--suffix"),
                   "install": ("-m", "-o", "-g", "-S", "--mode", "--owner", "--group", "--suffix"),
                   "rsync": ("-e", "--rsh", "--exclude", "--include", "--filter", "-f", "--suffix", "--chmod")}
        args = _argumenty(probe[m.end(1):], s_znach.get(glagol, ()))
        m_find = re.search(r"(?:^|[\s'\"(;])find\s+[\"']?(/[^\s'\"]*)", probe[:m.start(1)])
        if m_find and "-exec" in probe[m_find.end():m.start(1)]:
            args = [m_find.group(1).rstrip("/") + "/x" if a == "{}" else a for a in args]   # `-exec sed -i … {} +`
        faily = [a for a in args if not a.startswith("-")]
        if not args:
            continue
        vk = lambda a, spisok=SERVER_PATH: v_konfig(a, spisok, cwd)
        if glagol in ("tee", "touch", "truncate", "sponge"):
            return any(vk(a) for a in faily)
        if glagol == "htpasswd":
            return bool(faily) and vk(faily[0])
        if glagol == "curl":
            cel = _znachenie(args, ("--output",), ("-o",))
            return bool(cel) and vk(cel)
        if glagol == "wget":
            cel = _znachenie(args, ("--output-document", "--directory-prefix"), ("-O", "-P"))
            return bool(cel) and vk(cel)
        if glagol == "unzip":
            cel = _znachenie(args, (), ("-d",))
            return bool(cel) and vk(cel)
        if glagol == "openssl":
            return any(vk(c) for c in (_znachenie(args, (), ("-out",)), _znachenie(args, (), ("-keyout",))) if c)
        if glagol == "gpg":
            cel = _znachenie(args, ("--output",), ("-o",))
            return bool(cel) and vk(cel)
        if glagol == "patch":
            cel = _znachenie(args, ("--directory",), ("-d",))
            return vk(cel) if cel else (bool(faily) and vk(faily[0]))
        if glagol == "tar":
            if not any(a in ("--extract", "--get") or re.fullmatch(r"-?[a-zA-Z]*x[a-zA-Z]*", a) for a in args[:2]):
                continue                                # упаковка и просмотр — не правка
            cel = _znachenie(args, ("--directory",), ("-C",)) or cwd
            return bool(cel) and vk(cel)
        if glagol == "dd":
            if any(re.fullmatch(r"if=/dev/(zero|u?random)", a) for a in args) and \
                    not any(a.startswith("of=") and vk(a[3:], UDALENIE_PATH) for a in args):
                continue                                # замер диска: `dd if=/dev/zero of=/opt/ddtest`
            return any(a.startswith("of=") and vk(a[3:]) for a in args)
        if glagol in ("sed", "perl", "yq", "awk"):
            if glagol == "sed":
                na_meste = any(re.fullmatch(r"-(-in-place\S*|[a-zA-Z]*i\S*)", a) for a in args)
            elif glagol == "perl":
                na_meste = any(re.fullmatch(r"-(-in-place\S*|(?:(?![MmIeEx])[a-zA-Z0-9])*i\S*)", a) for a in args)
            elif glagol == "yq":
                na_meste = any(a in ("-i", "--inplace") or re.fullmatch(r"-[a-zA-Z]*i[a-zA-Z]*", a) for a in args)
            else:
                na_meste = any(a == "-i" and k + 1 < len(args) and args[k + 1] == "inplace" for k, a in enumerate(args))
            if not na_meste:
                continue
            return any(vk(a) for a in faily)
        if glagol in ("rm", "unlink"):
            return any(vk(a, UDALENIE_PATH) or (put(a, cwd).startswith("/") and CONFIG_FILE.search(put(a, cwd))
                                                and not VREMENNOE.match(put(a, cwd))) for a in faily)
        # cp, mv, install, ln, rsync, scp: цель — «-t каталог» или последний аргумент
        if glagol == "rsync" and (len(faily) < 2 or any(
                a in ("--dry-run", "--list-only") or re.fullmatch(r"-[a-zA-Z]*n[a-zA-Z]*", a) for a in args)):
            continue                                    # `rsync -n`, `--list-only`, один аргумент — показ
        if glagol == "mv" and any(vk(a, UDALENIE_PATH) for a in faily):   # и `mv -t каталог /etc/x`
            return True                                 # вынос или переименование конфига из /etc — правка
        cel = None
        for k, a in enumerate(args):
            if a in ("-t", "--target-directory") or re.fullmatch(r"-[a-zA-Z]*t", a):
                cel = args[k + 1] if k + 1 < len(args) else None
                break
            if a.startswith("--target-directory="):
                cel = a.split("=", 1)[1]
                break
            if re.fullmatch(r"-t/\S*", a):
                cel = a[2:]
                break
        if cel is not None:
            return vk(cel)
        if glagol in ("cp", "rsync") and len(faily) == 2 and kopiya_ryadom(faily[0], faily[1], cwd):
            continue                                    # копия-страховка рядом с оригиналом
        return bool(faily) and vk(faily[-1])
    return False

# Запуск скрипта-обёртки выкатки. Ожог 2026-08-04: перечислялись только ПРЯМЫЕ команды, а
# весь IaC-контур устроен обёрткой — настоящие `git pull` и `docker compose up -d` живут
# ВНУТРИ скрипта на сервере, в ход попадает только его вызов. Узнаём ЗАПУСК (первое слово
# команды после sudo/bash/ssh-хоста), а не упоминание имени: `git diff deploy-x.sh`,
# `ls`, `bash -n` — не выкатка (независимая проверка 25.09.2026). Имя — любое со словом
# deploy/update: `deploy-app.sh`, `redeploy.sh`, `bot_deploy.sh`, `self_update.sh`.
OBERTKA = re.compile(r"(^|/)([\w.-]*(deploy|update)[\w.-]*\.sh|[\w.]*(deploy|update)-[\w.-]+|[\w.-]+-(deploy|update))$"
                     r"|^/usr/local/s?bin/[\w.-]*(deploy|update|restart)[\w.-]*$", re.IGNORECASE)
PREFIKSY = {"sudo", "doas", "env", "nohup", "exec", "time", "nice", "ionice", "timeout", "bash", "sh", "zsh",
            "source", ".", "setsid", "stdbuf"}

def zapusk_obertki(probe):
    slova, i = probe.split(), 0
    while i < len(slova):
        w = slova[i].strip("'\"(`\\")
        if not w:
            i += 1
            continue
        if w in ("bash", "sh", "zsh") and i + 1 < len(slova) and slova[i + 1] == "-n":
            return False                                # проверка синтаксиса, не запуск
        if w == "ssh":                                  # ssh [флаги] хост [команда…]
            i += 1
            while i < len(slova) and slova[i].startswith("-"):
                i += 2 if slova[i] in ("-o", "-i", "-p", "-l", "-F", "-J", "-L", "-R", "-D", "-E", "-c", "-m", "-b", "-W") else 1
            i += 1
            continue
        if w == "<" and i + 1 < len(slova):             # `ssh h bash -s < deploy.sh`
            return bool(OBERTKA.search(slova[i + 1].strip("'\"")))
        if w in ("-u", "-g", "-C", "-p") and i + 1 < len(slova):
            i += 2
            continue
        if w in PREFIKSY or w.startswith("-") or re.fullmatch(r"\w+=\S*", w) or re.fullmatch(r"\d+[smhd]?", w):
            i += 1
            continue
        return bool(OBERTKA.search(w))
    return False

# git, меняющий рабочую копию на сервере (`cd /opt/app && git pull`, `git -C /opt/infra reset`).
GIT_RE = re.compile(r"(?:^|[\s'\"(`;])git\s+(-C\s+(\S+)\s+)?(pull|checkout|reset|merge|rebase|stash|apply|am"
                    r"|cherry-pick|restore|switch)\b")

def git_na_servere(probe, cwd=None):
    m = GIT_RE.search(probe)
    if not m:
        return False
    kuda = put(m.group(2), cwd) if m.group(2) else cwd
    return bool(kuda) and kuda.startswith("/") and not VREMENNOE.match(kuda) and bool(SERVER_PATH.match(kuda + "/"))

INVENTORY_RE = re.compile(r"inventory[/\\]|/infra/.*\.md$|refresh\.sh|dump-snapshot", re.IGNORECASE)

# Сегменты, начинающиеся с read-only утилиты, изменением не считаются: их аргументы —
# данные, а не команды. Без этого `grep -n "crontab" file` числился правкой инфраструктуры
# (холостая остановка в разборе 2026-07-24, F4+).
READONLY_LEAD = re.compile(
    r"^(grep|egrep|fgrep|rg|ag|echo|printf|cat|bat|less|more|head|tail|wc|jq|sort|uniq"
    r"|column|diff|comm|man|which|type|file|stat|basename|dirname)(\s|$)", re.IGNORECASE)
PREFIX_RE = re.compile(r"^\s*(sudo\s+((-[ug]|--user|--group)\s+\S+\s+|-\w+\s+)*)?(\w+=\S+\s+)*", re.IGNORECASE)
SSH_GOLOVA = re.compile(r"^ssh(\s+-\w+(\s+(?!-)[^\s'\"]+)?)*\s+[^\s'\"-]\S*\s*")

def komanda(probe):
    """Сама команда: без `ssh [флаги] хост`, открывающей кавычки и sudo."""
    t = probe
    m = SSH_GOLOVA.match(t)
    if m:
        t = t[m.end():]
    t = PREFIX_RE.sub("", t.lstrip("'\"(` ")).strip()
    t = re.sub(r"^((ba|z|da)?sh|su(\s+\S+)*?)\s+(-\w+\s+)*-\w*c\s+['\"]?", "", t)   # `bash -c "cd /opt/app && …"`
    return PREFIX_RE.sub("", t).strip()

# crontab меняет расписание всем, КРОМЕ просмотра `crontab -l` (и `-u пользователь -l`).
# До 25.09.2026 правило было `crontab\s+` — и ловило просмотр: холостые остановки на
# обычной диагностике (04.08 и 25.09.2026, `sudo crontab -l 2>&1 | grep -v "^#"`).
# Поэтому разбираем аргументы, а не ищем подстроку: запись бывает и без флагов —
# `crontab файл`, `… | crontab -`, `(crontab -l; echo …) | crontab -` (просмотр и запись
# в одной строке: второй сегмент обязан сработать).
# Программа — и по полному пути (`/usr/bin/crontab`, `\crontab`), но НЕ файл `/etc/crontab`,
# не `crontabs/`, не `crontab.bak`, не шаблон поиска `crontab*`.
CRONTAB_RE = re.compile(r"(?:^|[\s(`'\"])\\?(?:(?:/usr)?(?:/local)?/s?bin/)?crontab(?![\w./*?\[-])(.*)$",
                        re.IGNORECASE)
# Команды, у которых слово crontab — только аргумент (что искать, какой пакет, чей журнал).
# Действует ТОЛЬКО на разбор crontab: find с -exec/-delete в общий READONLY_LEAD не кладём.
CRONTAB_FOREIGN = re.compile(r"^(find|journalctl|whereis|locate|plocate|mlocate|dpkg|dpkg-query"
                             r"|apt-cache|apt-file|ls|zgrep|zegrep|zcat|xzgrep|getent)(\s|$)", re.IGNORECASE)
REDIR_RE = re.compile(r"^\d*(>>?|<|&>)")              # 2>&1, >файл, 2>/dev/null, <файл
REDIR_ALONE = re.compile(r"^\d*(>>?|<|&>)$")           # оператор отдельно — цель следующим словом

def crontab_changes(probe, piped):
    if CRONTAB_FOREIGN.match(probe) and not re.search(r"\s-(exec|execdir|ok|okdir)\s", probe):
        return False
    m = CRONTAB_RE.search(probe)
    if not m:
        return False
    rest = re.split(r"(?:^|\s)#", m.group(1), maxsplit=1)[0]     # комментарий bash — не аргументы
    # Расписание из вложенной команды: `crontab <(crontab -l | grep -v x)`, `crontab <<<"$(…)"`.
    # Её -l внешнему вызову не принадлежит — отрезаем, а сам факт вложения = установка.
    vlozh = re.search(r"<\(|<<<", rest)
    if vlozh:
        rest = rest[:vlozh.start()]
    rest = re.sub(r"\$\([^()]*\)|`[^`]*`", "SUBST", rest)        # $(date +%F) — одно слово
    rest = re.split(r"[)`]", rest, maxsplit=1)[0]                # конец $( … ), где стоял сам crontab
    rest = re.split(r"\|\|?|&&|;", rest, maxsplit=1)[0]            # канал внутри кавычек-данных не режется
    toks = [t.strip("'\"(") for t in rest.split()]
    smotrim, stdin_file, i = False, False, 0
    while i < len(toks):
        t = toks[i]
        if not t:
            i += 1
        elif REDIR_RE.match(t):
            stdin_file = stdin_file or t.lstrip("0123456789").startswith("<")
            i += 2 if REDIR_ALONE.match(t) else 1
        elif t == "-u":
            i += 2                                     # пользователь — не команда
        elif t in ("-l", "-V"):
            smotrim, i = True, i + 1
        elif t == "-T":
            smotrim, i = True, i + 2                  # проверка синтаксиса файла — не установка
        else:
            return True        # -e, -r, -i, «-», файл, незнакомый флаг — расписание меняется
    # Без аргументов crontab читает новое расписание со stdin — из канала, «< файла» или
    # вложенной команды (cronie; Debian/Ubuntu голый вызов отвергают). Голое слово в чужой
    # команде (`command -v crontab`, `dpkg -S crontab`) правкой не считаем.
    return not smotrim and (piped or stdin_file or bool(vlozh))

def razbit(cmd):
    """Режет команду на сегменты по `| || && ;` и переводу строки — но НЕ внутри кавычек-данных.
    Кавычки после `ssh хост` и `-c` (bash -c, sh -c, su -c) содержат команды — их режем; кавычки
    `sed`, `grep`, `awk`, `echo` — данные: `sed -i 's|a|b|' /etc/x` и директивы nginx с `;`
    остаются одной командой (независимая проверка 25.09.2026: раньше такая правка проходила).
    Возвращает [(сегмент, разделитель перед ним)]."""
    segs, buf, razd, stek, i, n = [], [], "", [], 0, len(cmd)
    def kod_li():
        # Текст от начала сегмента (или от открывшей кода кавычки) до этой кавычки: команды
        # внутри — только если перед ней РОВНО `ssh [флаги] хост`, `eval` или `… -c`.
        nachalo = stek[-1][2] + 1 if stek else 0
        tekst = PREFIX_RE.sub("", "".join(buf[nachalo:])).strip()
        return bool(re.search(r"(^|\s)-\w*c$", tekst) or tekst == "eval" or SSH_GOLOVA.fullmatch(tekst + " "))
    while i < n:
        ch = cmd[i]
        if ch == "\\" and not (stek and stek[-1][0] == "'"):
            buf.append(cmd[i:i + 2])
            i += 2
            continue
        if ch in "'\"":
            if stek and stek[-1][0] == ch:
                stek.pop()
            elif not stek or stek[-1][1]:               # внутри данных чужая кавычка — просто символ
                stek.append((ch, kod_li(), len(buf)))
            buf.append(ch)
            i += 1
            continue
        if ch == "\n":
            stek = []                                   # незакрытую кавычку через перевод строки не тянем
        if ch == "\n" or all(k for _, k, _ in stek):
            razdel = next((s for s in ("||", "&&", "|", ";", "\n") if cmd.startswith(s, i)
                           and not (s == "|" and i > 0 and cmd[i - 1] == ">")), None)
            if razdel:
                segs.append(("".join(buf), razd))
                buf, razd = [], razdel
                stek = [(q, k, -1) for q, k, _ in stek]  # новый сегмент начинается внутри тех же кавычек
                i += len(razdel)
                continue
        buf.append(ch)
        i += 1
    segs.append(("".join(buf), razd))
    return segs

# Тело heredoc — это ВХОД программы, а не команды: текст сообщения `git commit -F - <<EOF`,
# содержимое файла `cat > run.sh <<EOF`, код `python - <<EOF`. Разбирать его как команды —
# значит останавливать ход на тексте коммита, где упомянуты `ufw default` или `git pull`
# (ложные остановки 25.09.2026 в самой сессии правки замка).
# Тело выкидывается из разбора, ТОЛЬКО если его читает известная программа-читатель данных
# (CHITATELI_DANNYH: cat, git, gh, python, psql, jq, read, `while … done` …) и в логической
# строке нет оболочки, которая получит его как команды: ssh/sshpass/plink в любом месте
# (`timeout 120 ssh`, `cat <<EOF | ssh h 'bash -s'`, `for h …; do ssh $h`), оболочка без
# файла-скрипта (`bash`, `bash -s`, `sudo -iu root bash`, `bash -c "$(cat <<EOF …)"`),
# `sudo -s`/`-i`, `su`, `at`. Незнакомый читатель (`expect`, `runuser`, `docker exec … sh`) —
# тело разбирается как команды, как раньше: для дисциплинарного замка шум дешевле дыры.
# Оператор `<<` ищется только вне кавычек-данных и вне комментария (`grep "<<'PY'" файл`,
# `# см. cat <<EOF` — не heredoc); тело начинается после конца ЛОГИЧЕСКОЙ строки (перенос
# `\`); `<<\EOF` — тоже метка; вложенные тела разбираются рекурсивно; нет закрывающей метки —
# ничего не выкидываем; `"$(cat <<EOF … EOF)" && ssh …` — строка после метки приклеивается
# к команде. Первая версия (по первому слову команды, умолчание «не узнал — выкинуть») дала
# 21 регрессию на независимой проверке 25.09.2026. Сама запись в первой строке
# (`cat > /etc/x <<EOF`) ловится как раньше.
HEREDOC_OP = re.compile(r"<<(-?)\s*\\?(['\"]?)([A-Za-z_][\w.-]*)\2")
OBOLOCHKA = r"(?:/\S*/)?(bash|sh|zsh|dash|ksh|ash)"
CHITATELI_DANNYH = {"cat", "tee", "git", "gh", "glab", "python", "python3", "py", "node", "deno", "perl", "ruby",
                    "php", "psql", "mysql", "mariadb", "sqlite3", "jq", "yq", "awk", "gawk", "sed", "mail", "mailx",
                    "sendmail", "msmtp", "curl", "wc", "sort", "uniq", "grep", "head", "tail", "read", ":", "done",
                    "base64", "xxd", "iconv", "column", "cut", "tr", "envsubst", "true", "less", "more"}
OBERTKI_KOMANDY = {"sudo", "doas", "env", "nohup", "nice", "ionice", "exec", "time", "command", "builtin", "!",
                   "xargs", "stdbuf", "setsid"}

def _heredoc_operatory(s, stek):
    """Операторы heredoc в строке вне кавычек-данных и вне комментария. `stek` — контексты
    (' " $( ), переживает перевод строки: многострочные кавычки не теряются."""
    ops, i, n = [], 0, len(s)
    while i < n:
        top = stek[-1] if stek else None
        ch = s[i]
        if top == "'":
            if ch == "'":
                stek.pop()
            i += 1
            continue
        if ch == "\\":
            i += 2
            continue
        if top == '"':
            if ch == '"':
                stek.pop()
            elif s.startswith("$(", i):
                stek.append("$(")
                i += 2
                continue
            i += 1
            continue
        if ch == "#" and (i == 0 or s[i - 1] in " \t;&|("):
            break                                       # комментарий до конца строки
        if ch in "'\"":
            stek.append(ch)
        elif s.startswith("$(", i):
            stek.append("$(")
            i += 2
            continue
        elif ch == ")" and top == "$(":
            stek.pop()
        elif s.startswith("<<<", i):
            i += 3
            continue
        elif s.startswith("<<", i):
            m = HEREDOC_OP.match(s, i)
            if m:
                ops.append(m)
                i = m.end()
                continue
        i += 1
    return ops

ZAKRYTYE_KAVYCHKI = re.compile(r"'[^']*'|\"(?:[^\"\\\\]|\\\\.)*\"")
SSH_SLOVO = re.compile(r"(?<![\w.-])(?:/\S*/)?(ssh|plink)(?=\s|$)")
SSH_FLAG_ZNACH = {"-o", "-i", "-p", "-l", "-F", "-J", "-L", "-R", "-D", "-E", "-c", "-m", "-b", "-W", "-P", "-pw"}

def _udalyonnaya(tekst, konec):
    """Удалённая команда ssh/plink, начинающегося в `konec`: всё после флагов и хоста до `<<`."""
    slova, k = re.split(r"<<", tekst[konec:], maxsplit=1)[0].split(), 0
    while k < len(slova) and slova[k].startswith("-"):
        k += 2 if slova[k] in SSH_FLAG_ZNACH else 1
    ost = " ".join(w for w in slova[k + 1:] if not re.fullmatch(r"\d*(>>?|<|&>>?)&?\d*\S*", w))
    return ost.strip().strip("'\"").strip()

def _telo_chitaet_obolochka(tekst):
    if re.search(r"(?<![\w./-])" + OBOLOCHKA + r"\s+(-\S+\s+)*-\w*c\s+[\"']?\$\(", tekst):
        return True                                     # `bash -c "$(cat <<EOF …)"` — тело станет скриптом
    # ssh/plink: тело уходит удалённой команде. Нет её (`ssh h <<EOF`), это оболочка или внутри
    # подстановка — команды; удалённый читатель данных (`ssh h 'cat > x'`, `ssh h psql`,
    # `ssh h python3 -`) — данные; незнакомый — команды.
    for m in SSH_SLOVO.finditer(ZAKRYTYE_KAVYCHKI.sub(lambda q: "Q" * len(q.group(0)), tekst)):
        udal = _udalyonnaya(tekst, m.end())
        if not udal or "$(" in udal or _telo_chitaet_obolochka(udal):
            return True
        chitatel = _chitatel(udal)
        if chitatel not in CHITATELI_DANNYH and not re.fullmatch(OBOLOCHKA, chitatel):
            return True
    t = ZAKRYTYE_KAVYCHKI.sub(" ", tekst)               # содержимое закрытых кавычек — данные
    for m in re.finditer(r"(?<![\w./-])" + OBOLOCHKA + r"(?=\s|$|[;|&)])", t):
        toks = re.split(r"<<|[|;&)]", t[m.end():], maxsplit=1)[0].split()
        if "-c" in toks:
            continue                                    # тело — вход скрипта из -c
        if "-s" in toks or not any(not x.startswith("-") for x in toks):
            return True                                 # `bash`, `bash -s`, `sudo -iu root bash`
    if re.search(r"(?<![\w./-])(sudo|doas)(\s+-\S+)+\s*(<<|$)", t):
        return True                                     # `sudo -s <<EOF`, `sudo -i <<EOF`
    return bool(re.search(r"(?<![\w./-])(su|at|batch)(?=\s|$)", t))

def _chitatel(pered):
    """Программа, которой достаётся тело: последняя команда перед `<<` без обёрток."""
    pered = ZAKRYTYE_KAVYCHKI.sub("Q", pered.replace("\\\n", " "))   # `(`, `|` в кавычках — не границы
    while True:                                         # закрытые `$(…)` и `…` — одно слово, не граница
        svernuto = re.sub(r"\$\([^()]*\)|`[^`]*`", "SUBST", pered)
        if svernuto == pered:
            break
        pered = svernuto
    kusok = re.split(r"\$\(|\|\||&&|[;|(`]|\b(?:do|then|else)\b", pered)[-1]
    slova, k = kusok.split(), 0
    while k < len(slova):
        w = slova[k].strip("'\"")
        if w in ("-u", "-g", "-C", "timeout"):
            k += 2
            continue
        if w in OBERTKI_KOMANDY or w.startswith("-") or re.fullmatch(r"\w+=\S*", w) or not w:
            k += 1
            continue
        imya = w.rsplit("/", 1)[-1]
        if imya in ("docker", "podman", "kubectl"):     # `docker compose exec -T db psql` — читатель psql
            vnutri = [x.rsplit("/", 1)[-1] for x in slova[k + 1:]]
            return next((x for x in vnutri if x in CHITATELI_DANNYH), imya)
        return imya
    return ""

def _telo_komandy(tekst, pered):
    if _telo_chitaet_obolochka(tekst):
        return True
    chitatel = _chitatel(pered)
    if chitatel in CHITATELI_DANNYH or chitatel in ("ssh", "plink", "sshpass"):
        return False                                    # для ssh удалённую команду уже разобрали выше
    if re.fullmatch(OBOLOCHKA, chitatel):
        return False                                    # `bash script.sh <<EOF` — тело: вход скрипта
    return True                                         # незнакомый читатель — разбираем, как раньше

def bez_tel_heredoc(cmd):
    stroki, out, i, stek, logich, ozhidayut, prikleit = cmd.split("\n"), [], 0, [], [], [], False
    while i < len(stroki):
        s = stroki[i]
        i += 1
        if prikleit and out:
            out[-1] += " " + s                          # `"$(cat <<EOF … EOF)" && ssh …` — команда продолжается
        else:
            out.append(s)
        prikleit = False
        logich.append(s)
        ozhidayut.extend((len(logich) - 1, m) for m in _heredoc_operatory(s, stek))
        if (len(s) - len(s.rstrip("\\"))) % 2 == 1 and not (stek and stek[-1] == "'"):
            continue                                    # перенос `\` — логическая строка продолжается
        if ozhidayut:
            tekst = "\n".join(logich)
            for nomer, m in ozhidayut:
                pered = "\n".join(logich[:nomer] + [logich[nomer][:m.start()]])
                tabs, konec = m.group(1) == "-", m.group(3)
                j, telo, najdeno = i, [], False
                while j < len(stroki):
                    stroka = stroki[j]
                    j += 1
                    if (stroka.lstrip("\t") if tabs else stroka) in (konec, konec + ")", konec + ')"'):
                        najdeno = True                  # `EOF)` bash тоже принимает как конец внутри $( )
                        break
                    telo.append(stroka)
                if not najdeno:
                    break                               # нет закрывающей метки — ничего не выкидываем
                if _telo_komandy(tekst, pered):
                    out.extend(bez_tel_heredoc("\n".join(telo)).split("\n"))   # команды; вложенные тела — тоже
                    out.append("")                      # граница: тело закончилось
                else:
                    prikleit = bool(stek)               # внутри "$( … )": строка после метки — та же команда
                    if not prikleit:
                        out.append("")
                i = j
            ozhidayut = []
        if not stek:
            logich = []
    return "\n".join(out)

def changes_infra(cmd):
    """Ищет изменяющую команду посегментно, пропуская read-only обёртки."""
    cmd = bez_tel_heredoc(cmd)                         # сначала: `\` в теле heredoc — не продолжение строки
    cmd = re.sub(r"\\\r?\n", " ", cmd)                 # продолжение строки обратной косой — как в bash
    cmd = re.sub(r"\|[ \t]*\r?\n\s*", "| ", cmd)       # канал, перенесённый на новую строку
    cwd = None
    for seg, razd in razbit(cmd):
        piped = razd == "|"
        probe = PREFIX_RE.sub("", seg).strip()
        sama = komanda(probe)
        mcd = re.match(r"^cd\s+(\S+)", sama)
        if mcd:                                         # `cd /opt/app && echo X >> .env`
            cel = put(mcd.group(1), cwd)
            cwd = cel if cel.startswith("/") and not VREMENNOE.match(cel) else None
        if zapis_perenapravleniem(seg, cwd):
            return probe or seg.strip()
        if not probe or READONLY_LEAD.match(sama):
            continue
        if (CHANGE_RE.search(probe) or crontab_changes(probe, piped) or pishet_v_konfig(probe, cwd)
                or zapusk_obertki(probe) or git_na_servere(probe, cwd)):
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
