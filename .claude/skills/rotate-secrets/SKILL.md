---
name: rotate-secrets
description: |
  Плановая ротация секретов (DB-пароль, API-токен, SSH-ключ, TLS-cert, OAuth-secret) с обновлением
  inventory/access.md. Процедура: новый → атомарная подмена → verify → удалить старый. Yellow Zone,
  подтверждение + incident-запись в incidents/YYYY-MM-DD-rotate-<secret>.md.
  Триггеры: «ротировать секрет», «сменить пароль БД», «rotate password», «плановая ротация»,
  «secret expired», «compromise — ротировать», «сменить токен», «обновить ключ».
  НЕ для первичной настройки секретов (setup-secrets-vault); НЕ для удаления секрета без замены.
allowed-tools: Bash, Read, Edit, Write
---

<role>
Я ротирую секреты по плановому расписанию или при подозрении на компрометацию.
Каждая ротация — Yellow Zone: оператор получает брифинг 6 пунктов и подтверждает
перед началом. Я работаю по принципу «новый создан → атомарно подменён → проверен →
старый удалён» — никогда не удаляю старый секрет до того, как новый подтверждён в
работе.
</role>

<context>
Что предполагается:
- Есть менеджер паролей (Keychain macOS / pass / KeePassXC / Bitwarden) с доступом
  к индексу секретов.
- `inventory/access.md` существует и содержит реестр секретов с датами последней
  и следующей ротации.
- SSH-доступ к серверу-потребителю секрета.
- Свежий бэкап БД (если ротируется DB password) — < 24 часов.
</context>

<goals>
- Новый секрет применён везде, где использовался старый.
- Старый секрет больше не работает (проверено явно).
- `inventory/access.md` обновлён (дата ротации, дата следующей).
- Запись в `incidents/YYYY-MM-DD-rotate-<secret>.md` создана.
- Сервисы продолжают работать (downtime ≤ 5 мин для DB password, ≤ 0 для API token).
</goals>

<parameters>
- `SECRET_TYPE` — `db-password` / `api-token` / `ssh-key` / `tls-cert` / `oauth-secret`.
- `SECRET_NAME` — имя секрета из `inventory/access.md` (например, `postgres-myapp`).
- `REASON` — `scheduled` / `compromised` / `manual`.
</parameters>

# Инструкции

## Шаг 1. Pre-check (Green Zone)

- [ ] Секрет существует в `inventory/access.md` — найти строку с этим `SECRET_NAME`.
- [ ] Знаем все места использования:

  ```bash
  ssh "$SERVER" "grep -rln 'VAR_NAME' /opt/*/.env /etc/cron.d/ 2>/dev/null"
  ```

  Все потребители должны быть обновлены вместе, иначе часть продолжит работать со
  старым.
- [ ] Свежий бэкап (для DB password — обязательно): `restic snapshots --tag daily |
      tail -1` показывает время < 24 ч назад.
- [ ] Окно простоя согласовано (для DB password — до 5 мин из-за restart клиентов).

## Шаг 2. Yellow Zone брифинг 6 пунктов

Оператор получает:

1. **Что меняется:** ротируется `<SECRET_NAME>` типа `<SECRET_TYPE>`, причина
   `<REASON>`.
2. **Где используется:** список найденных потребителей (3 .env файла + 1 cron).
3. **Окно простоя:** ожидаемые секунды/минуты (зависит от типа).
4. **Риски:** что может пойти не так (например, для DB password — клиенты с pool'ом
   могут продолжить работать со старым).
5. **Откат:** в течение 5 минут возможен — старый секрет ещё в менеджере паролей с
   пометкой `-old`.
6. **Подтверждение:** оператор пишет «согласен на ротацию `<SECRET_NAME>`».

## Шаг 3. Категория-специфичная процедура

### 3.1 db-password

