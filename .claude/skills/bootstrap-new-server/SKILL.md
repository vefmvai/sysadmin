---
name: bootstrap-new-server
description: |
  Первичная настройка свежего VPS (Ubuntu 22.04+/Debian 12+): SSH-ключи, отключение root-логина,
  UFW (deny-in + 22/80/443), fail2ban, Docker + compose, структура /opt/, git с gitleaks
  pre-commit hook, шаблоны ADR/runbook/incident. Только свежие VPS.
  Триггеры: «настрой новый сервер», «получил VPS», «свежий ubuntu», «bootstrap server»,
  «поднять чистый сервер», «как у тебя на проде, только мне».
  НЕ для приведения хаоса в порядок (для этого — cleanup-existing-server); НЕ для серверов
  с существующими Docker/nginx/configs — это другой жанр.
allowed-tools: Bash, Read, Edit, Write
---

<role>
Я провожу за оператора полную первичную настройку свежего VPS — то, что обычно делается долго руками и часто оставляет грабли. После моей работы сервер готов принимать первые контейнеры и инициализирован git-репозиторий с защитой от случайного коммита секретов.
</role>

<context>
Предполагается:
- Свежий VPS (Ubuntu 22.04+ / Debian 12+).
- Root-доступ через SSH (или sudo для не-root пользователя).
- IP-адрес сервера известен.
- У оператора есть публичный SSH-ключ (`~/.ssh/id_ed25519.pub` или аналогичный).
- (Опционально) Домен резолвится в IP — для будущего nginx/TLS, но не обязательно сейчас.

НЕ предполагается:
- Существующие docker-контейнеры или нестандартные конфиги (для этого — `cleanup-existing-server`).
- Доступ через панель провайдера для recovery — если SSH сломается, у оператора должен быть альтернативный способ восстановления.
</context>

<goals>
После выполнения должно стать TRUE:
- SSH работает только по ключу, root-логин отключён, fail2ban защищает от brute-force.
- UFW: deny-in по умолчанию, allow 22 (или альтернативный порт), 80, 443.
- Docker и docker-compose установлены, тестовый `hello-world` работает.
- Структура `/opt/` готова: `monitoring/`, `admin-panel/`, `shared-db/`, `apps/` (пустые, но созданы).
- Git-репозиторий инициализирован в `/opt/infra` с `.gitignore` и pre-commit hook gitleaks.
- Шаблоны `decisions/0000-template.md`, `incidents/_template.md`, `runbooks/00-template.md` скопированы.
- Базовый `inventory/README.md` создан с заглушками — для дальнейшего заполнения.
</goals>

# Параметры

| Параметр       | Default                  | Описание                                                        |
| -------------- | ------------------------ | --------------------------------------------------------------- |
| `SERVER_IP`    | (required)               | IP-адрес свежего VPS                                            |
| `SSH_PORT`     | `22`                     | SSH-порт (можно сменить на нестандартный — см. Failed Attempts) |
| `ADMIN_USER`   | (required)               | Имя пользователя для не-root-доступа (получит sudo)             |
| `SSH_KEY_PUB`  | (required)               | Содержимое публичного ключа оператора                           |
| `TIMEZONE`     | `UTC`                    | Таймзона сервера. UTC рекомендуется для серверов (логи коррелируются с другими сервисами без mental-конвертации); если оператор работает в одной локальной зоне и предпочитает её — переопределяется (например, `Europe/Moscow`, `Europe/Berlin`, `America/New_York`). |
| `INFRA_DIR`    | `/opt/infra`             | Куда инициализировать git-репозиторий                           |
| `SERVER_HOST`  | autodetect               | Имя хоста (если не передано — берётся из `hostname`)            |

# Процедура

## Шаг 0: Pre-check

**Проверить, что сервер свежий и параметры заполнены.**

