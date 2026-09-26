#!/usr/bin/env bash
# Тесты Stop-хука «инвентарь не отстаёт» (§3.2, ADR-0023).
# Прогон: bash .claude/hooks/tests/test-inventory-sync-guard.sh
set -uo pipefail

# Обвязка теста тоже печатает русский текст через python: на чужой кодовой странице
# (Windows cp1252) она падает и подаёт хуку пустой вход — тест «проваливается» там,
# где замок исправен. Правило 3д свода замков.
export PYTHONIOENCODING=utf-8
HERE="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$HERE/inventory-sync-guard.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# Метки предохранителя кладём в свой TMPDIR: иначе они переживают прогон и следующий
# запуск тестов «пропускает» блокировки (метка = один блок на ход). Заодно не задеваем
# метки живой сессии.
MARKS="$TMP/marks"; mkdir -p "$MARKS"
PASS=0; FAIL=0

# Собираем транскрипт: реплика оператора + перечисленные вызовы инструментов.
mk() { # $1 = файл, далее пары "Bash:команда" / "Edit:путь"
  local out="$1"; shift
  {
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"почини сервис"}}'
    for spec in "$@"; do
      local tool="${spec%%:*}" arg="${spec#*:}"
      # Перевод путей Git Bash запрещён: команду, начинающуюся с `/` (`/usr/bin/crontab -r`),
      # он переписал бы в виндовый путь, и тест проверял бы не ту строку (25.09.2026).
      MSYS2_ARG_CONV_EXCL='*' python3 - "$tool" "$arg" <<'PY'
import json, sys
tool, arg = sys.argv[1], sys.argv[2]
inp = {"command": arg} if tool == "Bash" else {"file_path": arg, "new_string": "x"}
print(json.dumps({"type":"assistant","message":{"role":"assistant","content":[
  {"type":"tool_use","name":tool,"input":inp}]}}, ensure_ascii=False))
PY
    done
  } > "$out"
}

run() { # $1 = транскрипт, $2 = stop_hook_active (true|false)
  python3 - "$1" "${2:-false}" <<'PY' | TMPDIR="$MARKS" PYTHONIOENCODING="${HOOK_ENC:-utf-8}" bash "$HOOK"
import json, sys, os
# session_id стабилен между запусками (hash() в Python рандомизирован — метку бы не нашли).
print(json.dumps({"session_id": os.path.basename(sys.argv[1]), "cwd": "/tmp/p",
                  "transcript_path": sys.argv[1],
                  "stop_hook_active": sys.argv[2] == "true"}, ensure_ascii=False))
PY
}

check() { # $1 = block|pass, $2 = описание, $3 = транскрипт, $4 = stop_hook_active
  local out; out="$(run "$3" "${4:-false}")"
  local got="pass"; printf '%s' "$out" | grep -q '"decision": *"block"' && got="block"
  if [ "$got" = "$1" ]; then PASS=$((PASS+1)); printf '  ✅ %s\n' "$2"
  else FAIL=$((FAIL+1)); printf '  ❌ %s — ожидали %s, получили %s\n' "$2" "$1" "$got"; fi
}

echo "── Тесты Stop-хука «инвентарь не отстаёт» ───────────────"

echo "[1] Диагностика без изменений — не трогаем"
mk "$TMP/ro.jsonl" "Bash:docker ps -a" "Bash:systemctl status nginx" "Bash:df -h"
check pass "read-only команды" "$TMP/ro.jsonl"

echo "[1а] Опасные слова внутри read-only команд — не изменение (F4+, разбор 2026-07-24)"
mk "$TMP/ro2.jsonl" "Bash:grep -n \"crontab\" .claude/hooks/red-zone-guard.sh"
check pass "grep со словом crontab" "$TMP/ro2.jsonl"
mk "$TMP/ro3.jsonl" "Bash:echo 'docker compose up -d' >> notes.md"
check pass "echo с текстом команды" "$TMP/ro3.jsonl"
mk "$TMP/ro4.jsonl" "Bash:cat /etc/systemd/system/app.service | head -20"
check pass "чтение unit-файла" "$TMP/ro4.jsonl"