```bash
# 1. Сгенерировать новый
NEW=$(openssl rand -base64 32 | tr -d '+/=' | head -c 32)

# 2. Сохранить в менеджере паролей под ключом <SECRET_NAME>-new
#    (не перезаписывая старый — он понадобится для отката)
#    Keychain: security add-generic-password -a infra -s <NAME>-new -w "$NEW"
#    pass:     pass insert -e infra/db/<NAME>-new <<< "$NEW"

# 3. ALTER USER в БД
ssh "$SERVER" "docker exec postgres psql -U postgres \
    -c \"ALTER USER <role> WITH PASSWORD '$NEW'\""

# 4. Атомарно подменить во всех .env (НЕ редактировать вручную — sed)
for env_file in $ENV_FILES; do
    ssh "$SERVER" "sed -i.bak 's|^<VAR>=.*|<VAR>=$NEW|' '$env_file'"
done

# 5. Restart всех потребителей (минимальный downtime)
for compose_dir in $CONSUMER_DIRS; do
    ssh "$SERVER" "cd $compose_dir && docker compose restart"
done

# 6. Verify: connection works
ssh "$SERVER" "PGPASSWORD='$NEW' psql -h 127.0.0.1 -U <role> <db> -c 'SELECT 1'"
# Ожидаем: 1

# 7. Verify: старый пароль НЕ работает
ssh "$SERVER" "PGPASSWORD='<OLD>' psql -h 127.0.0.1 -U <role> <db> -c 'SELECT 1'" \
    && echo "FAIL: старый пароль ещё работает!" \
    || echo "OK: старый пароль не работает"

# 8. Удалить старый из менеджера паролей (только после verify)
#    Keychain: security delete-generic-password -a infra -s <NAME>-old
#    pass:     pass rm infra/db/<NAME>-old
# Переименовать <NAME>-new → <NAME>
```

См. `scripts/rotate-db-password.sh` — параметризованная версия для PG/MySQL/Redis.

### 3.2 api-token

```bash
# 1. Создать новый в провайдерской панели (Telegram BotFather, GitHub Settings,
#    Cloudflare API tokens, Yandex.Disk OAuth)
# 2. Сохранить в менеджере паролей как <NAME>-new
# 3. Подменить в .env (как db-password)
# 4. Restart соответствующего сервиса
# 5. Verify через test API call:
curl -sS "https://api.telegram.org/bot$NEW/getMe" | jq .ok
# Ожидаем: true
# 6. Revoke старого в провайдерской панели (только после verify)
```

См. `scripts/rotate-api-token.sh`.

### 3.3 ssh-key

```bash
# 1. Сгенерировать новую пару
ssh-keygen -t ed25519 \
    -C "infra-deploy-key-$(date +%Y-%m-%d)" \
    -f ~/.ssh/infra-deploy-new \
    -N ""

# 2. Добавить новый public key в authorized_keys (НЕ заменить ещё)
cat ~/.ssh/infra-deploy-new.pub | ssh "$SERVER" 'tee -a ~/.ssh/authorized_keys'

# 3. Verify подключение с новым ключом из ВТОРОЙ сессии (важно!)
ssh -i ~/.ssh/infra-deploy-new "$SERVER" 'echo OK'
# Только после этого:

# 4. Удалить старый ключ из authorized_keys
OLD_PUB=$(cat ~/.ssh/infra-deploy-old.pub)
ssh "$SERVER" "grep -v '$OLD_PUB' ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.new \
    && mv ~/.ssh/authorized_keys.new ~/.ssh/authorized_keys"

# 5. Обновить локальный SSH config (~/.ssh/config)
sed -i.bak 's|infra-deploy-old|infra-deploy-new|' ~/.ssh/config

# 6. Старый ключ — в архив (НЕ удалить совсем — пригодится для аудита)
mv ~/.ssh/infra-deploy-old ~/.ssh/archive/infra-deploy-$(date +%Y-%m-%d)
```

### 3.4 tls-cert

Обычно автоматически через acme.sh + cert-reload-smart.sh (см. ADR 0008 проекта-носителя).

```bash
# Плановая ротация — ничего не делать, acme.sh сам обновит за 30 дней до истечения
# Принудительно:
ssh "$SERVER" '~/.acme.sh/acme.sh --renew -d <domain> --force'

# Verify
echo | openssl s_client -connect <domain>:443 -servername <domain> 2>/dev/null \
    | openssl x509 -noout -dates
```

### 3.5 oauth-secret

Зависит от провайдера. Базовая логика та же (создать новый → подменить → verify →
revoke старого), но конкретные шаги — в документации провайдера (Yandex OAuth,
Google OAuth, GitHub OAuth и т.д.).

## Шаг 4. Update access.md

В `inventory/shared/access.md` найти строку с `<SECRET_NAME>` и обновить:

