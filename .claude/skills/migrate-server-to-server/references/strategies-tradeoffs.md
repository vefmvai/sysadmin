# Стратегии миграции: trade-offs

Детальное сравнение 4 стратегий миграции server-to-server. Используется в Шаге 2
скилла `migrate-server-to-server` (выбор стратегии).

---

## Сводная таблица

| Стратегия | Downtime | Сложность setup | Стоимость | Риск потери данных | Когда выбирать |
|-----------|----------|-----------------|-----------|--------------------|----------------|
| **Live** (логическая репликация) | 30-120 сек | Высокая | 1x | Очень низкий | PG-only, downtime < 5 мин критичен |
| **Backup-Restore** | 10-60 мин | Низкая | 1x | Низкий (есть дамп) | Большинство случаев, БД < 100GB |
| **Rsync-Incremental** | 5-15 мин | Средняя | 1x | Низкий | Средний объём, есть дни на параллельную работу |
| **Blue-Green** | 0 сек | Очень высокая | 2x временно | Очень низкий | Mission-critical, downtime недопустим |

---

## 1. Live Migration (логическая репликация)

### Применимость

- Стек преимущественно PostgreSQL (Redis тоже поддерживается через RDB+AOF).
- Терпимый downtime < 5 мин (только DNS switch).
- Готов потратить 1-2 часа на setup репликации заранее.

### Преимущества

- **Минимальный downtime** — только DNS switch (TTL × 2 на propagation).
- **Нет окна потери данных** — репликация продолжается до самого cutover.
- **Работает между minor-версиями PG** (например, 16.2 → 16.5).

### Недостатки

- **Сложный setup** — wal_level=logical, publication, subscription, начальная
  синхронизация схемы pg_dump.
- **Не все типы данных реплицируются** — DDL не реплицируется, large objects
  только частично, sequences отдельно.
- **Требует версии PG ≥ 10** на обоих концах.
- **Redis сложнее** — RDB+AOF гибрид требует CONFIG SET appendonly yes,
  старый Redis должен поддерживать BGSAVE.

### Setup (PostgreSQL)

```sql
-- На старом
ALTER SYSTEM SET wal_level = 'logical';
ALTER SYSTEM SET max_replication_slots = 10;
ALTER SYSTEM SET max_wal_senders = 10;
-- restart PG

-- Создать пользователя для репликации
CREATE USER replicator WITH REPLICATION PASSWORD '<strong>';
GRANT pg_read_all_data TO replicator;

-- Publication
CREATE PUBLICATION all_tables FOR ALL TABLES;
```

```sql
-- На новом (схема уже создана через pg_dump --schema-only)
CREATE SUBSCRIPTION sub_myapp
  CONNECTION 'host=OLD_IP port=5432 dbname=myapp user=replicator password=<strong>'
  PUBLICATION all_tables;

-- Ждать synchronized
SELECT subname, srsubstate FROM pg_subscription_rel;
-- srsubstate должен стать 'r' (ready) для всех таблиц
```

### Cutover

```bash
# 1. Убедиться что lag = 0
ssh new "docker exec postgres psql -U postgres -c \"SELECT * FROM pg_stat_subscription\""
# pg_stat_subscription.last_msg_send_time ≈ now()

# 2. Stop приложений на старом
ssh old "cd /opt/<svc> && docker compose stop"

# 3. DNS switch на новый IP

# 4. Drop subscription на новом
ssh new "docker exec postgres psql -U postgres -c 'DROP SUBSCRIPTION sub_myapp'"

# 5. Start приложений на новом
ssh new "cd /opt/<svc> && docker compose up -d"
```

---

## 2. Backup-Restore

### Применимость

- БД < 100GB (полный дамп умещается во время окна).
- Терпимый downtime 10-60 мин.
- Любой объём bind-mount данных (volumes отдельно через tar).
- Самый частый случай для маленьких/средних проектов.

### Преимущества

- **Простота** — один `pg_dumpall` плюс `tar` плюс `scp`.
- **Универсальность** — работает между любыми версиями PG (с поправкой на features).
- **Изолированность** — нет связи между серверами после копирования.

### Недостатки

- **Большой downtime** — пока идёт дамп + копирование + restore, сервис недоступен.
- **Размер растёт линейно с БД** — для 100GB БД дамп 30+ ГБ, время 30+ мин.

### Процедура

```bash
# 1. Stop сервиса на старом (downtime начинается)
ssh old "cd /opt/<svc> && docker compose stop"

# 2. pg_dumpall (~10-30 мин для 50GB БД)
ssh old "docker exec postgres pg_dumpall -U postgres | gzip > /backup/full.sql.gz"

# 3. tar volumes
ssh old "tar czf /backup/docker-volumes.tar.gz /var/lib/docker/volumes/"

# 4. scp на новый (~5-15 мин в зависимости от bandwidth)
ssh old "scp /backup/*.gz new:/tmp/"

# 5. На новом: restore схемы и volumes
ssh new "tar xzf /tmp/docker-volumes.tar.gz -C /"
ssh new "cd /opt/<svc> && docker compose up -d postgres"
ssh new "gunzip < /tmp/full.sql.gz | docker exec -i postgres psql -U postgres"

# 6. Start всех сервисов
ssh new "cd /opt/<svc> && docker compose up -d"

# 7. DNS switch
```