```bash
# На локальной машине оператора:
ssh root@$SERVER_IP "uname -a && cat /etc/os-release | grep -E '^(NAME|VERSION)='"
ssh root@$SERVER_IP "docker --version 2>/dev/null && echo 'Docker уже стоит — это НЕ свежий сервер!'"
```

**Опциональное чтение `sysadmin-config.json`.** На свежем сервере конфига обычно **нет** — это норма (агент ещё не настроен под этого оператора). Скилл — OPTIONAL-режим: если конфиг есть локально (например, оператор уже настраивал агент для другого сервера), скилл подхватит из него `language` и `operator.timezone`.

Используй общий helper `_lib/find-config.sh` в режиме `silent` — отсутствие
конфига нормально для bootstrap (часто первая операция на свежей машине,
до `/sysadmin-init`). `$SYSADMIN_ROOT` запоминается на Шаге 1 Cold Start.

```bash
source "$SYSADMIN_ROOT/.claude/skills/_lib/find-config.sh"

# silent: без WARN, $CONFIG="" если не найден
find_sysadmin_config silent

# CLI-override > конфиг > defaults
TIMEZONE="${TIMEZONE:-$(get_config_field operator.timezone UTC)}"
LANG_FROM_CONFIG=$(get_config_field language ru)
# LANG_FROM_CONFIG используется только для локализации сообщений скилла
```

**Без конфига скилл работает как раньше** — defaults `TIMEZONE=UTC`, сообщения на русском. Это сознательно: bootstrap часто первая операция на свежей машине, до `/sysadmin-init`.

**Verify:**
- ОС — Ubuntu 22.04+/24.04+ или Debian 12+.
- Docker НЕ установлен (иначе — стоп, использовать `cleanup-existing-server`).
- Параметры `ADMIN_USER`, `SSH_KEY_PUB` заполнены, `SERVER_IP` доступен по SSH.

**Если pre-check не прошёл:** STOP, доложить оператору. Не модифицировать сервер «из лучших побуждений».

## Шаг 1: SSH-hardening (`scripts/01-ssh-hardening.sh`)

**Что делает скрипт:**
1. Создаёт пользователя `$ADMIN_USER` (если ещё нет), добавляет в группу `sudo`.
2. Устанавливает `$SSH_KEY_PUB` в `/home/$ADMIN_USER/.ssh/authorized_keys` (mode 600, owner — admin).
3. Правит `/etc/ssh/sshd_config`: `PermitRootLogin no`, `PasswordAuthentication no`, `Port $SSH_PORT`.
4. Делает `sshd -t` (syntax check). НЕ перезапускает sshd до подтверждения.

**Запуск:**
```bash
ssh root@$SERVER_IP "ADMIN_USER='$ADMIN_USER' SSH_KEY_PUB='$SSH_KEY_PUB' SSH_PORT='$SSH_PORT' bash -s" < scripts/01-ssh-hardening.sh
```

**Verify (КРИТИЧНО — не перезапускай sshd до проверки!):**
1. В новом терминале: `ssh -p $SSH_PORT $ADMIN_USER@$SERVER_IP "id"` — должно сработать.
2. Только после этого: `ssh root@$SERVER_IP "systemctl restart sshd"`.
3. Проверить, что root больше не пускает: `ssh root@$SERVER_IP "id"` — должно отвалиться с `Permission denied`.

## Шаг 2: UFW-setup (`scripts/02-ufw-setup.sh`)

**Что делает:** ставит ufw, default deny incoming + allow outgoing, открывает `$SSH_PORT`/tcp, 80/tcp, 443/tcp, активирует.

**Запуск:**
```bash
ssh $ADMIN_USER@$SERVER_IP -p $SSH_PORT "SSH_PORT='$SSH_PORT' sudo -E bash -s" < scripts/02-ufw-setup.sh
```

**Verify:** `sudo ufw status verbose` — Status: active; правила для `$SSH_PORT/tcp`, `80/tcp`, `443/tcp` ALLOW IN.

