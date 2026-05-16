---
name: audit-security
description: |
  Security-аудит сервера по чек-листу (UFW, SSH-config, fail2ban, .env-mode, TLS-expiry,
  открытые порты, gitleaks, unattended-upgrades, Docker daemon). Output: structured отчёт
  PASS / WARN / FAIL с рекомендациями. Read-only (Green Zone) — НЕ исправляет.
  Триггеры: «security audit», «проверь безопасность», «аудит сервера», «compliance check»,
  «проверь хардеринг», «audit hardening».
  НЕ для исправлений (для них — отдельные скиллы); НЕ для penetration test (это другой жанр).
allowed-tools: Bash, Read
---

<role>
Я провожу security-аудит сервера по чек-листу. Я работаю в Green Zone — только
чтение, никаких изменений. Мой выход — структурированный отчёт PASS / WARN / FAIL
с рекомендациями. Исправлять найденное оператор решает сам — точечно, с
пониманием риска каждого изменения. Я никогда не «чиню» что-то автоматически,
потому что security-фиксы могут ломать работающие сервисы.
</role>

<context>
Что предполагается:
- SSH-доступ к серверу.
- Установлены утилиты: `ss`, `openssl`, `gitleaks` (опционально), `jq`.
- `inventory/shared/domains.md` существует — для проверки TLS по списку доменов.
- Локальная копия git-репо проекта (для gitleaks scan).
</context>

<goals>
- Получить чёткий список PASS / WARN / FAIL с конкретными деталями.
- Сравнить с предыдущим аудитом (если есть в `inventory/audits/`).
- Дать рекомендации с указанием Yellow Zone / Red Zone для каждого фикса.
- Сохранить отчёт в `inventory/audits/YYYY-MM-DD.md` (плановый) или
  `incidents/YYYY-MM-DD-security-audit.md` (если найдены FAIL).
</goals>

<parameters>
- `SCOPE` — `host` / `docker` / `git` / `tls` / `all` (default: `all`).
- `OUTPUT_FORMAT` — `markdown` / `json` (default: `markdown`).
- `SERVER` — SSH-target (если не задан CLI — берётся из `sysadmin-config.json`: `servers[0].ssh_alias`).
- `REPORT_LANGUAGE` — `ru` / `en` (если не задан CLI — берётся из `sysadmin-config.json`: `language`; default: `ru`).
</parameters>

# Инструкции

## Шаг 0. Чтение конфига (OPTIONAL)

Скилл — read-only OPTIONAL: конфиг используется опционально, без него работает на defaults + WARN. Конфиг улучшает поведение в трёх местах:
- `language` → язык отчёта (рус/англ);
- `secrets.manager` → рекомендации по `.env` конкретизированы под выбранный менеджер;
- `servers[0].ssh_alias` → значение `SERVER`, если CLI не задан.

Используй общий helper `_lib/find-config.sh` (единая точка изменения для
всех STRICT/OPTIONAL скиллов — алгоритм идентичен Cold Start Protocol персоны).
`$SYSADMIN_ROOT` — путь к sysadmin/ репо, известен по bridge-файлу
`~/.claude/agents/sysadmin.md` (читал на Cold Start).

```bash
source "$SYSADMIN_ROOT/.claude/skills/_lib/find-config.sh"

find_sysadmin_config optional   # OPTIONAL: defaults + WARN если не найден

# CLI-override > конфиг > дефолт
REPORT_LANGUAGE="${REPORT_LANGUAGE:-$(get_config_field language ru)}"
SERVER="${SERVER:-$(get_config_field 'servers[0].ssh_alias')}"
SECRETS_MANAGER="${SECRETS_MANAGER:-$(get_config_field secrets.manager)}"
```

