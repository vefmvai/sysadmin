---
name: deploy-service
description: |
  Деплой/обновление/откат инфраструктурного сервиса по паттерну push-to-pull (мак → git push →
  SSH → git pull --ff-only → docker compose up -d). Блокирующий pre-check: inventory свежий,
  бэкап ≤24ч, домен резолвится, working tree чистый. Yellow Zone, брифинг + type-to-confirm,
  rollback <5 мин. MODE: new | update | rollback.
  Триггеры: «задеплой», «новый сервис», «обнови сервис», «deploy», «выкатить», «накатить версию», «откати».
  НЕ для деплоя в обход git (аварийный runbook); НЕ для drop volume/database (Red Zone).
allowed-tools: Bash, Read, Edit, Write
---

<role>
Я выкатываю инфраструктурный сервис через git-based pipeline (push-to-pull —
ADR 0015 проекта-носителя или эквивалентное решение), защищая прод от
случайных правок «на сервере». Каждый деплой — Yellow Zone: брифинг 6 пунктов, явное
подтверждение, заранее готовый rollback за <5 мин. Прямые правки на сервере вне git —
аварийный режим, не моя норма.
</role>

<context>
Предполагается:
- Git-репозиторий `infra` настроен с deploy-pipeline (см. ADR 0015 проекта-носителя
  или эквивалент): инфраструктурный репо склонирован в `$INFRA_DIR` на сервере
  (стандартное соглашение — `/opt/infra/`, путь конфигурируется), есть deploy-key,
  SSH-алиас сервера в `~/.ssh/config`, рабочий `scripts/deploy/deploy-remote.sh`
  и серверный `$INFRA_DIR/deploy.sh`.
- Скилл `setup-secrets-vault` использован для хранения секретов (`.env` через Keychain/SOPS).
- Skилл `inventory-scan` запускался недавно — `inventory/shared/services.md` актуален.

НЕ предполагается:
- Автоматический CI/CD (отвергнут в ADR 0015 проекта-носителя для milestone v1; в вашем проекте может быть актуален раньше — см. условия выбора в `references/deploy-paradigms.md`).
- Прямые правки на сервере как норма (drift = аварийный режим).
- Деплой приложенческих сервисов (например, веб-приложений и ботов проекта-носителя) — они обычно живут в своих репозиториях со своими pipeline; этот скилл — только для инфраструктурных сервисов.
</context>

<goals>
После выполнения:
- ✓ Сервис задеплоен, контейнер `Up (healthy)`
- ✓ Если есть домен — nginx vhost работает, TLS валиден, HTTP 200/3xx
- ✓ `inventory/shared/services.md` обновлён (через `inventory-scan` или вручную)
- ✓ Rollback готов и проверен (есть предыдущий git ref, скрипт `rollback.sh` отлажен)
- ✓ Логи последних 30 секунд без ERROR/FATAL
</goals>

# Параметры

| Параметр | Required | Default | Описание |
|----------|----------|---------|----------|
| `SERVICE_NAME` | да | — | Имя сервиса в kebab-case (например, `my-app`, `kuma`) |
| `MODE` | нет | `update` | `new` (новый сервис) / `update` / `rollback` |
| `DEPLOY_PATH` | нет | `/opt/infra/services/<name>` | Путь на сервере |
| `DOMAIN` | нет | — | Домен для nginx vhost (если нужен публичный доступ) |
| `SOURCE_REPO` | нет | — | URL git-репо с docker-compose.yml (если `MODE=new`) |
| `IMAGE` | нет | — | Образ для `MODE=new` (`ghost:5.87.2`) — pin tag, без `:latest` |
| `PORT` | нет | — | Внутренний порт контейнера (для nginx upstream) |

Все параметры — env vars или CLI-аргументы. Никаких хардкодных IP/доменов в скрипте.

# Процедура

## Шаг 1: Pre-check (Зелёная зона, БЛОКЕР если не пройден)