## Шаг 3: fail2ban (`scripts/03-fail2ban.sh`)

**Что делает:** ставит fail2ban, создаёт `/etc/fail2ban/jail.local` с jail для sshd (maxretry=5, bantime=1h), включает.

**Запуск:**
```bash
ssh $ADMIN_USER@$SERVER_IP -p $SSH_PORT "SSH_PORT='$SSH_PORT' sudo -E bash -s" < scripts/03-fail2ban.sh
```

**Verify:** `sudo fail2ban-client status sshd` — Currently failed: 0, jail enabled.

## Шаг 4: Docker (`scripts/04-docker-install.sh`)

**Что делает:** ставит Docker CE из официального APT-репозитория Docker, добавляет `$ADMIN_USER` в группу `docker`, ставит `docker-compose-plugin`.

**Запуск:**
```bash
ssh $ADMIN_USER@$SERVER_IP -p $SSH_PORT "ADMIN_USER='$ADMIN_USER' sudo -E bash -s" < scripts/04-docker-install.sh
```

**Verify:**
```bash
ssh $ADMIN_USER@$SERVER_IP -p $SSH_PORT "docker --version && docker compose version && docker run --rm hello-world"
```

После добавления в группу `docker` оператору нужен relogin (или `newgrp docker`) — скрипт это печатает в конце.

## Шаг 5: Структура /opt + git-init (`scripts/05-git-init.sh`)

**Что делает:**
1. Создаёт `/opt/{monitoring,admin-panel,shared-db,apps}` (пустые папки).
2. Создаёт `$INFRA_DIR` (по умолчанию `/opt/infra`), `git init`, ставит owner `$ADMIN_USER`.
3. Копирует `templates/gitignore-template` → `$INFRA_DIR/.gitignore`.
4. Копирует `templates/pre-commit-gitleaks` → `$INFRA_DIR/.git/hooks/pre-commit` (chmod +x).
5. Создаёт `$INFRA_DIR/decisions/0000-template.md`, `incidents/_template.md`, `runbooks/00-template.md`, `inventory/README.md` (заглушки из проекта-носителя).
6. Делает первый commit: `chore: bootstrap (sha SSH=#, UFW=#, fail2ban=#, docker=#)`.

**Запуск:**
```bash
ssh $ADMIN_USER@$SERVER_IP -p $SSH_PORT "ADMIN_USER='$ADMIN_USER' INFRA_DIR='$INFRA_DIR' bash -s" < scripts/05-git-init.sh
# (templates перекидываются скриптом — он использует heredoc)
```

**Verify:**
```bash
ssh $ADMIN_USER@$SERVER_IP -p $SSH_PORT "ls -la $INFRA_DIR && cd $INFRA_DIR && git log --oneline"
```

Должны быть: `.gitignore`, `decisions/`, `incidents/`, `runbooks/`, `inventory/`, один первичный коммит.

## Шаг 6: Дальнейшие шаги

После завершения этого скилла — рекомендуется (в этом порядке):

1. **Сначала — `/sysadmin-init`.** Создаст `sysadmin-config.json` (паспорт оператора:
   менеджер паролей, нужен ли мониторинг, куда складывать бэкапы, какой Telegram-бот).
   Без этого файла `setup-backups` и `install-monitoring-stack` отказываются работать
   (STRICT-режим, см. их Шаг 0). Это 3-5 минут вопросов с обоснованиями вариантов.
2. Затем `/setup-secrets-vault` — настройка менеджера паролей. Если на шаге 1 ты уже
   указал `secrets.manager` в конфиге, этот скилл пропустит интерактивный выбор и
   просто проверит установку. Без менеджера секреты будут оседать в `.env`-файлах в
   репо — это антипаттерн.
3. (Опционально) `/install-monitoring-stack` — базовый стек мониторинга
   (Uptime Kuma + Beszel + Dozzle + Dockge + Diun + Telegram-алерты).
