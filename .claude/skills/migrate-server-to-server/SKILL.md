---
name: migrate-server-to-server
description: |
  Перенос Docker-инфраструктуры со старого VPS на новый. 4 стратегии: live (logical
  replication PostgreSQL + RDB/AOF Redis, downtime 30-120 сек), backup-restore
  (pg_dumpall + tar volumes + scp, downtime 10-60 мин), rsync-incremental (день 1+2+3
  с финальным delta, downtime 5-15 мин), blue-green (параллельные серверы со
  switching через nginx/LB, downtime 0, но 2x cost). Pre-migration checklist
  (inventory + размеры + зависимости + backup), cutover (DNS + final rsync),
  post-migration verify (row counts + healthchecks). Rollback сценарий явный —
  возврат на старый VPS за минуты.
  Используй когда оператор говорит "переезд на новый сервер", "migrate server",
  "сменить VPS", "переместить инфру", "новый провайдер", "сменить хостинг".
when_to_use: |
  При смене VPS-провайдера, апгрейде ресурсов сервера, переезде на bare-metal.
  Требует параллельный доступ к старому и новому серверу. Длительность зависит от
  стратегии: 1-3 часа (rsync для маленьких) — недели (blue-green с долгим warmup).
  Перед запуском новый сервер должен быть bootstraped — см. скилл `bootstrap-new-server`.
disable-model-invocation: false
allowed-tools: Bash, Read, Edit, Write
---

<role>
Я провожу миграцию Docker-инфраструктуры со старого VPS на новый, выбирая стратегию
по контексту (терпимость к downtime vs стоимость). Я не делаю миграцию «вслепую» —
pre-migration checklist обязателен, rollback готов в любой момент. Старый сервер
не уничтожается до тех пор, пока новый не отработает safe-период (1-2 недели).
</role>

<context>
Старый и новый VPS оба доступны по SSH одновременно. Новый VPS уже bootstraped
через `bootstrap-new-server` (Docker, UFW, fail2ban, базовое hardening). Свежий
бэкап существует и проверен. Inventory старого сервера актуален (запустить
`inventory-scan`, если давно не обновлялся).
</context>

<goals>
- Все сервисы работают на новом сервере, отвечают healthcheck'ами.
- Нет потерь данных — row counts на старом и новом совпадают.
- DNS переключён, TLS работает на новых endpoint'ах.
- Старый сервер можно отключить через safe-период (1-2 недели) без последствий.
- Откат возможен в любой момент: DNS возвращается на старый IP, который ещё жив.
</goals>

<parameters>
- `OLD_SERVER` — SSH-target старого VPS (например, `user@old.vps.com`).
- `NEW_SERVER` — SSH-target нового VPS.
- `STRATEGY` — `live` / `backup-restore` / `rsync-incremental` / `blue-green`.
- `SERVICES` — список сервисов или `all`.
- `DOWNTIME_TOLERANCE_SEC` — терпимый downtime в секундах (для авто-выбора стратегии).
- `DNS_PROVIDER` — провайдер DNS (для понижения TTL заранее).
</parameters>

# Инструкции

## Шаг 1. Pre-migration checklist (БЛОКЕР запуска)

Без этих пяти пунктов миграция не начинается. Это не «лучшая практика», а условие безопасности.

- [ ] Inventory старого сервера актуален — запусти `inventory-scan` если последний
      снимок старше 7 дней.
- [ ] Размеры volumes известны: `du -sh /var/lib/docker/volumes/*` — нужно для
      оценки времени rsync и свободного места на новом сервере.
- [ ] Зависимости каждого сервиса задокументированы — что нельзя переносить по
      одному (app+postgres, nginx+certificates, redis+app-with-sessions).
- [ ] Свежий бэкап перед миграцией: pg_dumpall + tar volumes + restic backup —
      offsite. Без бэкапа миграция запрещена даже на «маленьких» сервисах.
- [ ] Новый сервер прошёл `bootstrap-new-server` — Docker, UFW, fail2ban, SSH
      hardening готовы. Без этого новый сервер уязвим в окне миграции.

Если хотя бы один пункт не закрыт — STOP, оператору сообщается какой именно.

## Шаг 2. Выбор стратегии (decision tree)