```diff
-| postgres-myapp | infra/db/postgres-myapp | 2026-01-15 | 2026-04-15 |
+| postgres-myapp | infra/db/postgres-myapp | 2026-04-25 | 2026-07-25 |
```

Поля: имя секрета | путь в менеджере паролей | последняя ротация (сегодня) |
следующая ротация (сегодня + период по типу из `references/rotation-schedule.md`).

## Шаг 5. Запись в incident

Создать `incidents/YYYY-MM-DD-rotate-<NAME>.md` по шаблону `templates/rotation-incident.md`:

- Что произошло (плановая ротация / реакция на компромисс).
- Что было сделано (команды + кто запускал).
- Урок (если ротация выявила проблему — например, забыли потребитель в cron).

## Примеры

### Пример 1: плановая ротация POSTGRES_PASSWORD

```bash
# inventory/access.md показывает: postgres-myapp — следующая ротация 2026-04-25
# Сегодня 2026-04-25 — пора.

# Шаг 1: pre-check
ssh "$SERVER" 'grep -rln "POSTGRES_PASSWORD" /opt/*/.env'
# например: /opt/shared-db/.env, /opt/myapp/.env, /opt/myapi/.env  # ПРИМЕР

# Шаг 2: брифинг (Yellow Zone) — оператор подтверждает.

# Шаг 3: scripts/rotate-db-password.sh postgres-myapp
# (внутри: сгенерировать → ALTER → sed → restart → verify)

# Шаг 4: обновить access.md
# Шаг 5: incidents/2026-04-25-rotate-postgres-myapp.md
```

### Пример 2: компромисс — Telegram bot token утёк в публичный git

```bash
# 1. Срочно (не по плановому расписанию):
#    - Создать новый token в @BotFather (/revoke + /token)
#    - НЕ ждать брифинга — при компромиссе действовать быстро,
#      но всё равно записать incident
# 2. Обновить .env на сервере
# 3. Restart bot-сервиса
# 4. Verify через getMe API
# 5. incidents/2026-04-25-compromise-tgbot-<NAME>.md с разбором как утекло
```

## Failed Attempts

- **«Заменить authorized_keys без verify нового ключа из второй сессии».**
  Если новый ключ сгенерирован неправильно или в config'е опечатка — потеря
  доступа к серверу. **Решение:** ВСЕГДА проверять новый ключ из ОТДЕЛЬНОЙ
  SSH-сессии перед удалением старого.
- **«Не удалить старый api-token после ротации».** Компромисс продолжается
  невидимо. **Решение:** revoke старого в провайдерской панели сразу после
  verify нового.
- **«DB password rotation без compose restart».** Приложения с pool'ом
  соединений могут продолжить работать со старым паролем (старые соединения в
  pool'е). **Решение:** обязательный `docker compose restart` всех клиентов.
- **«Перезаписать запись в менеджере паролей до verify»**. Если новый секрет
  не работает (например, ALTER USER завершился ошибкой), откат невозможен —
  старого секрета уже нет нигде. **Решение:** записывать новый под ключом
  `<NAME>-new`, переименовывать только после полного verify.

## Граничные случаи

- **Secret в cron job.** При ротации обновить cron entry с новым значением
  (`crontab -e` или `/etc/cron.d/`). Cron перечитает файл при следующем запуске,
  restart не нужен.
- **Multiple consumers на разных серверах.** Обновить во ВСЕХ местах одновременно,
  иначе часть будет работать со старым. Best practice: deployment скрипт, который
  обновляет везде атомарно.
- **Cascading rotation** (TLS cert → reload nginx → reload зависимых от nginx
  сервисов). Последовательно, по таблице зависимостей.
- **Секрет используется в встроенном клиенте, не в .env.** Например, hardcoded
  в JS-bundle. Нужна пересборка приложения, не только подмена секрета. **Это —
  отдельный архитектурный долг**, фиксировать в incident как урок.
- **Ротация при работающем массовом импорте/экспорте.** Подождать окончания (если
  scheduled) или принять прерывание (если compromise).

## Bundled Resources

- `scripts/rotate-db-password.sh` — параметризованный для PG/MySQL/Redis (не для
  TLS, не для SSH-ключей — у них своя логика).
- `scripts/rotate-api-token.sh` — общий шаблон для Telegram/GitHub/Cloudflare/etc.
- `templates/rotation-incident.md` — шаблон записи incident.
- `references/rotation-schedule.md` — плановые периоды ротации по типам.