# <!-- DOC_TYPE: services|networks|volumes|databases|domains|cron|host-scripts|automations|server -->

<!--
Шаблон для генерации одного из 8 inventory-документов.
Скилл inventory-scan использует этот шаблон, когда документ ещё не существует
в `inventory/hosts/<host>/`. Если документ уже есть — НЕ перезаписываем,
а правим через Edit с пометкой `<!-- snapshot YYYY-MM-DD: было X, стало Y -->`.

Маркеры подстановки (заменяются генератором):
- {{HOST_DIR}}      — например, `prod-<your-server-ip>` (или `prod-<ssh-alias>`)
- {{SNAPSHOT_DATE}} — дата свежего snapshot, YYYY-MM-DD
- {{DOC_TYPE}}      — тип документа (services, networks, ...)
- {{DOC_TITLE}}     — человекочитаемое название («Контейнеры и сервисы»)
- {{TABLE_BODY}}    — таблица данных, сгенерированная из snapshot
- {{NOTES}}         — заметки оператора (пусто при первой генерации)
-->

# {{DOC_TITLE}} — {{HOST_DIR}}

> **Источник:** snapshot {{SNAPSHOT_DATE}}
> **Документ:** `inventory/hosts/{{HOST_DIR}}/{{DOC_TYPE}}.md`
> **Last verified:** {{SNAPSHOT_DATE}}

## Сводка

<!-- 2-3 предложения: что описано, на основе чего, какие документы дополняют -->

## Таблица

{{TABLE_BODY}}

<!--
Колонки таблицы зависят от типа документа:

services.md     — | container_name | image | networks | ports | health |
networks.md     — | name | driver | internal | subnet | aliases |
volumes.md      — | volume | driver | mountpoint | size | used_by |
databases.md    — | db_name | container | port | role | size |
domains.md      — | domain | dns_target | tls_source | nginx_block |
cron.md         — | schedule | command | log | owner |
host-scripts.md — | script | mode | owner | calls | status |
automations.md  — | name | trigger | schedule | runs | touches | log | status |
server.md       — | parameter | value | source |

automations.md — сводная витрина ВСЕХ автоматизаций сервера независимо от механизма
запуска (cron + systemd-timer + watcher + webhook + ручной запуск). Агрегирует cron.md
и host-scripts.md, добавляет timers/watchers — НЕ копирует их слово в слово.
Колонка `touches` (что трогает: БД / сервис / внешний API) — источник связей для
диаграммы automations.mmd. Значения trigger: cron / systemd-timer / watcher / webhook /
manual. status: active / failing / disabled / `? уточнить`.
-->

## Drift с предыдущим snapshot

<!-- Заполняется генератором при обновлении.
     Если drift'ов нет — пишем «drift'ов не найдено». -->

- ничего — synchronisation OK

## Заметки оператора

{{NOTES}}

<!--
Сюда оператор пишет вручную:
- Контекст: почему service назван именно так
- Технический долг: «container_name = legacy, переименовать в этапе X»
- Открытые вопросы: «source <example.com> cert — найти»

ЭТА СЕКЦИЯ НИКОГДА НЕ ПЕРЕЗАПИСЫВАЕТСЯ ГЕНЕРАТОРОМ.
inventory-scan читает её и сохраняет как есть.
-->

## Honest unknown

<!--
Если какие-то поля в таблице — `? уточнить` или `нет данных`,
здесь короткое объяснение почему данные неполные:

Пример:
- `tls_source` для `<example.com>` = `? уточнить` — сертификат работает,
  но не находится ни в /etc/letsencrypt/, ни в ~/.acme.sh/
- `size` для `<volume-name>` = `? уточнить` — `docker system df -v`
  не выдаёт размеры external volume

Это правило перекрывает любые попытки «сгладить»
несуществующими значениями.
-->