Если по какой-то причине `$SYSADMIN_ROOT` не задан — извлеки его из bridge-файла:
```bash
SYSADMIN_ROOT=$(grep -oE '`/[^`]+sysadmin/?`' ~/.claude/agents/sysadmin.md \
    | head -1 | sed 's|`||g; s|/$||')
```

**Важно:** скилл остаётся **read-only**, конфиг ничего не правит и не диктует поведение проверок — только язык отчёта, ssh-таргет и формулировки рекомендаций по `.env`-файлам. Без конфига всё работает как раньше (с предупреждением).

## Шаг 1. Запустить audit-script

```bash
bash scripts/security-audit.sh \
    --server <user>@<your-server> \
    --scope all \
    --domains-file inventory/shared/domains.md \
    --output inventory/audits/$(date +%Y-%m-%d).md
```

Скрипт прогоняет 4 категории проверок (см. `references/checklist.md` для
обоснования каждого пункта):

### Host scope

- **UFW активен** и default deny incoming.
  ```bash
  ssh "$SERVER" 'ufw status verbose | grep -E "Status: active|Default: deny \(incoming\)"'
  ```
- **UFW allow только 22, 80, 443** (или явно задокументированные исключения).
  ```bash
  ssh "$SERVER" 'ufw status numbered | grep -E "ALLOW IN" | grep -vE "(22|80|443)/tcp"'
  # Ожидаем: пусто
  ```
- **SSH PasswordAuthentication no** (или явно `prohibit-password`).
- **SSH PermitRootLogin** не `yes` (допустимо `no` или `prohibit-password`).
- **fail2ban active** + sshd jail enabled.
  ```bash
  ssh "$SERVER" 'systemctl is-active fail2ban && fail2ban-client status sshd | grep "Currently banned"'
  ```
- **unattended-upgrades** настроен на security only, без auto-reboot.
- **Открытые порты только публичные** — `ss -tlnp` показывает только 22/80/443
  на 0.0.0.0, всё остальное на 127.0.0.1.

### Docker scope

- **/etc/docker/daemon.json** не содержит `"insecure-registries"`.
- **.env-файлы mode 0600** во всех `/opt/*/`.
  ```bash
  ssh "$SERVER" 'find /opt -name ".env" -exec stat -c "%a %n" {} \;'
  # Все должны быть 600
  ```
- **Внутренние UI на 127.0.0.1** (Kuma, Beszel, Dozzle, Dockge).
- **Образы не `:latest`** (для публичных образов; локальные сборки —
  исключение по ADR 0010 проекта-носителя).

### Git scope

- **gitleaks scan** working tree И истории — 0 findings.
  ```bash
  cd /path/to/repo && gitleaks detect --no-banner --log-opts='--all'
  ```
- **.gitignore** содержит `.env`, `*.key`, `*.pem`, `secrets/`.
- **Историческая утечка** — `git log -p | grep -E '(password|secret|token).*='`
  не должна давать релевантных совпадений (исключая `.env.example`).

### TLS scope

Для каждого домена из `inventory/shared/domains.md`:

- Сертификат валиден, не истекает в ближайшие 14 дней (FAIL), 14-30 дней (WARN).
  ```bash
  echo | openssl s_client -connect "$domain:443" -servername "$domain" 2>/dev/null \
      | openssl x509 -noout -enddate
  ```
- Цепочка корректна (нет «unable to verify»).

## Шаг 2. Сформировать отчёт

Шаблон `templates/audit-report.md`:

```markdown
# Security Audit — YYYY-MM-DD

## Сводка: PASS X / WARN Y / FAIL Z

### Host
| Проверка | Статус | Детали |
|----------|--------|--------|
| UFW активен | PASS | Status: active, Default: deny |
| UFW allow только 22/80/443 | PASS | Allow IN: 22 (OpenSSH), 80, 443 |
| SSH PasswordAuthentication | PASS | no |
| SSH PermitRootLogin | PASS | prohibit-password |
| fail2ban | PASS | active, sshd jail enabled (5 banned IPs) |
| unattended-upgrades | PASS | security only, no auto-reboot |
| Открытые порты (внешние) | PASS | 22/80/443 only |

### Docker
| Проверка | Статус | Детали |
|----------|--------|--------|
| daemon.json | PASS | no insecure-registries |
| .env permissions | WARN | /opt/myapp/.env mode 644 (должно быть 600) |
| Внутренние UI на 127.0.0.1 | PASS | Kuma 3001, Beszel 8090, Dozzle 8080 |

### Git
| Проверка | Статус | Детали |
|----------|--------|--------|
| gitleaks scan | PASS | 0 findings (working tree + history --all) |
| .gitignore | PASS | .env, *.key, *.pem, secrets/ |

### TLS
| Домен | Статус | Дата истечения |
|-------|--------|----------------|
| example.com | PASS | 2026-08-15 (113 дней) |
| beta.example.com | WARN | 2026-05-10 (15 дней) |

## Рекомендации
1. **[WARN] /opt/myapp/.env mode 644** — `chmod 600` (Yellow Zone, после backup).
   Параллельно вынести значения в менеджер паролей (под `secrets.manager` из конфига):
   - `keychain` → `security find-generic-password -s "infra/<name>" -w` в `.env.example`.
   - `pass` → `pass infra/<name>` в `.env.example`.
   - `1password` → `op item get '<name>' --vault infra` в `.env.example`.
   - `bitwarden` → `bw get password '<name>'` в `.env.example`.
2. **[WARN] beta.example.com TLS** — `acme.sh --renew -d beta.example.com` (acme.sh
   обычно сам обновит за 30 дней до истечения, проверь cron).

## Историческая динамика
Сравнение с `inventory/audits/2026-01-25.md`:
- Улучшилось: SSH PermitRootLogin (был `yes` → стал `prohibit-password`).
- Не изменилось: остальные проверки.
- Ухудшилось: новый WARN на /opt/myapp/.env (новый сервис с этого квартала).
```

## Шаг 3. Архив отчёта

- **Если найдены FAIL** — сохранить в `incidents/YYYY-MM-DD-security-audit.md`,
  поднять флаг оператору.
- **Если только PASS / WARN** — сохранить в `inventory/audits/YYYY-MM-DD.md`
  (плановый аудит).

## Примеры

### Пример 1: квартальный плановый аудит

```
SCOPE=all
OUTPUT_FORMAT=markdown
SERVER=<user>@<your-server>
```

Результат: 18 PASS / 2 WARN / 0 FAIL. WARN'ы — TLS близко к истечению (acme.sh
обновит автоматически) и `.env` с 644 правами. Сохранён в
`inventory/audits/2026-04-25.md`.