Запускается до любых изменений. Любая красная проверка останавливает процедуру.

| Проверка | Команда | Норма |
|----------|---------|-------|
| `inventory/shared/services.md` свежий | `find inventory/snapshots/ -mtime -7 \| head -1` | есть файл за 7 дней |
| Последний бэкап свежий | `restic snapshots --latest 1 --json \| jq -r '.[0].time'` | возраст ≤24 ч |
| Working tree чистый (мак) | `git status --porcelain` | пусто |
| Local main = origin/main | `git fetch && git rev-parse main vs origin/main` | равны |
| Если `MODE=new` и `DOMAIN`: домен резолвится | `dig +short $DOMAIN` | возвращает IP сервера |
| SSH-доступ к серверу | `ssh "$SERVER" "echo ok"` | `ok` |

**Если хоть одна красная** — остановиться, вернуть оператору отчёт «pre-check провален»
с конкретным шагом для исправления. НЕ начинать деплой «в надежде, что обойдётся».

## Шаг 2: Decision Tree — new vs update vs rollback

- **`MODE=new`** → Шаги 3a (создание структуры из templates) → 4 (брифинг) → 5 (push-to-pull)
  → 6 (smoke) → 7 (nginx + TLS, если `DOMAIN`) → 8 (inventory)

- **`MODE=update`** → Шаг 3b (diff текущего состояния и нового) → 4 (брифинг с упором на что меняется)
  → 5 (push-to-pull) → 6 (smoke) → 8 (inventory)

- **`MODE=rollback`** → Шаг 3c (выбрать prev git ref) → 4 (брифинг отката) → 5 (rollback.sh с этим ref)
  → 6 (smoke)

## Шаг 3a: Создание нового сервиса (`MODE=new`)

```bash
mkdir -p services/<SERVICE_NAME>
cp .claude/skills/deploy-service/templates/docker-compose-skeleton.yml \
   services/<SERVICE_NAME>/docker-compose.yml
cp .claude/skills/deploy-service/templates/env-example-skeleton \
   services/<SERVICE_NAME>/.env.example
[ -n "$DOMAIN" ] && cp .claude/skills/deploy-service/templates/nginx-vhost-skeleton.conf \
   services/nginx/sites-available/<DOMAIN>.conf
```

Затем заменить плейсхолдеры (`<SERVICE_NAME>`, `<IMAGE>`, `<PORT>`, `<DOMAIN>`) на реальные
значения через `sed -i` или Edit. На сервере создать `.env` (не в git!) — секреты подставляются
из Keychain через скилл `setup-secrets-vault`.

## Шаг 3b: Diff для обновления (`MODE=update`)

```bash
cd /opt/infra
git fetch origin main
git log --oneline HEAD..origin/main -- services/<SERVICE_NAME>/  # что изменилось
git diff HEAD origin/main -- services/<SERVICE_NAME>/             # содержимое изменений
```

Показать оператору diff. Если `image:` тег меняется — обязательно проверить changelog образа
(см. Failed Attempts ниже).

## Шаг 3c: Выбор ref для rollback (`MODE=rollback`)

```bash
cd /opt/infra
git log --oneline -10 -- services/<SERVICE_NAME>/   # последние 10 коммитов сервиса
# оператор выбирает SHA, на который откатываемся
```

## Шаг 4: Yellow Zone брифинг 6 пунктов

Перед запуском Шага 5 — обязательный брифинг (см. Часть VII §7.4 методички):

1. **ЧТО:** какой сервис, какие файлы изменяются (показать `git diff` summary)
2. **ЗАЧЕМ:** новый функционал / security patch / откат проблемы / обновление версии
3. **РИСКИ:** ожидаемый downtime (`docker compose up -d` для одного контейнера ~10-30 сек),
   что зависит (`depends_on` контейнеры), что может упасть
4. **ОТКАТ:** конкретная команда `cd /opt/infra && git checkout <prev-sha> && ./deploy.sh`
   (для `MODE=rollback` — наоборот, текущий ref как страховка)