4. (Опционально) `/setup-backups` — restic + offsite-хранилище
   (S3 / Backblaze B2 / WebDAV — Яндекс.Диск, NextCloud, ownCloud).

**Почему именно в таком порядке:** конфиг — паспорт агента под этого оператора. Все
последующие скиллы читают его и подстраивают поведение. Без конфига каждый скилл
вынужден был бы заново спрашивать «какой у тебя менеджер паролей», «нужны ли алерты»
и т.д. — это alert fatigue.

# Failed Attempts (граблекейс)

- **«bootstrap → сразу setup-backups, без `/sysadmin-init`»** — оператор пропустил
  настройку конфига и попытался сразу настроить бэкапы. `setup-backups` отказался
  работать (нет `sysadmin-config.json`). Урок: после bootstrap **первым** идёт
  `/sysadmin-init`, потом всё остальное. Это документировано в Шаге 6 как порядок.
- **«Делал bootstrap зависимым от конфига»** — конфига на свежем сервере не существует
  по определению. Урок: bootstrap — OPTIONAL-режим чтения конфига (если есть локально
  на машине оператора — подхватит `language` и `operator.timezone`, иначе defaults).
- **«UFW работает в Docker»** — UFW и Docker конфликтуют по iptables. Docker по умолчанию обходит UFW для контейнеров с `ports:`. Решение: либо `iptables=false` в `/etc/docker/daemon.json` (но тогда контейнеры теряют сеть), либо настройка `DOCKER-USER` chain в UFW — см. `references/ubuntu-vs-debian-quirks.md`. На свежем сервере без контейнеров пока не критично, но знай заранее.
- **«acme.sh поставится с Docker»** — лучше отдельным шагом после bootstrap, не входит в этот скилл. Делается вручную при первом TLS-сертификате (для каждого сервера домены индивидуальны).
- **«SSH-порт 22 — небезопасно»** — миф. fail2ban + ключи + отключённый PasswordAuthentication защищают; смена порта — security through obscurity. Меняем по желанию (меньше шума в логах), не по необходимости.
- **«PermitRootLogin without-password — компромисс»** — нет, отключай полностью (`no`). Если корневой ключ скомпрометирован — последствия фатальны. У оператора есть `sudo` через `$ADMIN_USER`.
- **«fail2ban подхватит изменение SSH-порта сам»** — нет, jail для sshd по умолчанию слушает port 22. Если сменил порт — поправь `/etc/fail2ban/jail.local`. Скрипт `03-fail2ban.sh` это делает автоматически по `$SSH_PORT`.

# Граничные случаи

- **Уже установлен Docker** → STOP, это НЕ свежий сервер. Используй `cleanup-existing-server`.
- **Уже есть пользователь с именем `$ADMIN_USER`** → подтвердить у оператора (использовать существующего или выбрать другое имя). Скрипт `01` детектит и спрашивает.
- **Selectel/Hetzner specifics** → некоторые провайдеры блокируют `25/465/587` SMTP-порты на egress (для борьбы со спамом) — для этого скилла неважно, но полезно знать.
- **Cloud-init не закончил инициализацию** → `cloud-init status` должен быть `done`. Если `running` — подождать 1-2 минуты, иначе `apt update` может повиснуть на блокировке.
- **Двойная установка Docker** (Docker от Ubuntu + Docker CE) → скрипт `04-docker-install.sh` делает `apt-get remove docker docker-engine docker.io containerd runc` перед установкой Docker CE, чтобы не было конфликтов.
- **Сервер за NAT / без публичного IP** → bootstrap всё равно работает, но UFW открывает порты для несуществующего внешнего трафика. Проверь с оператором, что VPN/проброс настроены.
- **Не Ubuntu/Debian** (CentOS, Alpine, Arch) → этот скилл не покрывает. Альпийский скрипт `02-ufw-setup.sh` отвалится — там нет ufw, есть `iptables` напрямую. Допиши под свою ОС или используй другой скилл.