echo "[1б] Просмотр расписания crontab -l — не изменение (холостые остановки 04.08 и 25.09.2026)"
# Первые две строки — команды (имена хостов обобщены), на которых сторож остановил ход 25.09.2026
# (его собственный отчёт: «crontab -l 2>&1», «crontab -l 2>/dev/null»).
n=0
for c in \
  "ssh -o BatchMode=yes prod-host 'echo \"== root crontab\"; sudo crontab -l 2>&1 | grep -v \"^#\" | grep -v \"^\$\"'" \
  "ssh -o BatchMode=yes edge-host 'sudo ls /etc/cron.d; sudo crontab -l 2>/dev/null | grep -v \"^#\"'" \
  "sudo crontab -u root -l" \
  "crontab -l -u deploy" \
  "crontab -l > /tmp/cron.bak" \
  "command -v crontab >/dev/null 2>&1 || echo нет" \
  "dpkg -S crontab" \
  "find / -name crontab 2>/dev/null" \
  "sudo cp -p /etc/cron.d/backup /root/cron.d-backup.bak-2026-09-25" \
  "ls -la /etc/crontab /var/spool/cron/crontabs/" \
  "ssh h 'sudo cp -a /etc/cron.d/ /root/bak/cron.d/'" \
  "scp -r h:/etc/cron.d/ ./snapshots/prod-host/cron.d/" \
  "docker cp app:/etc/cron.d/ ./snap/cron.d/" \
  "cat /etc/cron.d/backup | tee /tmp/snap/cron.d/backup" \
  "rsync -a /etc/cron.d/ /root/backup/cron.d-2026-09-25/" \
  "sudo cp /etc/crontab /etc/crontab.bak" \
  "journalctl --since today | grep -iE 'cron|crontab'" \
  "grep -E \"REPLACE|crontab\" /var/log/syslog" \
  "ls -l \$(which crontab) /var/spool/cron/crontabs" \
  "find / -name \"crontab*\" 2>/dev/null" \
  "find / -name crontab -type f 2>/dev/null" \
  "crontab -l > ~/crontab-\$(date +%F).bak" \
  "crontab -l | tee /tmp/crontab-root.txt" \
  "if [ -n \"\$(crontab -l 2>/dev/null)\" ]; then echo есть; fi" \
  "journalctl -t crontab --since today" \
  "sudo crontab -l          # личное расписание root" \
  $'crontab -l \\\n  | grep -v \'^#\'' \
  "zgrep crontab /var/log/syslog.2.gz" \
  "crontab -u \$(id -un) -l" \
  "diff <(crontab -l) /tmp/cron.expected" \
  "run-parts --test /etc/cron.daily" \
  "sed -n '1,20p' /etc/cron.d/backup" \
  "crontab -T /tmp/new.cron" \
  "crontab -V" \
  "perl -ne 'print' /etc/nginx/nginx.conf" \
  "certbot certificates" \
  "sudo certbot certificates 2>/dev/null | grep -E \"Domains|Expiry\"" \
  "ls -la /etc/cron.d/certbot /lib/systemd/system/certbot.timer" \
  "acme.sh --list"; do
  n=$((n+1)); mk "$TMP/cronro$n.jsonl" "Bash:$c"
  check pass "просмотр: ${c:0:60}" "$TMP/cronro$n.jsonl"
done

echo "[2б] Запись расписания — останавливаем при любой форме"
# Установочная строка берётся ИЗ ШАБЛОНА скилла, а не из головы (правило 2 свода замков):
# именно ею setup-backups кладёт расписание, и замок её раньше не видел.
TPL="$HERE/../skills/setup-backups/templates/backup-cron-d"
INSTALL_LINE="$(sed -n 's/^#[[:space:]]*\(install -m [0-9]* .*cron\.d.*\)$/\1/p' "$TPL" | head -1)"
if [ -z "$INSTALL_LINE" ]; then
  FAIL=$((FAIL+1)); echo "  ❌ потерян источник: в $TPL нет строки install … /etc/cron.d/…"
