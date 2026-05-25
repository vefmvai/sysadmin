# dump-snapshot.sh — известные квирки и обходы

Памятка для скилла `inventory-scan`. Здесь собраны типичные баги, симптомы
и обходы, наблюдавшиеся при инвентаризации обжитых серверов. Когда snapshot
ведёт себя странно — сначала проверяем здесь.

---

## tls-certs.txt — пустой или с syntax error

**Симптом v1:** файл `tls-certs.txt` содержит `unexpected end of file` или
`unmatched '`. Даты сертификатов не выдаёт.

**Причина:** в первой версии скрипта внутри двойных кавычек был
неэкранированный апостроф в `Let's Encrypt`. Bash парсил его как начало
строки, и вся подоболочка валилась.

**Лечение в v2 (bundled):** обёрнуто в `set +e; ... ; true`. Если openssl
не найдёт сертификат — пишем пустоту, не валим скрипт. Для acme.sh добавлен
отдельный `ls ~/.acme.sh/*/fullchain.cer`.

**Открытое (пример honest-unknown):** некий домен `<example.com>` имеет
работающий TLS-сертификат, но он не в стандартных папках (`/etc/letsencrypt/`,
`~/.acme.sh/`) — источник неизвестен. Записывается в inventory как
`tls_source = ? уточнить` + todo с расследованием.

---

## SSH-alias из ~/.ssh/config не работает в bash sandbox

**Симптом:** `ssh prod-server 'echo ok'` падает с
`Could not resolve hostname prod-server`, хотя из обычного терминала
работает.

**Причина:** агентский bash sandbox не загружает пользовательскую
конфигурацию SSH (нет `~/.ssh/config` в search path или `BatchMode=yes`
не пускает). Алиасы из ProxyJump-конфигов тоже не работают.

**Обход:** в `dump-snapshot.sh` всегда передавать прямой `user@host`,
а не алиас. Если нужен явный ключ — `-i ~/.ssh/id_<key>`.

---

## stderr самого ssh-клиента попадал в файлы снимка (fix v1.4.3)

**Симптом:** в файлах снимка (`containers.txt`, `networks.txt` и др.) среди
данных встречаются строки вида `mux_client_request_session: ... Connection
reset by peer`, `** WARNING: connection is not using a post-quantum key
exchange algorithm`, `ControlSocket ... already exists, disabling
multiplexing`. Особенно заметно на Windows / OpenSSH 9.x с `ControlMaster auto`
в `~/.ssh/config` оператора. Ручная чистка `sed`-ом не идемпотентна — следующий
`/inventory-scan` соберёт мусор заново.

**Причина:** старая строка `run_cmd "$cmd" 2>&1 | redact_stream > "$outfile"`
сливала в один поток stderr **двух** источников: (1) удалённой команды —
полезно, и (2) локального `ssh`-клиента — шум транспорта. После `2>&1`
отличить их уже нельзя.

**Лечение (v1.4.3), два рычага:**

1. **Заглушить ssh-клиентский шум у источника** — в `run_cmd`:
   `ssh -o LogLevel=ERROR -o ControlMaster=no ...`. `LogLevel=ERROR` убирает
   WARNING/INFO (post-quantum warning, ControlSocket-болтовню), но пропускает
   ERROR/FATAL — реальные сбои соединения видны. `ControlMaster=no` отключает
   мультиплексирование оператора для этих коротких команд (источник
   `mux_client_request_session`).
2. **Разделить потоки в `run_remote`** — stdout (данные) → файл снимка,
   stderr (диагностика удалённой команды) → отдельный `<label>.stderr.log`
   рядом, **только если он непустой** (не плодим пустые файлы; команды с
   `2>/dev/null` внутри их не создают). ОБА потока проходят `redact_stream` —
   stderr тоже может содержать секрет (ошибка с connection-string), маскировка
   везде (приоритет №1 CLAUDE.md). Зафиксировано в ADR-0009.