---

## 3. Rsync-Incremental

### Применимость

- Объём данных 10-100 GB.
- Есть несколько дней на параллельную работу (день 1 + день 2 + cutover).
- Терпимый downtime 5-15 мин (только финальный delta + restart).

### Преимущества

- **Малый финальный downtime** — основная масса данных копируется заранее, в
  окне cutover только delta.
- **Гибкий** — bind mounts, named volumes, любые файлы переносятся одинаково.
- **Параллельная работа** — старый сервер продолжает работать во время дня 1 и
  дня 2.

### Недостатки

- **Не подходит для PG `_data` напрямую** — копирование PGDATA на работающий
  PG некорректно (race condition в WAL). Решение: rsync для bind-mount uploads
  + pg_dumpall для PG.
- **Требует SSH доступа `rsync` с привилегиями** (часто sudo).
- **3 дня минимум** — нельзя сделать в один заход.

### Процедура

```bash
# День 1 — первый полный rsync
rsync -avz /var/lib/docker/volumes/ new:/var/lib/docker/volumes/  # ~10-60 мин

# День 2 — delta
rsync -avz --delete /var/lib/docker/volumes/ new:/var/lib/docker/volumes/  # ~30 сек - 5 мин

# День 3 — cutover окно
ssh old "cd /opt/<svc> && docker compose stop"     # downtime START
rsync -avz --delete /var/lib/docker/volumes/ new:/var/lib/docker/volumes/  # ~10 сек
# pg_dumpall отдельно для PG (он не rsync'ится корректно)
ssh old "docker exec postgres pg_dumpall | gzip | ssh new 'gunzip | docker exec -i postgres psql -U postgres'"
ssh new "cd /opt/<svc> && docker compose up -d"   # downtime END
# DNS switch
```

### Hardlink dedupe (для multiple snapshots)

Если хочется держать несколько incremental snapshots для отката:

```bash
rsync -avz --link-dest=/var/lib/docker/volumes.snapshot-day1/ \
    /var/lib/docker/volumes/ \
    new:/var/lib/docker/volumes.snapshot-day2/
# Файлы которые не изменились — hardlink, не дубликат
```

---

## 4. Blue-Green

### Применимость

- Mission-critical: downtime недопустим (платёжные системы, SLA 99.99%).
- Бюджет позволяет 2x ресурсов на 1-2 недели.
- Нужен мгновенный rollback (один nginx reload).

### Преимущества

- **0 downtime** — оба сервера работают параллельно, cutover атомарен.
- **Мгновенный rollback** — переключить weighted обратно (30-60 сек).
- **Тестируемость** — можно отправить 1% трафика на green, посмотреть метрики,
  только потом 100%.

### Недостатки

- **2x cost** — оба сервера работают одновременно 1-2 недели.
- **Сложный setup** — нужен LB перед обоими (nginx с upstream / Cloudflare LB /
  HAProxy).
- **Синхронизация данных** — БД должна реплицироваться live между blue и green
  (logical replication PG обязательно).
- **Asymmetric bugs** — если приложение пишет в обе БД (split-brain), всё ломается.

### Архитектура

```
                 ┌──── Cloudflare LB / nginx ────┐
                 │ weight: 100% blue / 0% green  │
                 └──┬───────────────────────┬────┘
                    │                       │
         ┌──────────▼─────────┐  ┌──────────▼─────────┐
         │  BLUE (old VPS)    │  │  GREEN (new VPS)   │
         │  app + postgres    │  │  app + postgres    │
         └────────┬───────────┘  └─────────▲──────────┘
                  │  logical replication   │
                  └────────────────────────┘
```

### Cutover

```bash
# 1. Убедиться что данные синхронизированы (lag = 0)
# 2. Изменить weighted в nginx upstream (или Cloudflare LB)
#    upstream app {
#        server blue.example.com weight=0;
#        server green.example.com weight=100;
#    }
# 3. nginx -s reload (атомарно для новых соединений)
# 4. Существующие соединения дорабатывают на blue 30-60 сек
# 5. Мониторить метрики green 24 часа
# 6. Если ОК — отключить репликацию blue → green
```

### Rollback

```bash
# Один nginx reload — обратно на blue
upstream app {
    server blue.example.com weight=100;
    server green.example.com weight=0;
}
nginx -s reload
# Восстановление: 30-60 сек
```

---

## Как выбирать (decision tree)

```
1. Терпимый downtime < 60 сек И есть бюджет 2x?
   → Blue-Green

2. Терпимый downtime < 5 мин И стек PG-only?
   → Live (логическая репликация)

3. Объём 10-100 GB И есть несколько дней?
   → Rsync-Incremental

4. Иначе:
   → Backup-Restore (универсальный fallback)
```

При сомнении выбирать Backup-Restore — простейший, наименьший риск
конфигурационной ошибки, для большинства проектов downtime 10-30 мин приемлем.