fi
n=0
for c in \
  "(crontab -l; echo \"0 3 * * * /opt/x.sh\") | crontab -" \
  "crontab -l | sed '/old-job/d' | crontab -" \
  "echo '*/5 * * * * /opt/check.sh' | sudo crontab -u root -" \
  "echo '* * * * * /opt/x' | crontab" \
  "ssh prod-host 'crontab /tmp/new.cron'" \
  "ssh prod-host 'sudo crontab -r'" \
  "crontab -e" \
  "ssh prod-host \"crontab -l > /tmp/c; echo x >> /tmp/c; crontab /tmp/c\"" \
  "crontab < /tmp/new.cron" \
  "ssh prod-host 'sudo $INSTALL_LINE'" \
  "ssh prod-host \"sudo sed -i 's/^0 22/0 21/' /etc/cron.d/backup\"" \
  "cat new.cron | ssh prod-host 'sudo tee /etc/cron.d/backup >/dev/null'" \
  "ssh prod-host 'sudo cp backup.cron /etc/cron.d/ 2>&1'" \
  "/usr/bin/crontab -r" \
  "sudo /usr/bin/crontab -u app /tmp/new.cron" \
  "ssh h 'crontab -l | grep -v old-job | /usr/bin/crontab -'" \
  "\\crontab -r" \
  "crontab <(crontab -l | grep -v old-job)" \
  "crontab < <(crontab -l; echo \"0 3 * * * /opt/b.sh\")" \
  "crontab <<<\"\$(crontab -l; echo '0 3 * * * /opt/b.sh')\"" \
  "sudo cp /root/crontab /etc/crontab" \
  "sudo cp new.cron /var/spool/cron/crontabs/app" \
  "sudo cp backup.cron /etc/cron.d" \
  "scp backup.cron root@h:/etc/cron.d/backup" \
  "sudo cp backup.cron /etc/cron.d/backup 2> /dev/null" \
  "sudo cp -t /etc/cron.d/ backup.cron" \
  "sudo sed -i.bak 's/^0 3/0 4/' /etc/cron.d/backup" \
  "sudo sed -e 's/^0 3/0 4/' -i /etc/crontab" \
  "sudo mv /etc/cron.d/backup /root/backup.cron.disabled" \
  "ssh h 'sudo rm -f /etc/cron.d/old-job'" \
  "echo '0 3 * * * root /opt/b.sh' > /etc/cron.d/backup" \
  "sudo sh -c 'echo \"0 3 * * * root /opt/b.sh\" >> /etc/crontab'" \
  $'ssh root@h \'cat > /etc/cron.d/backup\' <<\'EOF\'\n0 3 * * * root /opt/b.sh\nEOF' \
  "sudo ln -s /opt/app/app.cron /etc/cron.d/app" \
  "sudo cp backup.sh /etc/cron.daily/backup" \
  "echo x | sudo tee -a /var/spool/cron/root" \
  $'cat new.cron |\n  crontab' \
  "find /tmp -name new.cron -exec crontab {} \\;" \
  "sudo perl -pi -e 's/^0 3/0 4/' /etc/cron.d/backup" \
  "printf 'x' | sudo dd of=/etc/cron.d/backup" \
  "sudo sed -i 's/^1/2/' /etc/anacrontab" \
  "docker exec app sh -c 'echo x >> /etc/crontabs/root'" \
  "sudo certbot certonly --nginx -d x.kz" \
  "acme.sh --issue -d x.kz"; do
  n=$((n+1)); mk "$TMP/cronrw$n.jsonl" "Bash:$c"
  check block "запись: ${c:0:60}" "$TMP/cronrw$n.jsonl"
done

echo "[2в] Историческая версия (до 25.09.2026) обязана ложно ловить просмотр — тест не слеп"
# Без этой секции [1б] была бы зелёной и на сломанном замке, если бы случаи вдруг
# перестали доходить до правила. Берём хук из истории git, а не из головы.
OLD_HOOK="$TMP/old-guard.sh"
if ( cd "$HERE" && MSYS_NO_PATHCONV=1 git show "25424f7:.claude/hooks/inventory-sync-guard.sh" ) > "$OLD_HOOK" 2>/dev/null \
   && [ -s "$OLD_HOOK" ]; then
  SAVED_HOOK="$HOOK"; HOOK="$OLD_HOOK"
  mk "$TMP/hist1.jsonl" "Bash:sudo crontab -u root -l"
  check block "старый замок останавливал на crontab -l (дефект виден)" "$TMP/hist1.jsonl"
  # И обратная сторона: установку расписания в /etc/cron.d старый замок не видел —
  # значит случай из [2б] ловит настоящую дыру, а не то, что и так ловилось.
  mk "$TMP/hist2.jsonl" "Bash:ssh prod-host 'sudo $INSTALL_LINE'"
  check pass "старый замок пропускал install в /etc/cron.d (дыра видна)" "$TMP/hist2.jsonl"
  HOOK="$SAVED_HOOK"
