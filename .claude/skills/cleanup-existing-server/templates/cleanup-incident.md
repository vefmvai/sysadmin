# Cleanup incident — {{DATE}} — {{SCOPE}}

<!--
Шаблон записи в incidents/ после прогона cleanup-existing-server.
Имя файла: incidents/YYYY-MM-DD-cleanup-<scope>.md (где <scope> — название
категории или короткое описание, например, "rename-postgres" или
"env-permissions").

Заполнять КАЖДЫЙ раз, даже если категория мелкая. Журнал — основа для
ретроспективы и для следующего оператора.
-->

## Что чистили

- **Категория:** {{CATEGORY}} (одна из: names / permissions / drift / dead-configs / memory-limits)
- **Scope:** {{SCOPE_DETAIL}} (например, «контейнер postgres переименование», «env права в /opt/myapp»)
- **Snapshot до:** `inventory/hosts/{{HOST_DIR}}/snapshots/{{DATE_BEFORE}}/`
- **Snapshot после:** `inventory/hosts/{{HOST_DIR}}/snapshots/{{DATE_AFTER}}/`
- **Бэкап до:** {{BACKUP_REF}} (restic snapshot id или путь к safety-копии)

## Брифинг 6 пунктов (что было утверждено)

1. **ЧТО:** {{WHAT}}
2. **ЗАЧЕМ:** {{WHY}}
3. **РИСКИ:** {{RISKS}}
4. **ОТКАТ:** {{ROLLBACK}}
5. **СТРАХОВКА:** {{SAFETY}}
6. **ПРОВЕРКА:** {{VERIFY}}

## Конкретные команды (для воспроизводимости)

```bash
{{COMMANDS}}
```

## Хронология

- **{{TIME_START}}** — Pre-check (snapshot, backup) — OK
- **{{TIME_BRIEF}}** — Брифинг согласован, оператор сказал «давай»
- **{{TIME_APPLY}}** — Применение изменений
- **{{TIME_VERIFY}}** — Верификация (re-inventory или specific check)
- **{{TIME_END}}** — Готово, изменения заметны в drift-report

Простой (если был): {{DOWNTIME_SECONDS}} секунд.

## Результат

- **Что починилось:** {{FIXED}}
- **Что сломалось:** {{BROKEN}} (если ничего — «без неожиданностей»)
- **Drift до:** {{DRIFT_BEFORE}}
- **Drift после:** {{DRIFT_AFTER}}

## Lessons learned

<!--
Если попался новый граблекейс, не описанный в SKILL.md — кратко записать сюда.
В дальнейшем перенести в .claude/skills/cleanup-existing-server/references/typical-grabli.md.
Пример: «При переименовании postgres внутри сети internal:true Stage 1 не работает —
disconnect + connect через docker network не пускает контейнер обратно в internal-сеть
без явного --internal флага. Обход: остановить контейнер, поправить compose, снова up -d».
-->

- {{LESSON_1}}
- {{LESSON_2}}

## Last verified

{{DATE_AFTER}} — `{{VERIFICATION_COMMAND}}`