```
ЕСЛИ DOWNTIME_TOLERANCE_SEC < 60 И бюджет позволяет 2x временно:
    → blue-green
ИНАЧЕ ЕСЛИ DOWNTIME_TOLERANCE_SEC < 300 И в стеке только PostgreSQL/Redis:
    → live (логическая репликация PG + RDB/AOF Redis)
ИНАЧЕ ЕСЛИ объём данных < 50GB И есть несколько дней на параллельную работу:
    → rsync-incremental (день 1+2 онлайн, день 3 cutover 5-15 мин)
ИНАЧЕ:
    → backup-restore (простой 10-60 мин, минимум setup)
```

После выбора — Yellow Zone брифинг 6 пунктов оператору:
1. **Что меняется:** какие сервисы переносятся, на какой адрес.
2. **Что может пойти не так:** реальные риски конкретно этой стратегии.
3. **Окно простоя:** ожидаемый downtime в секундах/минутах.
4. **Точка невозврата:** до DNS-switch'а откат бесплатный, после — TTL × 2.
5. **Откат:** конкретные команды, которые вернут на старый сервер.
6. **Подтверждение:** оператор пишет согласие явной фразой.

## Шаг 3. Стратегия-специфичная процедура

### 3.1 Backup-Restore (наиболее частый случай)

Применимо: маленькие БД (<100GB), приемлемый downtime 10-30 мин, минимум setup.

```bash
# 1. На старом — полный логический дамп
ssh "$OLD_SERVER" 'docker exec postgres pg_dumpall | gzip > /backup/full.sql.gz'

# 2. tar volumes (уделить внимание правам владельца — postgres uid 999)
ssh "$OLD_SERVER" 'tar czf /backup/docker-volumes.tar.gz /var/lib/docker/volumes/'

# 3. scp на новый сервер
ssh "$OLD_SERVER" 'scp /backup/*.gz '"$NEW_SERVER"':/tmp/'

# 4. На новом — восстановить compose, разархивировать, поднять
ssh "$NEW_SERVER" 'cd /opt/<service> && git pull && tar xzf /tmp/docker-volumes.tar.gz -C /'
ssh "$NEW_SERVER" 'cd /opt/<service> && docker compose up -d postgres'
ssh "$NEW_SERVER" 'gunzip < /tmp/full.sql.gz | docker exec -i postgres psql -U postgres'
ssh "$NEW_SERVER" 'cd /opt/<service> && docker compose up -d'

# 5. Smoke-test через health-check скилл
# 6. DNS switch (TTL уже снижен заранее за 24-48 ч)
```

См. `scripts/02-rsync-incremental.sh` для аналога с rsync.

### 3.2 Rsync-Incremental

Применимо: средний объём данных, есть несколько дней на параллельную работу.

```bash
# День 1 — первый полный rsync (старый сервис ещё работает)
rsync -avz --progress /var/lib/docker/volumes/ "$NEW_SERVER":/var/lib/docker/volumes/

# День 2 — повторный rsync (только delta, быстро)
rsync -avz --progress --delete /var/lib/docker/volumes/ "$NEW_SERVER":/var/lib/docker/volumes/

# День 3 — cutover окно
ssh "$OLD_SERVER" 'cd /opt/<service> && docker compose stop'
rsync -avz --progress --delete /var/lib/docker/volumes/ "$NEW_SERVER":/var/lib/docker/volumes/
ssh "$NEW_SERVER" 'cd /opt/<service> && docker compose up -d'
# DNS switch
```

### 3.3 Live (логическая репликация PostgreSQL)

Применимо: критичный downtime, PostgreSQL-only стек или PG + Redis.

```sql
-- На старом сервере
ALTER SYSTEM SET wal_level = 'logical';
ALTER SYSTEM SET max_replication_slots = 10;
ALTER SYSTEM SET max_wal_senders = 10;
-- restart PG требуется для wal_level
CREATE PUBLICATION all_tables FOR ALL TABLES;
```

```sql
-- На новом сервере
CREATE DATABASE myapp;
\c myapp
-- Сначала перенести схему через pg_dump --schema-only
CREATE SUBSCRIPTION sub_myapp
  CONNECTION 'host=OLD_IP dbname=myapp user=replicator password=...'
  PUBLICATION all_tables;

-- Ждать synchronized
SELECT * FROM pg_stat_subscription;  -- state должен стать 'streaming'
```