else
  FAIL=$((FAIL+1)); echo "  ❌ потерян источник: нет 25424f7 (релиз 2.12.2) в истории"
fi

echo "[2г] Запись файлов в конфиги сервера — любым способом (с 25.09.2026)"
# До этого замок видел запись через `>` и `install` только в файлы расписания. Среди случаев —
# команды сессии 25.09.2026 (имена хостов обобщены), которые меняли сервер, а замок их бы не заметил.
n=0
for c in \
  "echo 'server {}' > /etc/nginx/conf.d/a.conf" \
  "sudo sh -c 'echo X=1 >> /opt/app/.env'" \
  "cat new.service | sudo tee /etc/systemd/system/x.service >/dev/null" \
  "ssh office-host 'sudo tee /opt/bots/compose/app/compose.yml >/dev/null' < compose.yml" \
  "ssh prod-host 'sudo install -m 755 -o root -g root /tmp/new-x.sh /opt/infra/scripts/backup/x.sh'" \
  "ssh office-host 'sudo install -d -o root -g root -m 755 /opt/bots/app'" \
  "ssh prod-host 'sudo tee /etc/systemd/system/db-pull.timer >/dev/null' < t.timer" \
  "sudo cp nginx.conf /etc/nginx/nginx.conf" \
  "rsync -a ./site/ root@h:/var/www/site/" \
  "scp app.env root@h:/opt/app/.env" \
  "sudo sed -i 's/^#Port 22/Port 2222/' /etc/ssh/sshd_config" \
  "sudo rm /etc/nginx/sites-enabled/default" \
  "sudo mv /etc/nginx/sites-enabled/old /root/disabled/" \
  "echo 'ssh-ed25519 AAAAC3Nz x' >> /root/.ssh/authorized_keys" \
  "printf 'vm.swappiness=10\\n' | sudo dd of=/etc/sysctl.d/99-x.conf" \
  "sudo perl -pi -e 's/old/new/' /etc/hosts" \
  "bash scripts/bots/deploy-app.sh" \
  "ssh office-host 'sudo /opt/bots/scripts/deploy-bot.sh'"; do
  n=$((n+1)); mk "$TMP/cfgrw$n.jsonl" "Bash:$c"
  check block "запись: ${c:0:60}" "$TMP/cfgrw$n.jsonl"
done
n=0
for c in \
  "ssh h 'cat /etc/nginx/nginx.conf' > ./nginx.conf" \
  "sudo cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak" \
  "scp root@h:/etc/nginx/nginx.conf /tmp/" \
  "docker cp app:/etc/nginx/nginx.conf ./" \
  "sudo apt install -y sqlite3" \
  "pip install -r /opt/app/requirements.txt" \
  "git mv docs/a.md docs/b.md" \
  "echo x > /tmp/out.txt" \
  "sudo journalctl -u nginx > /tmp/nginx-journal.txt" \
  "grep -r listen /etc/nginx/ > /tmp/listen.txt" \
  "ssh h 'sudo sqlite3 /var/lib/app/db.sqlite \".backup /tmp/x.db\"'" \
  "sudo rm -f /opt/app/cache/x.tmp" \
  "sed -n '1,20p' /etc/ssh/sshd_config" \
  "ssh prod-host 'sudo cp -p /etc/cron.d/backup /root/cron.d-backup.bak-2026-09-25'" \
  "git show HEAD:x.sh | ssh prod-host 'cat > /tmp/new-x.sh'"; do
  n=$((n+1)); mk "$TMP/cfgro$n.jsonl" "Bash:$c"
  check pass "не правка: ${c:0:60}" "$TMP/cfgro$n.jsonl"