**Класс файлов `*.stderr.log`** — нормальный продукт скана, не сбой. Появляется
рядом с секцией, если удалённая команда что-то написала в stderr. Verify
«≥16 файлов» он не ломает (только добавляет). Снимки живут в приватной `infra/`
— версионирование `.stderr.log` решает оператор в своём `.gitignore`.

---

## find -mtime +N округляет вниз

**Симптом:** `find -mtime +1` пропускает файлы, которые «вчера», но
ещё не прошло 48 часов с их создания.

**Причина:** `-mtime +N` означает «возраст СТРОГО больше N полных дней».
Файл, созданный 30 часов назад, имеет возраст 1 полный день — не больше.

**Обход для retention snapshot'ов:** сортировать по имени, не по `-mtime`:

```bash
find "$SNAPSHOTS_DIR" -mindepth 1 -maxdepth 1 -type d \
  | sort -r | tail -n +$((RETENTION+1)) | xargs -r rm -rf
```

Snapshot'ы датированы (YYYY-MM-DD), сортировка по имени = сортировка по
дате. Никаких сюрпризов с округлением.

---

## host-env-redacted.txt — пароли в URL не маскируются

**Симптом:** в `.env` есть `DATABASE_URL=postgres://user:secret@host/db`.
Скрипт маскирует через `sed "s/=.*/=<HIDDEN>/"` — значит, `DATABASE_URL`
будет полностью скрыт, **но** при сравнении с реальным `.env` в `inventory`
оператор может увидеть полный URL в каком-то документе, забыв про маскирование.

**Лечение:** до коммита inventory-документов агент **обязан** запустить
gitleaks. Файл `containers-inspect.json` всегда даёт ~40 false positives
(env-переменные внутри контейнеров) — это ожидаемо, пропускаем.

---

## containers-inspect.json — env-переменные plain text (ИСПРАВЛЕНО)

**Симптом (до фикса):** `docker inspect` выдавал env-переменные контейнера
без маскирования. Пароли БД, JWT-секреты, API-ключи (`OPENROUTER_API_KEY`,
`BOT_TOKEN` и т.п.) были видны открытым текстом. Файл мог случайно уйти
в коммит (`git add -A`), bug-report или rsync-бэкап — а `.gitignore` это
лишь последний рубеж, не основная защита.

**Исправлено в коде (redaction v2).** `dump-snapshot.sh` теперь маскирует
секреты **до записи на диск**, а не полагается только на `.gitignore`.
Маскировка закрывает четыре паттерна:
1. `KEY=value`, где секрет-слово (`TOKEN/KEY/SECRET/PASSWORD/PASS/API/CREDENTIAL`,
   case-insensitive) стоит **где угодно в имени** переменной (не только в конце) →
   `KEY=<REDACTED>` (имя сохраняется для аудита). Так ловятся и `AWS_ACCESS_KEY_ID=`,
   и `API_TOKEN_PROD=`, а не только `*_KEY=`/`*_TOKEN=` (v1 ловил только суффикс).
2. Креды в URL: `scheme://user:pass@host` → `scheme://user:<REDACTED>@host`.
3. Секрет в query-string: `?secret=...&token=...` → `?secret=<REDACTED>`.
4. AWS access key ID по значению: `AKIA`/`ASIA` + 16 символов `[A-Z0-9]` →
   `<REDACTED>` (ловит идентификатор даже голым в логе, без обёртки `KEY=`).
   Паттерн без `\b` — `\b` не работает в BSD sed на macOS (кросс-платформенность).

Реализация — **без жёсткой зависимости от `jq`** (его часто нет на
macOS/Git-for-Windows у оператора, через которого проходит snapshot,
см. инцидент Windows-портабельности). Если `jq` есть — structurally-aware
redaction `.Config.Env`; если нет — построчный fallback на `sed`. Оба
пути дополнительно прогоняют URL-паттерн (одного `jq` мало: переменная
вида `DATABASE_URL` не матчит секрет-паттерн по имени, и пароль внутри
URL утекал бы — проверено тестом).

