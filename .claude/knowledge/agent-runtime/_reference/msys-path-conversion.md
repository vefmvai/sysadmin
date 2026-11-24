---
knowledge_domain: agent-runtime
layer: reference
last_researched: 2026-10-14
ttl_days: 60
sources_checked:
  - "замер 2026-10-14, Git for Windows 2.54.0, Git Bash: пробник — нативный jq (`jq -n '$ARGS.positional' --args`), 25 форм аргумента + переменная окружения"
  - "регресс .claude/skills/configure-vpn-routing/tests/test-vless-inbound-guards.sh §3 — поймал дефект при написании, испытан на версии без защиты (2 провала)"
  - "живой случай 2026-10-14: `git show origin/main:<путь>` → fatal: ambiguous argument 'origin\\main;.claude\\…'"
---

# Git Bash переписывает POSIX-пути в аргументах нативных программ

Знание для того, кто пишет в мозге скрипт, который **выполняется у оператора**, а передаёт
программе **путь на сервере** — путь сертификата в JSON для панели, файл для `ssh`, имя в
git-объекте. На машине оператора под Windows такой путь может молча превратиться в путь
Windows, и сломается не локальная команда, а конфиг на сервере.

Повод: 14.10.2026 регресс-тест входа `vless-tls` (ADR-0045, отдельный PR) показал, что `jq --arg cert "/root/cert/…/fullchain.pem"`
отдаёт в JSON `C:/Program Files/Git/root/cert/…/fullchain.pem`. Без теста этот путь ушёл бы в
панель 3X-UI, и xray на сервере не нашёл бы сертификат.

---

## Правило. Конверсию делает среда, а не программа

Git Bash построен на MSYS2. Когда MSYS-оболочка запускает **нативную** Windows-программу
(не из `/usr/bin`), рантайм MSYS заранее переписывает аргументы и переменные окружения,
похожие на POSIX-пути, — чтобы программа Windows поняла `/c/Users/…` и `/tmp/…`. Для
локальных файлов это нужно. Для путей **другой машины** это порча.

Какие программы нативные — свойство конкретной установки, а не имени. У оператора на
2026-10-14: `jq` (WinGet), `curl`, `git`, `openssl` (`/mingw64/bin`), `python3` (WindowsApps) —
нативные. `ssh`/`scp` из `/usr/bin` — MSYS и **не** переписываются; но оператор ходит на сервер
Windows-овым OpenSSH (`/c/Windows/System32/OpenSSH` первым в PATH) — тогда они нативные и
переписываются. Один и тот же скрипт ведёт себя по-разному в зависимости от PATH.
Отличить: `ldd "$(command -v X)" | grep -q msys-2.0.dll` → MSYS-программа.

## Таблица замера (2026-10-14, нативный jq)

| Аргумент | Получила программа |
|---|---|
| `/root/x`, `/etc/x`, `/opt/x` | `C:/Program Files/Git/root/x` — **переписан** |
| `/tmp/x` | `C:/Users/<user>/AppData/Local/Temp/x` — переписан |
| `/c/Users/<user>/x` | `C:/Users/<user>/x` — переписан |
| `/` | `C:/Program Files/Git/` — переписан; `/dev/null` → `nul` |
| строка с пробелами, **начинающаяся** с `/`: `/usr/local/x-ui/x-ui setting -show true` | `C:/Program Files/Git/usr/…` — **переписана целиком** |
| `--opt=/etc/x`, `x=/etc/y`, `-F/etc/x`, `@/root/x` | часть после `=`/ключа/`@` — **переписана** |
| `a=1&b=/x` (после **любого** `=`, не только первого) | `a=1&b=X:/` — одиночная буква после `/` читается как **буква диска** |
| `"/root/x"` (кавычки внутри значения) | `"C:/Program Files/Git/root/x"` — переписан |
| `/a:/b`, `origin/main:.claude/x` | `C:\…\a;C:\…\b`, `origin\main;.claude\x` — **список путей Windows** |
| переменная окружения `X=/root/x` | `C:/Program Files/Git/root/x` — **переписана** |
| `host:/root/x`, `srv:/opt/x` | как есть |
| `HEAD:.claude/x`, `<хеш>:.claude/x` | как есть |
| строка с пробелами, начинающаяся **не** с `/`: `sudo cat /etc/x`, `bash /tmp/x` | как есть |
| `'/root/x'` (одинарные кавычки внутри значения) | как есть |
| URL, JSON `{"a":"/root/x"}`, `k={"a":"/root/x"}` | как есть |
| `//server/share`, относительный `a/b/c`, `/a;/b`, ` /root/x` (ведущий пробел) | как есть |
| любой аргумент MSYS-программе (`/usr/bin/printf` и т. п.) | как есть |