done

echo "[2д] Формы второго раунда независимой проверки (кавычки, cd, обёртки, флаги) — 25.09.2026"
# `|` и `;` внутри кавычек-данных больше не режут команду: правка sed с разделителем `|` и
# директивы nginx с `;` раньше проходили молча. Относительный путь после `cd /abs` понимается.
n=0
for c in \
  "ssh prod-host \"sudo sed -i 's|proxy_pass http://127.0.0.1:3000|proxy_pass http://127.0.0.1:4000|' /etc/nginx/sites-available/site\"" \
  "ssh prod-host 'sudo sed -i \"s/listen 80;/listen 8080;/\" /etc/nginx/sites-available/default'" \
  "sudo sed -i 's/^PermitRootLogin yes/PermitRootLogin no # hardening/' /etc/ssh/sshd_config" \
  "ssh prod-host 'cd /opt/app && echo \"LOG_LEVEL=debug\" >> .env'" \
  "ssh prod-host 'sudo -u deploy bash -c \"cd /opt/site && git fetch && git reset --hard origin/main\"'" \
  "ssh prod-host 'sudo /opt/app/redeploy.sh'" \
  "ssh prod-host 'sudo /opt/bots/bot_deploy.sh'" \
  "ssh prod-host 'sudo /usr/local/sbin/deploy-run site'" \
  "ssh prod-host '\\cp -f /opt/infra/cron/backup /etc/cron.d/backup'" \
  "sudo -u git cp /tmp/mirror.cron /etc/cron.d/mirror" \
  "sudo bash -c '/opt/x/gen-cron.sh &>> /etc/cron.d/gen'" \
  "ssh prod-host 'sudo mv -t /root/cron-off/ /etc/cron.d/backup-old'" \
  "ssh prod-host 'sudo mv /etc/systemd/system/x.service /etc/systemd/system/x.service.bak'" \
  "ssh prod-host \"sudo find /tmp/conf -name '*.conf' -exec cp {} /etc/nginx/conf.d/ \\;\"" \
  "ssh prod-host 'sudo install /tmp/app.service /etc/systemd/system/app.service -m 644'" \
  "sudo wget -qO /etc/logrotate.d/app https://example.org/x" \
  "ssh prod-host 'echo \"ssh-ed25519 AAAA x\" >> ~/.ssh/authorized_keys'" \
  "ssh-copy-id -i ~/.ssh/id_ed25519.pub deploy@prod-host" \
  "ssh prod-host 'sudo touch /etc/deploy-hook/DISABLED'" \
  "ssh prod-host 'sudo htpasswd -bc /etc/nginx/.htpasswd admin x'" \
  "ssh prod-host 'sudo ufw default deny incoming'" \
  "ssh prod-host 'sudo usermod -aG docker deploy'" \
  "ssh prod-host 'sudo tar -xzf /tmp/nginx-conf.tgz -C /etc/nginx'" \
  "scp .env root@prod-host:/root/app-bot/.env" \
  "ssh prod-host 'sudo x-ui restart'"; do
  n=$((n+1)); mk "$TMP/r2rw$n.jsonl" "Bash:$c"
  check block "запись: ${c:0:60}" "$TMP/r2rw$n.jsonl"
done
n=0
for c in \
  "git -C /c/Users/me/Projects/infra diff scripts/bots/deploy-app.sh" \
  "git add scripts/bots/deploy-app.sh" \
  "ssh prod-host 'cat /opt/infra/scripts/deploy-app.sh'" \
  "bash -n scripts/bots/deploy-app.sh" \
  "sudo cp /etc/nginx/sites-available/site.conf{,.bak}" \
  "cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.2026-09-25" \
  "cp -a /etc/nginx /etc/nginx-backup-20260925" \
  "rsync -avn ./nginx/ prod-host:/etc/nginx/" \
  "ssh prod-host 'docker exec pg pg_dump -U app app > /opt/backups/app-2026-09-25.sql'" \
  "crontab -l | ssh backup-host \"cat > /srv/snap/prod-host-root.cron\"" \
  "ssh prod-host 'sudo rm -rf /root/.cache/pip'" \
  "ssh prod-host 'pip -q install -r /opt/bot/requirements.txt'" \
  "ssh prod-host 'sudo nginx -T 2>&1 | tee /tmp/nginx-T.txt'" \
  "[ \"\$(crontab -l | wc -l)\" -gt 0 ] && echo yes" \
  "ssh-keyscan example.kz >> ~/.ssh/known_hosts" \
  "sed -n 's|listen 80;|X|p' /etc/nginx/sites-available/default" \
  "sudo apt update" \
  "yq '.services' /opt/app/docker-compose.yml" \
  "ssh prod-host 'sudo sqlite3 /etc/x-ui/x-ui.db \"SELECT * FROM settings\"'" \
  "ssh prod-host 'sudo tar -czf /tmp/etc.tgz /etc/nginx'"; do
  n=$((n+1)); mk "$TMP/r2ro$n.jsonl" "Bash:$c"
  check pass "не правка: ${c:0:60}" "$TMP/r2ro$n.jsonl"