В снимке рядом — метки в `meta.txt`: `redaction_applied: true`,
`redaction_version: v2`, `redaction_tool: jq|sed-fallback` — при ревью
сразу видно, что данные не raw.

**Что осталось на операторе:**
1. Файл всё равно лежит в `inventory/hosts/<host>/snapshots/<DATE>/` —
   папка snapshots в `.gitignore` (правило этапа 1). Маскировка — основная
   защита, `.gitignore` — дублирующий рубеж.
2. В публичные документы (`services.md`) этот файл не копируется
   целиком — только нужные поля, без env-секции.

---

## TLS-сертификаты вне стандартных путей

**Симптом:** `tls-certs.txt` пустой, но HTTPS на сервере работает.

**Причина:** сертификат может быть выписан через другой ACME-клиент
(certbot, lego, dehydrated) и лежать в нестандартном пути. Или это
коммерческий сертификат, выпущенный вручную.

**Обход:** дополнительно проверить руками:
- `nginx -T | grep -E '(ssl_certificate|listen 443)'` — какой путь
  использует nginx
- `find / -name 'fullchain.pem' 2>/dev/null` — на свой страх и риск
- если не нашлось — `tls_source = ? уточнить` в domains.md

---

## ss vs netstat — может не быть ни того, ни другого

**Симптом:** в `host-resources.txt` секция «открытые порты» пустая или
содержит «команда не найдена».

**Причина:** минималистичные образы (alpine, distroless) могут не иметь
ни `ss` (часть iproute2), ни `netstat` (часть net-tools).

**Обход:** скрипт уже пробует обе. Если обе отсутствуют — пишет
«ss/netstat не найден», операторская задача добавить хотя бы iproute2:
`apt install iproute2` или эквивалент.

---

## docker system df -v — не показывает размер external volume

**Симптом:** `volumes.txt` показывает `<external-volume-name>` как 0 B, хотя
в нём гигабайты данных.

**Причина:** external volume Docker не может смерить через `system df`,
потому что не он его создавал. `system df` работает только с volume,
который Docker сам создал в рамках compose-проекта.

**Обход:** для external volume размер брать через
`du -sh /var/lib/docker/volumes/<name>/_data` (требует root на сервере).
В inventory `size = ? уточнить (external)` — это валидный honest unknown.

---

## Системные/snap-юниты загромождают systemd-enabled.txt

**Симптом:** список включённых юнитов 200+ строк, в основном `systemd-*`,
`sys-*`, `snap.*`.

**Лечение:** скрипт фильтрует через
`grep -vE '^(UNIT|[0-9]+ unit|systemd-|sys-|snap\.)'` и берёт первые 50
строк. Если оператор хочет увидеть всё — запустить вручную без фильтра.

---

## systemd-timers.txt: штатные таймеры маскируют таймеры оператора

**Симптом:** `systemctl list-timers` показывает десятки штатных таймеров
(`apt-daily`, `man-db`, `logrotate`, `fstrim`, `e2scrub`, `fwupd`-refresh),
среди которых теряется заведённый оператором `backup.timer` или `pipeline.timer`.

**Лечение:** секция `systemd-timers.txt` фильтрует список `*.timer`-юнитов тем же
подходом, что и `systemd-enabled.txt` — исключает `systemd-/sys-/snap./snapd./apt-/
man-db/logrotate/fstrim/e2scrub/fwupd/...`, оставляя юниты оператора. `list-timers` (с
расписанием next/last) выводится целиком — расписание читается оттуда, а `systemctl
cat` показывает только отфильтрованные юниты. На хосте без systemd (контейнер,
macOS-local) — honest unknown «нет данных (systemctl недоступен)», снимок не падает
(`set +e`).

