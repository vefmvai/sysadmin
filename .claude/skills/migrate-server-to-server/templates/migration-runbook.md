# Migration Runbook — `<MIGRATION_NAME>`

**Дата планируемой миграции:** YYYY-MM-DD
**Окно cutover:** HH:MM - HH:MM (UTC) / HH:MM - HH:MM (локальное)
**Стратегия:** `live` / `backup-restore` / `rsync-incremental` / `blue-green`
**Терпимый downtime:** N минут

---

## Серверы

| Роль | Host | IP | Провайдер | Доступ |
|------|------|----|-----------|--------|
| Old (blue) | old.example.com | X.X.X.X | <PROVIDER> | ssh user@old |
| New (green) | new.example.com | Y.Y.Y.Y | <PROVIDER> | ssh user@new |

## Сервисы для переноса

| Сервис | Volumes | Размер | Зависимости | Домен |
|--------|---------|--------|-------------|-------|
| <SVC1> | <vol_data> | <Xgb> | postgres | <domain1> |
| <SVC2> | <vol_data> | <Ygb> | redis | <domain2> |

## Pre-migration checklist

- [ ] Inventory старого сервера актуален (snapshot < 7 дней)
- [ ] Размеры volumes известны (`du -sh`)
- [ ] Зависимости задокументированы выше
- [ ] Бэкап перед миграцией: `bash scripts/01-pre-migration-backup.sh user@old`
- [ ] Новый сервер прошёл `bootstrap-new-server`
- [ ] TTL DNS снижен до 300 сек за 24-48 ч до cutover

## Yellow Zone брифинг оператору

1. **Что меняется:** <список сервисов> переезжают со старого на новый.
2. **Что может пойти не так:** <конкретные риски этой стратегии>.
3. **Окно простоя:** ожидаемые N минут downtime.
4. **Точка невозврата:** до DNS switch — откат бесплатный.
5. **Откат:** `<команда возврата DNS на старый IP>`.
6. **Подтверждение:** оператор пишет «согласен на миграцию <NAME>».

## Шаги cutover (день N)

| # | Действие | Команда | Ответственный | Время |
|---|----------|---------|---------------|-------|
| 1 | Финальный rsync delta | `bash scripts/02-rsync-incremental.sh ... cutover` | sysadmin | T+0 |
| 2 | Start сервисов на новом | (в скрипте 03-cutover.sh) | sysadmin | T+5 |
| 3 | Smoke-test через IP | (в скрипте 03-cutover.sh) | sysadmin | T+7 |
| 4 | DNS switch в панели | вручную в Cloudflare/Selectel | оператор | T+8 |
| 5 | Мониторить propagation | `dig <domain>` × 20 каждые 30 сек | sysadmin | T+8..T+18 |
| 6 | Verify целостности | `bash scripts/04-post-migration-verify.sh` | sysadmin | T+20 |

## Post-migration

- [ ] Все сервисы PASS в `04-post-migration-verify.sh`
- [ ] Inventory обновлён (новый IP, новый snapshot)
- [ ] Старый сервер: stop сервисов, но не destroy
- [ ] Запись в `incidents/YYYY-MM-DD-migration-<NAME>.md`

## Cleanup старого (через 1-2 недели)

- [ ] Финальный snapshot старого сервера (страховка)
- [ ] Compose-файлы из старого — в git как cold archive
- [ ] Уведомить провайдера о cancel

## Rollback (если что-то пошло не так)

1. DNS switch обратно на старый IP (один клик в панели).
2. На старом: `ssh old 'docker compose -f /opt/<svc>/docker-compose.yml up -d'`.
3. Подождать TTL × 2 (10 мин) для propagation.
4. Curl-проверка что старый снова отвечает.
5. Расследовать причины на новом, повторить миграцию с исправлениями.