done

echo "[2е] Тело heredoc — данные, если его читает не оболочка (25.09.2026)"
# Ложные остановки в самой сессии правки замка: текст коммита `git commit -F - <<EOF` с
# упоминанием `ufw default` и `git pull` принимался за команды. Командами тело бывает, только
# если его читает оболочка — ssh без команды, `bash -s`, `sudo -s`.
n=0
for c in \
  $'git commit -q -F - <<\'EOF\'\nfix: ufw default deny, systemctl edit x, git pull в /opt/app\nsudo cp x /etc/nginx/nginx.conf\nEOF' \
  $'cat > /tmp/notes.md <<\'EOF\'\nsudo systemctl restart nginx\necho X >> /opt/app/.env\nEOF' \
  $'gh pr create --title x --body-file - <<\'EOF\'\n- ufw enable, hostnamectl set-hostname, useradd deploy\nEOF' \
  $'cat > run.sh <<\'EOF\'\n#!/usr/bin/env bash\ndocker compose up -d\nEOF' \
  $'python - <<\'PY\'\nprint("mv /etc/x /root/y")\nPY'; do
  n=$((n+1)); mk "$TMP/hdro$n.jsonl" "Bash:$c"
  check pass "тело — данные: ${c:0:50}" "$TMP/hdro$n.jsonl"
done
n=0
for c in \
  $'ssh prod-host <<\'EOF\'\nsudo systemctl restart nginx\nEOF' \
  $'ssh prod-host \'bash -s\' <<\'EOF\'\nsudo cp /tmp/x.conf /etc/nginx/nginx.conf\nEOF' \
  $'bash <<\'EOF\'\nsudo ufw default deny incoming\nEOF' \
  $'ssh prod-host sudo -s <<\'EOF\'\necho X=1 >> /opt/app/.env\nEOF' \
  $'sudo tee /etc/systemd/system/x.service > /dev/null <<\'EOF\'\n[Service]\nEOF' \
  $'git commit -q -m x <<\'EOF\'\nтекст\nEOF\nsudo systemctl restart nginx' \
  $'grep -n "<<\'PY\'" hook.sh\nssh prod \'sudo systemctl restart nginx\'' \
  $'# запись через cat <<EOF, см. ниже\nssh prod \'sudo systemctl restart nginx\'' \
  $'ssh -o ConnectTimeout=5 \\\n    root@prod <<\'EOF\'\nsudo systemctl restart nginx\nEOF' \
  $'cat <<\'EOF\' | ssh prod \'sudo bash -s\'\nsystemctl restart nginx\nEOF' \
  $'timeout 120 ssh prod \'bash -s\' <<\'EOF\'\nsudo systemctl restart nginx\nEOF' \
  $'sudo -iu root bash <<\'EOF\'\nsystemctl restart nginx\nEOF' \
  $'git commit -q -m "$(cat <<\'EOF\'\nfix: x\nEOF\n)" && ssh prod \'cd /opt/app && git pull\'' \
  $'/usr/bin/ssh prod <<\'EOF\'\nsudo systemctl restart nginx\nEOF' \
  $'expect <<\'EOF\'\nsudo systemctl restart nginx\nEOF' \
  $'bash -c "$(cat <<\'EOF\'\nsystemctl restart nginx\nEOF\n)"'; do
  n=$((n+1)); mk "$TMP/hdrw$n.jsonl" "Bash:$c"
  check block "тело — команды или запись: ${c:0:45}" "$TMP/hdrw$n.jsonl"