После синхронизации (delta = 0) — DNS switch, остановить старый, удалить subscription.

### 3.4 Blue-Green

Применимо: нулевой downtime критичен, бюджет позволяет 2x временно.

```
1. Новый сервер (green) поднят полностью параллельно со старым (blue).
2. Данные синхронизируются между ними (live или rsync).
3. nginx/LB перед обоими: weighted 100% blue → 0% green.
4. Cutover: weighted 0% blue → 100% green (атомарно через nginx -s reload).
5. Держать blue 1-2 недели как страховку.
```

См. `references/strategies-tradeoffs.md` для детального сравнения 4 стратегий.

## Шаг 4. Cutover (`scripts/03-cutover.sh`)

Финальное переключение — порядок критичен.

1. **Снизить TTL заранее** (за 24-48 ч до cutover): A-record TTL → 300 сек.
2. **Финальный rsync delta** (если применимо для стратегии).
3. **Stop сервисов на старом** — но НЕ уничтожать контейнеры (`docker compose stop`,
   не `down`).
4. **Start сервисов на новом** — `docker compose up -d`.
5. **Smoke-test на новом** перед DNS-switch — health-check для каждого сервиса.
6. **DNS switch** — обновить A-record на новый IP (атомарно одним кликом в панели
   или API провайдера).
7. **Мониторить propagation** 5-10 мин: `for i in {1..20}; do dig <domain> +short; sleep 30; done`.

## Шаг 5. Post-migration verify (`scripts/04-post-migration-verify.sh`)

Проверки сразу после cutover, до отключения старого сервера.

```bash
# Row counts — главная метрика отсутствия потерь
ssh "$OLD_SERVER" 'docker exec postgres psql -U postgres -d <db> \
  -c "SELECT count(*) FROM <main-table>"'
ssh "$NEW_SERVER" 'docker exec postgres psql -U postgres -d <db> \
  -c "SELECT count(*) FROM <main-table>"'
# → должны совпадать

# Healthchecks (подставить реальные сервисы из inventory)
for svc in <service-1> <service-2> <service-3>; do  # ПРИМЕР, замените своими
    curl -sSf https://"$svc".example.com/health || echo "FAIL: $svc"
done

# TLS работает
echo | openssl s_client -connect <domain>:443 -servername <domain> 2>/dev/null \
  | openssl x509 -noout -dates

# Бэкапы работают на новом
ssh "$NEW_SERVER" 'restic snapshots --json | tail -5'

# Cron entries активны на новом
ssh "$NEW_SERVER" 'crontab -l && ls /etc/cron.d/'
```

## Шаг 6. Rollback (если что-то пошло не так)

Откат построен на том, что **старый сервер ещё жив** — мы его только остановили,
не уничтожили.

```bash
# 1. DNS switch обратно на старый IP (один клик в панели DNS-провайдера)
# 2. На старом — поднять сервисы, которые мы stop'нули в Шаге 4
ssh "$OLD_SERVER" 'cd /opt/<service> && docker compose up -d'
# 3. Подождать TTL × 2 (10 мин) для propagation
# 4. Проверить что старый снова отвечает
curl -sSf https://<domain>/health
# 5. Анализ причин на новом сервере (логи, метрики)
# 6. Повторить миграцию с исправлениями
```

## Шаг 7. Cleanup старого сервера (через safe-период)

Не торопиться — индустриальный стандарт 1-2 недели.

- Дни 0-2: активный мониторинг, логи смотрят постоянно.
- Дни 3-7: пассивно следим, smoke-test раз в день.
- Неделя 2: финальный snapshot старого сервера в архив.
- После 14 дней: можно отключить у провайдера, репо `compose/конфиги` остаётся как
  холодный архив.

## Примеры

### Пример 1: миграция трёх ботов (rsync-incremental)

Стек: 3 telegram-бота, общий postgres, ~3GB данных. Downtime 5 мин приемлем.
Стратегия: rsync-incremental (1 день полный + 1 день delta + cutover).