## Как не наступить

1. **Путь на сервере → нативной программе отдельным аргументом или через окружение** —
   отключить конверсию **у этого вызова**:
   `MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' jq -nc --arg cert "$REMOTE_CERT" …`.
   Первая переменная — Git for Windows, вторая — MSYS2; на Linux и macOS обе ни на что не влияют.
2. **Не отключать конверсию на весь скрипт или в общей библиотеке** (решение — ADR-0046). Там же ходят локальные
   пути, которым конверсия нужна: cookie-файл из `mktemp` (`/tmp/…`) для нативного `curl -b`,
   временные файлы, файлы репозитория. Отключение сломало бы их — уже другим, тоже тихим образом.
3. **Удалённую команду — одной строкой, которая НЕ начинается с `/`:** `ssh host "sudo cat /etc/x"`
   безопасно. Опасно и `ssh host cat /etc/x` (путь отдельным аргументом), и
   `ssh host "/usr/local/x-ui/x-ui setting -show true"` — пробелы не спасают строку, начинающуюся
   с `/`. Если команда обязана начинаться с абсолютного пути — префикс из п. 1 у вызова `ssh`.
4. **`git show <ref>:<путь>`** — с `MSYS_NO_PATHCONV=1`, если в ref есть `/` (`origin/main`).
5. **Проверять под Git Bash заглушкой**, а не только на Linux: на Linux дефекта нет, тест
   зелёный при сломанном коде. Образец — `configure-vpn-routing/tests/test-vless-inbound-guards.sh` §3:
   скрипт в изолированном дереве, библиотека API подменена, проверяется JSON, который ушёл бы в панель.

## Аудит мозга 2026-10-14 — что защищено

Просмотрены все локально исполняемые скрипты и блоки ```bash скиллов (~470 строк вызовов
`jq`/`curl`/`git`/`python3`/`openssl`/`ssh`/`scp`). Скрипты, исполняемые на сервере
(`bootstrap-new-server`, `setup-backups`, тела heredoc, уходящие через stdin), не затронуты.
Защищены префиксом из п. 1:

- **`ssh <хост> "/usr/local/x-ui/…"`** — `scripts/lib-api/3xui.sh` (`api_gen_reality_keypair`),
  `.claude/skills/setup-vpn-panel/scripts/02-install-3x-ui.sh`, `03-configure-tls.sh`, команды в
  `.claude/skills/setup-vpn-panel/SKILL.md` и
  `.claude/skills/setup-vpn-panel/references/panel-hardening.md`;
- **`jq` с путями чужого сервера** — `parse-vless-link.sh` (обе копии: `spx`, `path`),
  `add-outbound-from-vless.sh` (`spiderX`), `create-vless-inbound.sh` (путь сертификата — в правке ADR-0045);
- **`jq` с секретами**, которые могут начинаться с `/`: `parse-hysteria2-link.sh`,
  запись в Bitwarden в `3xui.sh`.

Дефект уже проявлялся в данных: в разобранной подписке 2026-06 два пути ws/xhttp стали
`C:/Program Files/Git/api/v1/stream`. Оговорка добавлена там, где команду задаёт оператор: пример `state.digest_cmd` в
`infra-config.schema.json`.

**Не закрыто** (нельзя проверить без живой панели): тело входа в панель
`-d "username=…&password=…"` в `3xui.sh` — пароль с `=/` или начинающийся с `/` исказится, а
префикс там нельзя (тот же вызов несёт локальный cookie-файл). Сгенерированные агентом пароли
(A-Za-z0-9) безопасны. Лечение — тело через stdin (`--data-binary @-`).

Регресс: `scripts/test-msys-path-conversion.sh` — разбор ссылок, сборка исходящего на заглушке
API, статическая проверка `ssh <хост> '/…'`; на коде до правки — 5 провалов. Значим только под
Git Bash: секция 0 сама сообщает, переписывает ли среда пути.
