# PostgreSQL restore — порядок и edge cases

Справочник по восстановлению PostgreSQL из дампов. Главное — соблюдать порядок шагов,
иначе будут неочевидные ошибки.

## Каноничный порядок

```
1. Поднять контейнер с правильным образом   → pg_isready
2. Восстановить globals (роли)              → pg_dumpall --globals-only
3. Создать БД                               → createdb
4. Восстановить данные                      → pg_restore
5. (опционально) ANALYZE                    → ускоряет первые запросы
```

## Шаг 1: Образ контейнера

| Тип БД | Образ |
|--------|-------|
| Чистая PostgreSQL без расширений | `postgres:16` (или версия совпадающая с продом) |
| PostgreSQL с pgvector | `pgvector/pgvector:pg16` |
| PostgreSQL с PostGIS | `postgis/postgis:16-3.4` |
| TimescaleDB | `timescale/timescaledb:latest-pg16` |

> **Критично:** версия PostgreSQL должна совпадать с продом до major.minor. Если на проде
> 16.3 — не используй 16.5, могут быть несовместимые системные таблицы.

### pgvector edge case

```
ERROR: type "public.vector" does not exist
```

Эта ошибка означает, что используется чистый `postgres:16`, а в дампе есть колонки типа
`vector` (от расширения pgvector). Решение — использовать образ `pgvector/pgvector:pg16`,
который включает расширение из коробки. Образ полностью совместим с обычным postgres
для всех остальных операций.

## Шаг 2: Восстановление globals

`pg_dump <db>` НЕ включает роли (users, groups). Они хранятся в кластере и общие для всех
БД. Восстанавливать через отдельный файл `globals_*.sql`, созданный командой:

```bash
docker exec <prod-container> pg_dumpall -U postgres --globals-only > globals.sql
```

Восстановление:

```bash
docker exec -i <test-container> psql -U postgres < globals.sql
```

Если пропустить этот шаг, при `pg_restore` будут ошибки:

```
ERROR: role "<role-name>" does not exist
ERROR: must be member of role "owner"
```

## Шаг 3: Создание БД

`pg_restore` восстанавливает СОДЕРЖИМОЕ БД, но саму БД не создаёт. Поэтому:

```bash
docker exec <test-container> createdb -U postgres <db_name>
```

Альтернатива — `pg_restore --create`, но при этом нужен дамп в формате plain (`pg_dump -F p`),
а не custom — мы по умолчанию используем custom (`-F c`).

## Шаг 4: pg_restore

```bash
docker exec -i <test-container> pg_restore \
  -U postgres \
  -d <db_name> \
  --no-owner \
  --no-privileges \
  --verbose \
  < <db_name>_YYYYMMDD.dump
```

| Флаг | Зачем |
|------|-------|
| `--no-owner` | Игнорирует ALTER OWNER — все объекты будут принадлежать пользователю, который запустил pg_restore (postgres) |
| `--no-privileges` | Игнорирует GRANT/REVOKE — упрощает первичный restore |
| `--verbose` | Видно прогресс по таблицам |
| `--clean` | (Не используем!) Дропает существующие объекты — опасно при restore в чужой кластер |
| `--if-exists` | Используется только с `--clean` |

### Игнорируемые ошибки

`pg_restore` всегда возвращает exit code != 0 при наличии любых WARNING. Пример:

```
WARNING: errors ignored on restore: 3
```

Эти 3 ошибки — обычно `extension already exists` или `role X does not exist` (если globals
не загружены полностью). Это НЕ блокирует restore — данные восстановятся, ошибки относятся
к метаданным.

> **Тонкость:** в скриптах не делай `set -e` вокруг pg_restore. Лучше вручную проверять
> row counts после restore, чем падать на «ошибках» которые ничего не значат.

## Шаг 5: ANALYZE (опционально)

После restore таблицы есть, но статистика для query planner — пустая. Первые запросы
будут медленнее, чем обычно. Решение:

```bash
docker exec <test-container> psql -U postgres -d <db_name> -c "ANALYZE;"
```

Не обязательно для restore-test (где сверяем row counts), но полезно перед прод-запуском.

## Сверка row counts с продом

Стандартная проверка после restore:

```sql
-- На проде:
SELECT tablename, n_live_tup
FROM pg_stat_user_tables
ORDER BY n_live_tup DESC
LIMIT 5;

-- На тесте — то же:
SELECT tablename, n_live_tup
FROM pg_stat_user_tables
ORDER BY n_live_tup DESC
LIMIT 5;
```

Допуск ±несколько записей в активных таблицах (между моментом дампа и сверкой могла
пройти активность). Если расхождение значимое (>1%) — restore некорректен, разбираться.

## Особые случаи

### Большие БД (>10 ГБ)

- pg_dump в формате custom (`-F c`) сжимает на лету (zlib level 5 по умолчанию)
- Восстановление одной БД 20 ГБ занимает 30-60 минут
- На SSD — диск становится bottleneck'ом, не CPU

### Параллельный restore

```bash
pg_restore -j 4 ...  # 4 параллельных воркера
```

Ускоряет в ~3 раза на multi-core машинах. Не применять для маленьких БД — overhead больше выигрыша.

### Foreign tables / FDW

Если БД использует foreign data wrapper (postgres_fdw, dblink), после restore нужно:

1. Создать сервер: `CREATE SERVER ...`
2. Создать user mapping: `CREATE USER MAPPING ...`

Эти команды есть в дампе, но требуют, чтобы внешний сервер был доступен. Иначе при ANALYZE
будут ошибки connection refused.

### Логические репликационные слоты

Слоты не переносятся через дамп. После restore их надо пересоздать:

```sql
SELECT pg_create_logical_replication_slot('slot_name', 'pgoutput');
```

## Mind-map порядка

```
restic restore
    ↓
docker run pgvector/pgvector:pg16
    ↓
pg_isready (ждать)
    ↓
psql < globals.sql        ← роли
    ↓
createdb <db>             ← пустая БД
    ↓
pg_restore < <db>.dump    ← данные
    ↓
psql < count(*)           ← сверка
    ↓
docker rm -f              ← очистка
```