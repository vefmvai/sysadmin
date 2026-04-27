# RB-XX: Восстановление БД из бэкапа

**Last verified:** <YYYY-MM-DD>, <agent>, <production-host>

## Metadata

| Параметр | Значение |
|----------|----------|
| Автор | агент-сисадмин |
| Версия | 1.0 |
| Риск | средний |
| Примерное время | 30 мин на одну БД |

## Предусловия

- [ ] Есть свежие snapshot'ы в restic-репозитории `<RESTIC_REPOSITORY>` (проверь `restic snapshots`)
- [ ] Docker работает на хосте
- [ ] Образ `<IMAGE>` доступен (для PostgreSQL с pgvector — `pgvector/pgvector:pg16`)
- [ ] Свободно >= 2x размер крупнейшей БД на диске

## Шаг 0: Извлечение snapshot'а

```bash
restic --password-file /root/.restic-password restore latest --target /tmp/restore
ls /tmp/restore/opt/backups/dbs/
```

## Шаг 1: Поднять временный контейнер

> **ВАЖНО:** Используй именно тот же образ, что на проде. Для БД с pgvector — `pgvector/pgvector:pg16`,
> НЕ чистый `postgres:16`. Тип `public.vector` иначе не существует и pg_restore упадёт.

```bash
docker run -d \
  --name <TEST_CONTAINER> \
  -e POSTGRES_PASSWORD=testpassword \
  -p 5433:5432 \
  <IMAGE>

until docker exec <TEST_CONTAINER> pg_isready -U postgres; do sleep 1; done
```

## Шаг 2: Восстановить globals (роли)

> **Важно:** pg_dump НЕ включает роли. Без globals будут ошибки `role does not exist`.

```bash
docker exec -i <TEST_CONTAINER> psql -U postgres < $(ls /tmp/restore/opt/backups/dbs/globals_*.sql | sort | tail -1)
```

## Шаг 3: Восстановить базы данных

> **Порядок:** сначала `createdb`, затем `pg_restore`. pg_restore сам не создаёт БД.

```bash
# Для каждой БД:
docker exec <TEST_CONTAINER> createdb -U postgres <DB_NAME>

docker exec -i <TEST_CONTAINER> pg_restore \
  -U postgres \
  -d <DB_NAME> \
  --no-owner \
  --no-privileges \
  --verbose \
  < $(ls /tmp/restore/opt/backups/dbs/<DB_NAME>_*.dump | sort | tail -1)
```

## Проверка: сверка row counts с продом

```bash
# Прод
docker exec <PROD_CONTAINER> psql -U postgres -d <DB_NAME> \
  -c "SELECT tablename, n_live_tup FROM pg_stat_user_tables ORDER BY n_live_tup DESC LIMIT 5;"

# Тест
docker exec <TEST_CONTAINER> psql -U postgres -d <DB_NAME> \
  -c "SELECT tablename, n_live_tup FROM pg_stat_user_tables ORDER BY n_live_tup DESC LIMIT 5;"
```

Допуск: ±несколько записей от дневной активности между моментом дампа и сверкой.
Значимое расхождение → блокер, не закрывать прогон.

## Откат

Тестовый контейнер использует другой порт (5433) — продукция не затронута.

```bash
docker rm -f <TEST_CONTAINER>
```

## Примечания по безопасности

- Тестовый контейнер слушает 5433, не 5432 — намеренно, чтобы исключить случайные подключения
  приложений к тестовому экземпляру.
- `testpassword` — только для теста. Никогда не использовать в проде.
- Дампы содержат чувствительные данные → удалить `/tmp/restore/` после проверки.

## История верификаций

### <YYYY-MM-DD> — ___________

**Параметры прогона:**
- Тестовый контейнер: <TEST_CONTAINER> (образ <IMAGE>, порт 5433)
- Источник дампов: <DESTINATION>

**Результаты по базам данных:**

| БД | Статус | Строки (прод vs тест) |
|----|--------|----------------------|
| <DB_NAME> | PASS / FAIL | … |

**Очистка:** Тестовый контейнер удалён после прогона.

---

## Связанное

- Скрипт оркестратора: `/opt/backup/backup-all.sh`
- Скрипт проверки возраста: `/opt/backup/check-backup-age.sh`
- ADR о стратегии бэкапов: `decisions/000X-backup-strategy.md`
- Инвентарь БД: `inventory/databases.md`