done
n=0
for c in \
  $'git commit -q \\\n  -F - <<\'EOF\'\nfix: ufw default deny\nEOF' \
  $'MSG=$(cat <<\'EOF\'\nfix: systemctl restart nginx\nEOF\n)' \
  $'cat > /tmp/fix.sh <<\\EOF\nsudo systemctl restart nginx\nEOF' \
  $'ssh prod \'bash -s\' <<\'OUTER\'\ncat > /tmp/note <<\'EOF\'\nsystemctl restart nginx\nEOF\nOUTER' \
  $'bash ./configure-answers.sh <<\'EOF\'\nsudo systemctl restart nginx\nEOF' \
  $'ssh prod \'cat > /tmp/note.txt\' <<\'EOF\'\nsudo systemctl restart nginx\nEOF' \
  $'ssh prod "sudo -u postgres psql app" <<\'SQL\'\n-- systemctl restart nginx\nSELECT 1;\nSQL' \
  $'jq -r \'.[] | .name\' <<\'EOF\'\n[{"name":"sudo systemctl restart nginx"}]\nEOF' \
  $'docker compose exec -T db psql -U app <<\'SQL\'\n-- systemctl restart nginx\nSQL' \
  $'gh pr create --title "fix(hooks): x" \\\n  --body-file - <<\'EOF\'\n- ufw default deny incoming\nEOF' \
  $'PYTHONIOENCODING=utf-8 python - "$(cygpath -m x.py)" <<\'PYEOF\'\nprint("mv /etc/x /root/y")\nPYEOF'; do
  n=$((n+1)); mk "$TMP/hdro2$n.jsonl" "Bash:$c"
  check pass "тело — данные (формы проверки): ${c:0:40}" "$TMP/hdro2$n.jsonl"
done

echo "[2] Изменение без обновления inventory — останавливаем"
mk "$TMP/change1.jsonl" "Bash:ssh prod-host 'docker compose up -d academii'"
check block "docker compose up" "$TMP/change1.jsonl"
mk "$TMP/change2.jsonl" "Bash:ssh prod-host 'systemctl restart nginx'"
check block "systemctl restart" "$TMP/change2.jsonl"
mk "$TMP/change3.jsonl" "Bash:ssh prod-host 'ufw allow 8443'"
check block "правило firewall" "$TMP/change3.jsonl"
mk "$TMP/change4.jsonl" "Bash:ssh prod-host 'docker network create services'"
check block "новая сеть" "$TMP/change4.jsonl"

echo "[2а] Выкатка скриптом-обёрткой — тоже изменение (пропуск 2026-08-04)"
# Ожог: весь IaC-контур устроен обёрткой — реальные `git pull` и `docker compose up`
# живут ВНУТРИ скрипта на сервере, а в ход попадает только его вызов. Замок ловил
# прямые команды и молчал на обёртке: выкатка пересоздала контейнер, ответ закончился
# словами «инфраструктуру это не меняло», отставание снимка заметил оператор.
mk "$TMP/wrap1.jsonl" "Bash:./scripts/deploy/deploy-remote.sh prod-host"
check block "деплой с ноутбука" "$TMP/wrap1.jsonl"
mk "$TMP/wrap2.jsonl" "Bash:ssh prod-host 'cd /opt/infra && ./deploy.sh'"
check block "серверный deploy.sh" "$TMP/wrap2.jsonl"
mk "$TMP/wrap3.jsonl" "Bash:cd ~/Projects/app && ./deploy.sh"
check block "деплой чужого проекта" "$TMP/wrap3.jsonl"
mk "$TMP/wrap4.jsonl" "Bash:ssh prod-host 'cd /opt/apps/bot && ./update.sh'"
check block "update.sh" "$TMP/wrap4.jsonl"
# Граница: упоминание внутри read-only команды изменением не считается (правило 4).
mk "$TMP/wrap5.jsonl" "Bash:grep -n 'deploy.sh' README.md"
check pass "grep со словом deploy.sh" "$TMP/wrap5.jsonl"
mk "$TMP/wrap6.jsonl" "Bash:cat scripts/deploy/deploy-remote.sh"
check pass "чтение самого скрипта выкатки" "$TMP/wrap6.jsonl"

