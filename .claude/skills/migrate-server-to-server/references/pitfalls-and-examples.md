# Миграция: грабли, граничные случаи и разобранные примеры

Справка к скиллу `/migrate-server-to-server`. Открывать в двух ситуациях: планируешь
миграцию и хочешь увидеть, как она выглядит целиком (раздел «Примеры»), или шаг повёл себя
не так, как написано в процедуре (разделы «Грабли» и «Граничные случаи»).

Сравнение четырёх стратегий с командами — соседний `strategies-tradeoffs.md`.

---

# Примеры

## Пример 1: миграция трёх ботов (rsync-incremental)

Стек: 3 telegram-бота, общий postgres, ~3GB данных. Downtime 5 мин приемлем.
Стратегия: rsync-incremental (1 день полный + 1 день delta + cutover).

```bash
# Пятница вечер: полный rsync
rsync -avz /var/lib/docker/volumes/ new:/var/lib/docker/volumes/  # ~5 мин

# Суббота утро: delta rsync — 🔴 RED ZONE (--delete), type-to-confirm перед запуском
rsync -avz --delete /var/lib/docker/volumes/ new:/var/lib/docker/volumes/  # ~30 сек

# Суббота вечер: cutover окно
ssh old 'docker compose -f /opt/bot1/docker-compose.yml stop'
ssh old 'docker compose -f /opt/bot2/docker-compose.yml stop'
ssh old 'docker compose -f /opt/bot3/docker-compose.yml stop'
# 🔴 RED ZONE (--delete), type-to-confirm перед запуском
rsync -avz --delete /var/lib/docker/volumes/ new:/var/lib/docker/volumes/  # ~5 сек delta
ssh new 'cd /opt/bot1 && docker compose up -d'
# ... остальные боты
# DNS switch для каждого домена
# Verify: каждый бот отвечает на /health
```

## Пример 2: миграция production-стека с zero downtime (blue-green)

Стек: API + frontend, 50k активных пользователей, downtime недопустим.
Стратегия: blue-green с logical replication PG.

См. детали в `references/strategies-tradeoffs.md`, секция Blue-Green.

---

# Грабли, на которых уже спотыкались

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
- **Машина оператора продолжает работать со старым сервером.** SSH-туннели, MCP-серверы
  и деплой-скрипты после cutover молча смотрят на старый IP: «зелёный» health-check MCP
  проверяет мёртвую копию БД, а правка через него уходит в данные, которые никто не читает;
  первый деплой падает или, хуже, уезжает на старый сервер. **Решение:** секция «Рабочее
  место оператора» в Шаге 5 — обязательная часть verify, не опция.
- **Конфиг на сервере ушёл вперёд git — на новый уехала отставшая версия.** Правки
  боевого конфига вносили руками (`nano` + `nginx -s reload`) мимо push-to-pull, git
  их не получил. При клонировании на новый сервер часть боевой конфигурации молча
  теряется. **Решение:** drift-сверка в pre-migration checklist (Шаг 1, пункт 8) —
  `diff`/`sha256` боевого конфига против git ДО переноса; расходится → сначала синхрон
  git с боевой версией (реальное состояние сервера — истина при расхождении). Боевой
  кейс 2026-07-09: nginx `/comics/`, `/sw.js`, HSTS-правки жили только на сервере.
- **Пачки SSH-подключений при переносе ловят UFW rate-limit нового сервера.** Миграция
  гонит десятки `ssh`/`scp`/`rsync` подряд; если на приёмнике `ufw limit` на порту 22
  (наследие старого bootstrap до фикса) — самобан на 30 сек, соединения рвутся
  `Connection closed`/`timed out`. **Решение:** на приёмнике `ufw allow 22` (защита —
  fail2ban, не UFW-лимит; см. bootstrap-new-server); со стороны Mac — SSH-мультиплексор
  (`ControlMaster auto` / `ControlPersist`) переиспользует одно соединение. Промежуточный
  обход, если приёмник ещё под лимитом: ProxyJump через другой сервер того же ДЦ.
- **Docker network subnets конфликтуют.** Оба сервера в одной LAN с одинаковыми
  внутренними подсетями. **Решение:** `/etc/docker/daemon.json` с явным
  `default-address-pools` ДО первого `docker compose up`.

---

# Граничные случаи

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