**Граблекейс selectel (2026-05-24, расширение фильтра):** на боевом сервере в
«операторские» таймеры просочились штатные `chrony-dnssrv@`, `mdadm-last-resort@`,
`mdcheck_start/continue`, `mdmonitor-oneshot`, `ua-timer`, `snapd.snap-repair` — их
префиксы (`chrony-`, `mdadm-`, `mdcheck`, `mdmonitor`, `ua-timer`, `snapd.`) не были
в исключениях, и реальный сигнал (`newsforge-collector*`) тонул в 7 строках шума.
Фильтр расширен: добавлены `snapd.|chrony-|chronyd|mdadm-|mdcheck|mdmonitor|ua-timer|
ua_|ubuntu-advantage|raid-check|btrfs|smartd`. После фикса на selectel остаются ровно
3 операторских таймера (news-pipeline). При появлении новых ложных срабатываний —
дописывать префикс сюда, не выдумывать.

---

## watchers.txt: наблюдатель ≠ скрипт по расписанию

**Симптом:** скрипт с `inotifywait`/`fswatch`/`watchdog` виден в `systemd-enabled.txt`
как обычный сервис и неотличим от него — на карте получает роль «сервис», а не
«автоматизация-наблюдатель».

**Лечение:** секция `watchers.txt` ловит долгоживущие процессы
`ps -eo comm,args | grep -E 'inotifywait|inotifywatch|fswatch|watchmedo'`.
Это событийный триггер (`trigger: watcher` в `automations.md`), а не расписание.
Пустой набор → «пусто (file-watcher'ов не найдено)», не ошибка (`set +e` — grep на
пустом выводе возвращает ненулевой код).

**Граблекейс selectel (2026-05-24, ложное срабатывание hardware watchdog):** голый
паттерн `watchdog` ловил `watchdogd` и `/usr/sbin/watchdog` — это демон слежения за
зависанием ядра (hardware watchdog), а НЕ наблюдатель за файлами. На карте он
становился фантомной «автоматизацией-наблюдателем», которой оператор не заводил.
Паттерн сужен: `watchdog` убран, оставлены настоящие file-watcher'ы
(`inotifywait|inotifywatch|fswatch|watchmedo`), а второй `grep -vE` отсекает
hardware-демон по `/usr/sbin/watchdog` и `\bwatchdogd\b`. Python-watchdog,
запущенный как наблюдатель, ловится по `watchmedo` (его CLI). После фикса на
selectel watchers.txt честно пуст.

---

## crontab.txt и прочие секции: секрет в query-string утекал открытым текстом

**Симптом (граблекейс selectel, 2026-05-24):** в `crontab.txt` видна cron-задача
`curl "http://localhost:3100/api/cron/cleanup-orders?secret=B+SLNc55...="` — реальный
токен записан **открытым текстом**, хотя `meta.txt` рапортует `redaction_applied: true`.

**Причина — две независимые дыры:**
1. **Redaction применялся не ко всем секциям.** `redact_stream` вызывался только для
   `containers-inspect.json` и `host-env-redacted.txt`. Остальные `run_remote`-секции
   (`crontab`, `host-scripts-content`, `nginx-sites`, ...) писались на диск сырыми —
   метка `redaction_applied: true` вводила в заблуждение.
2. **Паттерн не покрывал query-string.** `redact_stream` ловил `KEY=value` и
   `scheme://user:pass@host`, но не `?secret=`/`?token=`/`?api_key=` в URL.

**Лечение:** (1) `run_remote` теперь прогоняет вывод КАЖДОЙ секции через
`redact_stream` до записи на диск — общий рубеж, не точечный. (2) в `redact_stream`
добавлен третий sed-паттерн на query-string секреты:
`[?&](secret|token|key|password|passwd|access_token|api_key|apikey|sig|signature)=`
→ `<REDACTED>`. После фикса grep по всему снимку selectel не находит незамаскированных
секретов; `?secret=<REDACTED>` в crontab.txt.

**Важно (граница):** redaction в снимке — это про то, чтобы секрет не уехал в git.
Сам секрет на сервере (в живом crontab) остаётся — его убирают отдельно, ротацией
(`/rotate-secrets`, Yellow Zone), а не этим read-only скиллом.