echo "[3] Изменение + обновление inventory — пропускаем"
mk "$TMP/ok1.jsonl" "Bash:ssh prod-host 'docker compose up -d'" "Edit:/infra/inventory/hosts/prod-host/services.md"
check pass "правка inventory в том же ходе" "$TMP/ok1.jsonl"
mk "$TMP/ok2.jsonl" "Bash:ssh prod-host 'systemctl restart nginx'" "Bash:ssh prod-host '/opt/infra-dashboard/bin/refresh.sh'"
check pass "пересборка снимка/дашборда" "$TMP/ok2.jsonl"
mk "$TMP/ok3.jsonl" "Bash:ssh prod-host 'docker compose up -d'" "Bash:bash scripts/dump-snapshot.sh prod-host"
check pass "пересъёмка снимка" "$TMP/ok3.jsonl"

echo "[4] Защита от зацикливания"
mk "$TMP/loop.jsonl" "Bash:ssh prod-host 'docker compose restart api'"
check block "первый раз останавливаем" "$TMP/loop.jsonl"
check pass  "второй раз тот же ход — пропускаем (метка)" "$TMP/loop.jsonl"
mk "$TMP/loop2.jsonl" "Bash:ssh prod-host 'docker compose restart web'"
check pass  "stop_hook_active=true — пропускаем" "$TMP/loop2.jsonl" true

echo "[5] Fail-open: непонятный вход не мешает работе"
printf 'не json' | TMPDIR="$MARKS" bash "$HOOK" >/dev/null 2>&1 && { PASS=$((PASS+1)); echo "  ✅ мусор на входе"; } \
  || { FAIL=$((FAIL+1)); echo "  ❌ мусор на входе уронил хук"; }
echo '{"session_id":"x","transcript_path":"/nope/none.jsonl"}' | TMPDIR="$MARKS" bash "$HOOK" >/dev/null 2>&1 \
  && { PASS=$((PASS+1)); echo "  ✅ транскрипта нет"; } || { FAIL=$((FAIL+1)); echo "  ❌ упал без транскрипта"; }

echo "[6] Вердикт доходит и при чужой кодовой странице консоли (правило 3д)"
# Дефект 26.08.2026: сторож печатал ответ через python, а консоль на Windows в cp1252 —
# python падал на первом же русском символе, хук не печатал НИЧЕГО и выходил с кодом 0.
# Движок читает это как «возражений нет»: 9 случаев из 9 проходили как разрешённые.
# Лечится строкой `export PYTHONIOENCODING=utf-8` в шапке ХУКА, но проверять её надо
# отдельным случаем: своим таким же export (шапка этого файла) тест лечит хук ЗА НЕГО —
# переменная наследуется дочернему процессу, и убери её из хука, итог останется зелёным.
# Здесь кодировка навязывается ИМЕННО ХУКУ, перекрывая наследство.
HOOK_ENC=cp1252
mk "$TMP/enc.jsonl" "Bash:ssh prod-host 'docker compose up -d academii'"
check block "остановка доходит при cp1252-консоли" "$TMP/enc.jsonl"
check pass  "read-only при cp1252 не трогаем"      "$TMP/ro.jsonl"
# Отдельный транскрипт: предохранитель «один блок на ход» опознаёт ход по имени файла,
# и повторный прогон того же случая хук законно пропустил бы.
mk "$TMP/enc2.jsonl" "Bash:ssh prod-host 'docker compose up -d academii'"
ENC_OUT="$(run "$TMP/enc2.jsonl" 2>/dev/null)"
if printf '%s' "$ENC_OUT" | grep -q 'инфраструктура изменилась'; then
  PASS=$((PASS+1)); echo "  ✅ русский текст причины не искажён"
else
  FAIL=$((FAIL+1)); echo "  ❌ причина при cp1252 пуста или искажена"
fi
unset HOOK_ENC

echo "─────────────────────────────────────────────────────────"
printf 'Итог: %d прошло, %d провалено\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