### Пример 2: аудит после security-инцидента

```
SCOPE=git    # подозрение что секрет утёк в git
```

Результат: 3 PASS / 0 WARN / 1 FAIL. gitleaks нашёл DB password в коммите 3-месячной
давности. Сохранён в `incidents/2026-04-25-security-audit.md`. Рекомендация:
**срочно** ротировать пароль БД (через скилл `rotate-secrets`), переписать историю
git (`git filter-repo`).

## Failed Attempts

- **«Запуск без `sysadmin-config.json` без предупреждения»** — отчёт уезжает на defaults (язык=ru, нет ssh-алиаса, рекомендации по `.env` без привязки к менеджеру), оператор не понимает, почему рекомендации общие. Урок: при отсутствии конфига выводить WARN в stderr с указанием на `/sysadmin-init`. Скилл остаётся read-only и НЕ падает — degraded gracefully.
- **«gitleaks scan только working tree»** — пропускает исторические утечки.
  **Решение:** `--log-opts='--all'` для полной истории.
- **«Чек портов через netstat».** Утилита устарела, на новых Ubuntu может не
  быть. **Решение:** использовать `ss -tlnp`.
- **«Один общий скрипт без scope-параметра».** Полный прогон долгий (TLS check
  для 20 доменов — 1-2 минуты), нет нужды каждый раз. **Решение:** разбить по
  scope для частичных аудитов (только git, только tls).
- **«Автоматически чинить найденное».** Security-фиксы могут ломать работающие
  сервисы (например, ужесточение firewall может отрубить мониторинг). **Решение:**
  только отчёт + рекомендации, оператор решает что и как чинить.
- **«Чек .env прав без exclusions».** На сервере могут быть чужие пользователи
  (deploy-bot, какой-нибудь sandbox). **Решение:** проверять только `/opt/*/.env`,
  игнорировать остальное.

## Граничные случаи

- **Контейнер с собственным sshd** (например, для bastion). Отдельный порт,
  отдельная проверка sshd_config внутри контейнера.
- **Provider firewall** (Selectel, Hetzner). UFW проверяется ВНУТРИ сервера,
  поверх может быть provider-level firewall с другими правилами. Скилл проверяет
  только хостовой UFW.
- **acme.sh deploy-hook не сработал.** Сертификат обновился, но nginx не
  перезагружен — старый cert ещё в памяти. Решение: проверять `nginx -V` /
  `nginx -t` + дату последнего reload.
- **Public registry mirrors** (Docker Hub mirror в RU). Могут быть в
  insecure-registries намеренно. Это **исключение**, документировать в
  `inventory/server.md` и игнорировать в аудите.
- **Multiple Docker daemons** (если стоит rootless Docker дополнительно). Каждый
  проверяется отдельно.

## Bundled Resources

- `scripts/security-audit.sh` — основной скрипт, прогоняет все scope'ы или один
  выбранный.
- `templates/audit-report.md` — шаблон отчёта с разделами Host / Docker / Git /
  TLS / Рекомендации / Историческая динамика.
- `references/checklist.md` — детальный чек-лист с обоснованием каждого пункта
  (откуда правило, какие риски при нарушении, ссылки на security-hardening.md).