5. **СТРАХОВКА:** snapshot inventory есть, бэкап БД (если затрагивается) свежий ≤24ч
6. **ПРОВЕРКА:** конкретный healthcheck endpoint, ожидаемый HTTP-код, что искать в логах

Затем запросить type-to-confirm с уникальной строкой:
`deploy-<SERVICE_NAME>-<YYYYMMDD-HHMM>` — оператор должен ввести ровно её.

## Шаг 5: Push-to-pull deploy (паттерн ADR 0015 проекта-носителя или эквивалент)

```bash
# На локальной машине
cd <repo-root-of-infra>
git add services/<SERVICE_NAME>/  [services/nginx/sites-available/<DOMAIN>.conf]
git commit -m "feat(<SERVICE_NAME>): deploy v<X.Y.Z>"
git push origin main

# Триггер деплоя
./scripts/deploy/deploy-remote.sh
```

Скрипт `deploy-remote.sh` (см. `scripts/deploy/deploy-remote.sh` в репо) делает pre-flight
(local main == origin/main), идёт по SSH в `/opt/infra/`, вызывает серверный `deploy.sh`,
который делает `git pull --ff-only` + селективный `docker compose up -d` по diff.

Для `MODE=rollback` используется `scripts/rollback.sh` из этого скилла — он делает
`git checkout <prev-sha>` вместо `git pull` и затем тот же `docker compose up -d`.

## Шаг 6: Smoke-test после деплоя

Ждать 30 секунд (контейнер запускается, healthcheck стартует), затем:

```bash
ssh "$SERVER" '
  docker ps --filter name=<SERVICE_NAME> --format "{{.Names}} {{.Status}}"
  docker logs --since=30s <SERVICE_NAME> 2>&1 | grep -iE "error|fatal|panic" | head -10
'

# Если есть домен
curl -s -o /dev/null -w "%{http_code}\n" --max-time 10 "https://<DOMAIN>/healthz" \
  || curl -s -o /dev/null -w "%{http_code}\n" --max-time 10 "https://<DOMAIN>/"
```

Ожидаемое:
- `Status` содержит `Up` и `(healthy)` (если есть healthcheck)
- В логах нет `ERROR`/`FATAL`/`panic`
- HTTP-код 200 или 3xx

Если хоть что-то не сошлось → автоматический rollback (см. Шаг 5 для `MODE=rollback`).

## Шаг 7: Nginx + TLS (только `MODE=new` с `DOMAIN`)

После того как контейнер поднят и отвечает:

```bash
ssh "$SERVER" '
  ln -sf "$INFRA_DIR/services/nginx/sites-available/<DOMAIN>.conf" \
         /etc/nginx/sites-enabled/<DOMAIN>.conf
  nginx -t && systemctl reload nginx
  acme.sh --issue --webroot /var/www/html -d <DOMAIN>
  acme.sh --install-cert -d <DOMAIN> ...   # подробности — см. references/deploy-paradigms.md
  systemctl reload nginx
'
```

См. шаблон nginx-vhost: `templates/nginx-vhost-skeleton.conf`.

## Шаг 8: Обновление inventory

```bash
# Запуск скилла inventory-scan (предпочтительно)
@inventory-scan

# Или ручное обновление (минимум)
# Edit inventory/shared/services.md — добавить строку про новый сервис
git add inventory/shared/services.md
git commit -m "docs: добавлен <SERVICE_NAME> в services.md"
git push
```

# Failed Attempts

Реальные грабли, документированные на этом проекте:

- **«rsync вместо git pull»** — антипаттерн, drift'ы между сервером и репо. Принцип
  «только git как источник истины» зафиксирован в ADR 0015 проекта-носителя
  или эквивалентном решении. См. рассказ в `references/deploy-paradigms.md`.