```bash
# Пятница вечер: полный rsync
rsync -avz /var/lib/docker/volumes/ new:/var/lib/docker/volumes/  # ~5 мин

# Суббота утро: delta rsync
rsync -avz --delete /var/lib/docker/volumes/ new:/var/lib/docker/volumes/  # ~30 сек

# Суббота вечер: cutover окно
ssh old 'docker compose -f /opt/bot1/docker-compose.yml stop'
ssh old 'docker compose -f /opt/bot2/docker-compose.yml stop'
ssh old 'docker compose -f /opt/bot3/docker-compose.yml stop'
rsync -avz --delete /var/lib/docker/volumes/ new:/var/lib/docker/volumes/  # ~5 сек delta
ssh new 'cd /opt/bot1 && docker compose up -d'
# ... остальные боты
# DNS switch для каждого домена
# Verify: каждый бот отвечает на /health
```

### Пример 2: миграция production-стека с zero downtime (blue-green)

Стек: API + frontend, 50k активных пользователей, downtime недопустим.
Стратегия: blue-green с logical replication PG.

См. детали в `references/strategies-tradeoffs.md`, секция Blue-Green.

## Failed Attempts

- **`pg_dump` с хоста с другой версией PostgreSQL.** Несовместимость dump'а
  старой версии с новой. **Решение:** всегда `docker exec postgres pg_dumpall`
  изнутри контейнера, версия совпадает с восстанавливающим.
- **rsync без `--link-dest`.** Каждый прогон тратит место под полные дубликаты.
  **Решение:** `--link-dest=/path/to/previous/snapshot/` для hardlink dedupe.
- **DNS switch без снижения TTL заранее.** Старые resolvers возвращают старый IP
  часами или сутками. **Решение:** TTL → 300 сек за 24-48 ч до cutover.
- **Уничтожить старый сразу после cutover.** Нет fallback при проблеме на новом.
  **Решение:** держать старый запущенным минимум 24 часа после migration.
- **Hardcoded IP в JS-bundle или конфиге.** Frontend ходит на старый IP даже
  после DNS switch. **Решение:** `grep -r "192\." /app/src` перед миграцией,
  переменные окружения для всех endpoint'ов.
- **Cron jobs забыли перенести.** Бэкап-скрипт остался только на старом.
  **Решение:** `crontab -l > /tmp/cron-old.txt && find /etc/cron.d -type f` и
  скопировать на новый.
- **Docker network subnets конфликтуют.** Оба сервера в одной LAN с одинаковыми
  внутренними подсетями. **Решение:** `/etc/docker/daemon.json` с явным
  `default-address-pools` ДО первого `docker compose up`.

## Граничные случаи

- **БД > 100GB.** Backup-restore медленный (часы). Рассмотреть live (логическая
  репликация) или blue-green.
- **Stateless app только.** Rsync не нужен — просто copy compose-файла + start
  на новом + DNS switch.
- **Сертификаты Let's Encrypt.** На новом сервере acme.sh с нуля (DNS challenge
  если возможно — не требует доступа к 80 порту до cutover).
- **acme.sh с DNS API.** Credentials провайдера должны быть на новом сервере
  до первого `acme.sh --issue`.
- **WebSocket-соединения.** Разрываются при DNS switch. Решение: client-side
  reconnect логика + graceful shutdown (`docker stop --time=30`).
- **Floating/static IP у провайдера.** Если можно перевесить тот же IP с старого
  на новый — DNS switch не нужен вовсе. Уточнять у провайдера заранее.
- **PostgreSQL разных версий.** При смене PG 14 → 16 нужен `pg_upgrade` или
  логическая репликация (она работает между версиями). Простой dump/restore
  тоже работает между minor версиями.

## Bundled Resources

- `scripts/01-pre-migration-backup.sh` — обязательный backup перед миграцией.
- `scripts/02-rsync-incremental.sh` — параметризованный rsync с поддержкой
  `--link-dest`.
- `scripts/03-cutover.sh` — оркестрирует stop старого + start нового + DNS-switch.
- `scripts/04-post-migration-verify.sh` — row counts + healthcheck + TLS check.
- `templates/migration-runbook.md` — шаблон runbook'а для конкретной миграции.
- `references/strategies-tradeoffs.md` — таблица 4 стратегии × downtime / cost /
  complexity / data loss risk + развёрнутые примеры.