- **«docker compose up -d без аргумента `<service>`»** — поднимает ВСЕ сервисы compose-файла.
  Опасно для shared-stacks (например, исторический compose может содержать postgres+redis,
  которыми пользуются другие БД проекта). Всегда указывать конкретный сервис:
  `docker compose up -d my-app`.
- **«git push --force после правки на сервере»** — уничтожает ту самую правку, которую делали
  напрямую. NEVER. Сначала забрать правку с сервера в репо, потом push.
- **«деплой без healthcheck в compose»** — контейнер `Up`, но приложение внутри упало.
  Smoke-test не поймает. Healthcheck в compose обязателен (см. шаблон).
- **«Compose при смене `image:` строки пересоздаёт контейнер всегда»** — сравнение
  делается по строке тега, не по digest. Например, замена `redis:7-alpine` → `redis:7.4.8-alpine`
  пересоздаёт все redis-контейнеры, хотя image-id тот же. Если нужен узкий scope —
  использовать `--no-deps` и переименование точечно.
- **«Compose без явного `image:`, только `build:`»** при смене service key триггерит полную
  пересборку из Dockerfile (наблюдалось до 8 минут простоя на средних образах).
  Решение: добавить `image: <project>-<service>:latest` явно перед переименованием.
- **«acme.sh обновил cert, но nginx ссылается на старый путь»** — паттерн зафиксирован
  в ADR 0008 проекта-носителя или эквивалентном решении. После certbot/acme —
  обязательно `nginx -s reload` или скрипт-обёртка типа `cert-reload-smart.sh`.

# Граничные случаи

- **Новый сервис без домена** (внутренний бот, worker) → пропустить Шаг 7 (nginx).
- **Обновление с breaking changes БД-схемы** → это **Red Zone**, не Yellow. Сначала миграция
  отдельно (отдельный runbook), потом деплой кода.
- **Сервис не в shared compose, а в отдельном compose-файле в /opt/<service>** → старый паттерн,
  путь к compose другой. Если возможно — мигрировать в `/opt/infra/services/` в рамках следующего
  деплоя (отдельный план).
- **Rollback после успешного deploy** (мониторинг показал проблему через час) → запустить
  `bash .claude/skills/deploy-service/scripts/rollback.sh <SERVICE_NAME> <prev-sha>` за <5 мин.

# Идемпотентность

`docker compose up -d` сам по себе идемпотентен: если состояние совпадает с желаемым — ничего
не делает. Скрипт `deploy.sh` на сервере использует `--ff-only` — повторный запуск без новых
коммитов не делает изменений. Безопасно перезапускать всю процедуру.

# Параметризация

Никаких хардкодных IP/доменов/сервисов в этом SKILL.md и скриптах:
- IP сервера → SSH-алиас (имя `prod` / `production` / любое — настраивается
  оператором один раз в `~/.ssh/config`); в скрипте используется переменная `$SERVER`
- Путь к инфра-репо на сервере → переменная `$INFRA_DIR`
  (стандартное соглашение `/opt/infra/`, путь конфигурируется)
- Домен сервиса → переменная `DOMAIN` (передаётся из брифинга)
- Имя сервиса → переменная `SERVICE_NAME`
- Источник секретов → менеджер паролей оператора через скилл `setup-secrets-vault`

# Bundled resources

- `scripts/deploy.sh` — обёртка вокруг `scripts/deploy/deploy-remote.sh` репо (для запуска из скилла)
- `scripts/deploy-remote.sh` — копия рабочего скрипта для self-contained вызова
- `scripts/rollback.sh` — откат на конкретный git ref
- `templates/docker-compose-skeleton.yml` — заготовка с pinned image, mem_limit, healthcheck, networks, labels
- `templates/nginx-vhost-skeleton.conf` — TLS + proxy_pass + security headers
- `templates/env-example-skeleton` — секреты как ссылки на Keychain (не значения)
- `references/deploy-paradigms.md` — разбор rsync (антипаттерн) vs push-to-pull (ADR 0015 или эквивалент) vs CI/CD