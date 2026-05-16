# План проверки sysadmin после рефакторинга 2026-05-16

> **Этот документ для проверки в чистой сессии Claude Code** — после того как контекст текущей сессии очистится. Открой новый чат, скопируй промпт-стартер из конца документа, и Claude пройдёт по этому плану.
>
> **Цель** — убедиться что вся работа Фаз A-D (порядок в системе, mermaid-схемы, автопроверка обновлений, INSTALL.md, релиз v1.0.0) действительно работает у Василия и готова к публикации для учеников.

---

## Что было сделано в работе 2026-05-16

Кратко (детали — в git log сoresponding repos):

**Фаза A — порядок в системе:**
- Старый мозг агента из `infra/.claude/` заархивирован в `infra/_archive/old-brain-2026-05-16/`.
- Bridge `~/.claude/agents/sysadmin.md` переориентирован на новый мозг в `sysadmin/.claude/agents/sysadmin.md`.
- `sysadmin-config.json` перенесён из `sysadmin/` в `infra/`. Дубли `example.json` / `schema.json` в `infra/` удалены.
- Блок «Инфраструктурные задачи» удалён из `~/.claude/CLAUDE.md` (bridge сам справляется с маршрутизацией).
- Cold Start Protocol персоны + `sysadmin-init` + `sysadmin-meet/parts/finale.md` + 5 операционных скиллов (audit-security, setup-backups, setup-secrets-vault, install-monitoring-stack, bootstrap-new-server) + `validate-config.sh` — все используют **единый алгоритм поиска** `$CONFIG_PATH` через `infra/`. Inconsistency `INFRA_DIR_LOCAL` устранена.

**Фаза B — mermaid-диаграммы:**
- Созданы 4 шаблона в `sysadmin/.claude/skills/inventory-scan/templates/diagrams/`: `topology.mmd`, `services-network.mmd`, `domains-routing.mmd`, `vpn-architecture.mmd` + README.
- Скилл `inventory-scan` дополнен Шагом 4.5 (генерация/обновление диаграмм) + триггеры в evals.
- Персона §3.2 «Inventory ↔ реальность» расширена правилом: при архитектурном изменении — обновить mermaid-диаграмму. Чек-лист завершённости задачи дополнен пунктом. Ядро персоны = 400 строк (ровно hard cap ADR-0002).

**Фаза C — автопроверка обновлений:**
- Файл `VERSION` (1.0.0) в корне `sysadmin/`.
- `.update-check` в `.gitignore` (у каждого оператора своя метка).
- Cold Start §5.5 — фоновая проверка раз в 14 дней через `git fetch --tags`. Уведомление 💡 в следующее сообщение если есть новая версия. Команда «обнови sysadmin» — git pull + changelog + Yellow Zone подтверждение.
- Bridge-файл — добавлен триггер «обнови sysadmin».

**Фаза D — публикация:**
- `INSTALL.md` — детальная инструкция для Claude Code (9 шагов установки).
- `README.md` — обновлён для человека (одна фраза установки, новая архитектура двух репо, обновления, удаление).
- Тег `v1.0.0` создан и запушен на github.
- Main `sysadmin/` запушен (origin: `git@github.com:vefmvai/sysadmin.git`).
- `infra/` главный коммит запушен (origin: `git@github.com:vefmvai/infra.git`).
- Release notes подготовлены в `.planning/RELEASE-NOTES-v1.0.0.md` (надо создать GitHub Release вручную или через `gh auth login`).

---

## План проверки — 7 блоков

### Блок 1: Состояние файлов и git-репо

**Цель:** убедиться что структура файлов соответствует плану.

```bash
# 1.1 Bridge-файл указывает на новый мозг
cat ~/.claude/agents/sysadmin.md | head -15
# Должно быть: name: sysadmin, путь .claude/agents/sysadmin.md в /sysadmin/, НЕ в /infra/

# 1.2 В глобальном CLAUDE.md нет блока «Инфраструктурные задачи»
grep -A 2 "Инфраструктурные задачи" ~/.claude/CLAUDE.md
# Должно: ничего не найти

# 1.3 sysadmin-config.json в infra/, не в sysadmin/
ls "$HOME/Yandex.Disk.localized/Claude Code/sysadmin/sysadmin-config.json" 2>&1 | grep -q "No such file" && echo "OK: нет в sysadmin/"
ls "$HOME/Yandex.Disk.localized/Claude Code/infra/sysadmin-config.json" >/dev/null && echo "OK: есть в infra/"

# 1.4 В sysadmin/ остались только публичные example/schema
ls "$HOME/Yandex.Disk.localized/Claude Code/sysadmin/"sysadmin-config*

# 1.5 В infra/ нет дублей example/schema
ls "$HOME/Yandex.Disk.localized/Claude Code/infra/"sysadmin-config* 2>/dev/null
# Должен быть ТОЛЬКО sysadmin-config.json (один файл)

# 1.6 Старый мозг архивирован
ls "$HOME/Yandex.Disk.localized/Claude Code/infra/.claude/" 2>&1 | grep -q "No such file" && echo "OK: .claude/ удалён"
ls "$HOME/Yandex.Disk.localized/Claude Code/infra/_archive/old-brain-2026-05-16/"
# Должно: agents/, skills/, README.md

# 1.7 Размер ядра персоны — 400 строк
wc -l "$HOME/Yandex.Disk.localized/Claude Code/sysadmin/.claude/agents/sysadmin.md"
# Должно: ровно 400

# 1.8 VERSION файл
cat "$HOME/Yandex.Disk.localized/Claude Code/sysadmin/VERSION"
# Должно: 1.0.0

# 1.9 4 mermaid-шаблона
ls "$HOME/Yandex.Disk.localized/Claude Code/sysadmin/.claude/skills/inventory-scan/templates/diagrams/"
# Должно: README.md, domains-routing.mmd, services-network.mmd, topology.mmd, vpn-architecture.mmd

# 1.10 INSTALL.md существует и содержит правильный github URL
grep -c "vefmvai/sysadmin" "$HOME/Yandex.Disk.localized/Claude Code/sysadmin/INSTALL.md"
# Должно: >= 3 упоминания
```

**Критерий успеха:** все 10 проверок дают ожидаемый результат.

---

### Блок 2: Унификация поиска конфига во всех скиллах

**Цель:** проверить что нет старых паттернов `${INFRA_DIR:-$(pwd)}/sysadmin-config.json` и `INFRA_DIR_LOCAL`.

```bash
cd "$HOME/Yandex.Disk.localized/Claude Code/sysadmin"

# 2.1 Старого паттерна нигде нет
! grep -rn 'INFRA_DIR:-\$(pwd)' .claude/ && echo "OK"

# 2.2 INFRA_DIR_LOCAL нигде нет
! grep -rn "INFRA_DIR_LOCAL" .claude/ && echo "OK"

# 2.3 Новый паттерн (массив кандидатов с infra/) есть во всех нужных скиллах
for skill in audit-security setup-backups setup-secrets-vault install-monitoring-stack bootstrap-new-server; do
    if grep -q "../infra/sysadmin-config.json" .claude/skills/$skill/SKILL.md; then
        echo "OK: $skill"
    else
        echo "FAIL: $skill — нет нового паттерна"
    fi
done

# 2.4 То же в sysadmin-init (СКИЛЛ ВКЛЮЧАЕТ путь записи в infra)
grep -c "infrastructure.root_path" .claude/skills/sysadmin-init/SKILL.md
# Должно: >= 1

# 2.5 validate-config.sh находит схему относительно sysadmin/, не infra/
grep -q "SYSADMIN_ROOT=" .claude/skills/sysadmin-init/scripts/validate-config.sh && echo "OK"
```

**Критерий успеха:** все скиллы используют новый паттерн, старые ссылки удалены.

---

### Блок 3: Cold Start Protocol и работа агента

**Цель:** убедиться что агент стартует корректно при вызове из произвольной папки.

**Действия Claude (в чистой сессии):**

1. Открыть Claude Code в **произвольной папке** (например, `~/` или любой проект пользователя).
2. Написать: `@sysadmin привет, представься в одной строке`.
3. **Ожидаемое поведение:**
   - Bridge-файл срабатывает (Claude видит subagent `sysadmin`).
   - Subagent читает свою полную персону из `sysadmin/.claude/agents/sysadmin.md`.
   - Cold Start Protocol запускается: ищет `sysadmin-config.json` → находит в `infra/`.
   - Читает inventory из `infra/inventory/`.
   - Предупреждает про Yandex.Disk (если путь содержит `Yandex.Disk.localized`).
   - Отвечает одной строкой представления.

**Что проверить в ответе:**
- ✅ Агент представился по-русски как сисадмин.
- ✅ Знает имя оператора (Vasily — из конфига).
- ✅ Может назвать актуальный сервер из inventory.
- ❌ Если агент **не нашёл конфиг** — критичная ошибка, INSTALL.md / Cold Start не работают для других папок.

---

### Блок 4: Скиллы агента находят конфиг

**Цель:** проверить что 5 операционных скиллов корректно ищут `sysadmin-config.json` в `infra/`.

**Действия Claude:**

Из произвольной папки попроси агента:

> @sysadmin покажи список своих скиллов и для каждого скажи: какой режим работы с конфигом (STRICT / OPTIONAL) и где он сейчас ищет sysadmin-config.json.

**Ожидаемое:** агент должен правильно перечислить — для каждого скилла указать infra/ как первое место поиска.

**Дополнительно — практический smoke-test:**

> @sysadmin запусти Шаг 0 (pre-check) скилла /audit-security без выполнения самой проверки. Покажи переменные $CONFIG, $REPORT_LANGUAGE, $SERVER, $SECRETS_MANAGER.

Агент должен найти конфиг в `infra/` и заполнить переменные правильно.

---

### Блок 5: Mermaid-шаблоны корректны

**Цель:** убедиться что 4 шаблона валидны и пригодны к использованию.

```bash
cd "$HOME/Yandex.Disk.localized/Claude Code/sysadmin/.claude/skills/inventory-scan/templates/diagrams"

# 5.1 Все 4 шаблона существуют
ls *.mmd | wc -l
# Должно: 4

# 5.2 Каждый начинается с %% комментария-документации
for f in *.mmd; do
    head -1 "$f" | grep -q "^%% " && echo "OK: $f"
done

# 5.3 В каждом есть classDef для стилизации
for f in *.mmd; do
    grep -q "classDef" "$f" && echo "OK styles: $f"
done

# 5.4 (Опционально) Если mmdc установлен — проверить синтаксис
command -v mmdc >/dev/null && {
    for f in *.mmd; do
        mmdc -i "$f" -o /tmp/test-$f.svg 2>&1 | grep -q "Generating" && echo "OK syntax: $f"
    done
}
```

**Действия Claude в чистой сессии:**

> @sysadmin запусти /inventory-scan на моём сервере. После завершения покажи: какие диаграммы созданы, в какой папке, есть ли в них незаполненные плейсхолдеры `<...>`.

**Критерий:** диаграммы созданы в `infra/inventory/diagrams/`, плейсхолдеры заменены на реальные данные.

---

### Блок 6: Автопроверка обновлений

**Цель:** убедиться что механизм работает.

**Действия Claude:**

```bash
# 6.1 Создаём искусственно «старую» метку (15 дней назад)
echo "$(date -u -v-15d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '15 days ago' +%Y-%m-%dT%H:%M:%SZ)" > \
    "$HOME/Yandex.Disk.localized/Claude Code/sysadmin/.update-check"

# 6.2 Запускаем sysadmin в произвольной папке
# В чате: "@sysadmin привет"
```

**Ожидаемое:**
- Cold Start §5.5 видит что метка > 14 дней.
- Запускает фоновую проверку (Task subagent или background bash).
- Если обновлений нет — обновляет метку, оператор ничего не видит.
- Если есть (для теста — поставить тег `v1.0.1-test` локально и git push) — добавляет 💡 в следующее сообщение.

**Также:**

> @sysadmin обнови sysadmin

Должен пройти процедуру: `git fetch --tags` → показ changelog → Yellow Zone подтверждение → `git checkout vX.Y.Z`.

---

### Блок 7: INSTALL.md — sandbox-проверка

**Цель:** убедиться что INSTALL.md действительно работает для нового пользователя.

**Sandbox-симуляция (без удаления текущей установки):**

1. В чистой сессии Claude Code, **в произвольной новой пустой папке** (например, `mkdir /tmp/sysadmin-test && cd /tmp/sysadmin-test`).
2. Написать: `Установи агента sysadmin из репо https://github.com/vefmvai/sysadmin по инструкции в INSTALL.md, но используй /tmp/sysadmin-test/sysadmin и /tmp/sysadmin-test/infra как пути установки. И ~/.claude/agents/sysadmin.md.bak.test как путь bridge-файла (чтобы не сломать мою рабочую установку).`.
3. **Ожидаемое:** Claude корректно проходит все 9 шагов INSTALL.md:
   - Pre-check (git, jq, ОС)
   - Спросить пути → использовать заданные
   - Брифинг 6 пунктов → подтвердить
   - git clone --branch v1.0.0
   - Создание infra/ со скелетом
   - Создание bridge с правильным абсолютным путём
   - Запрос на запуск `/sysadmin-init`
4. После проверки — удалить песочницу: `rm -rf /tmp/sysadmin-test && rm ~/.claude/agents/sysadmin.md.bak.test`.

**Критерии:**
- ✅ Все шаги выполнены без ошибок.
- ✅ Bridge-файл содержит правильный путь `/tmp/sysadmin-test/sysadmin/.claude/agents/sysadmin.md`.
- ✅ `infra/` создана со скелетом папок (inventory, decisions, incidents, knowledge, runbooks).
- ✅ `/sysadmin-init` готов к запуску из новой папки.

---

## Дополнительно: проверка консистентности

**Документация:**

```bash
cd "$HOME/Yandex.Disk.localized/Claude Code/sysadmin"

# Везде должно быть 17 скиллов
grep -rn "17 скиллов\|17 готовых" . --include="*.md" | wc -l
# Должно: >= 5

# Нигде не должно быть упоминаний 11 или 13 скиллов
grep -rn "11 скиллов\|13 скиллов" . --include="*.md"
# Должно: ничего

# Нигде нет ссылок на старый путь конфига в sysadmin/
grep -rn "sysadmin/sysadmin-config.json" . --include="*.md" | grep -v ".planning/"
# Должно: только context-документы про прошлое, не активные пути
```

**Канон ADR:**

```bash
ls decisions/
# Должно: 0000-template.md, 0001-skill-canon.md, 0002-persona-canon.md,
#         0003-knowledge-architecture.md, 0004-evals-format.md, 0005-vpn-architecture.md
```

---

## Промпт для запуска проверки в чистой сессии

Скопируй это в новый чат Claude Code:

```
Проведи комплексную проверку sysadmin-агента после рефакторинга 2026-05-16.

Открой и следуй документу:
/Users/vasiliy/Yandex.Disk.localized/Claude Code/sysadmin/CHECK-PLAN.md

Пройди по 7 блокам + дополнительные проверки. По каждому блоку:
1. Выполни проверочные команды (Bash).
2. Зафиксируй результат: ✅ PASS / ❌ FAIL / ⚠️ WARN.
3. Если FAIL — покажи что именно не так и предложи фикс.

В конце дай сводный отчёт по всем блокам в формате:

Блок 1 (Состояние файлов): X/10 PASS
Блок 2 (Унификация поиска): X/5 PASS
...
Блок 7 (INSTALL.md): пройден / не пройден

Какие проблемы найдены: <список>
Какие фиксы предложены: <список>

Не запускай sandbox-тест из Блока 7 без явного «да» от оператора —
он создаёт временные папки в /tmp/.

Не запускай /inventory-scan в Блоке 5 без подтверждения — это
изменения на реальном сервере (Yellow Zone).

Не модифицируй .update-check в Блоке 6 без подтверждения —
это влияет на поведение Cold Start.

Остальные блоки (1, 2, 3, 4, доп) можно прогонять без подтверждения —
они read-only.
```

---

## Что НЕ проверяется этим планом

- **Тестирование на сервере (Yellow/Red Zone скиллов)** — каждый скилл (deploy, bootstrap, audit) тестируется отдельно при реальной задаче. План про инфраструктуру установки, не про функциональность серверных скиллов.
- **Eval-сценарии триггеров** — `scripts/run-evals.sh` для распознавания фраз. Это отдельный прогон через `claude -p` (см. ADR-0004), требует токенов подписки. Запускается перед каждым релизом, не в этом плане.
- **GitHub Release создание** — требует `gh auth login`. Release notes готовы в `.planning/RELEASE-NOTES-v1.0.0.md`, ручное создание в UI занимает 30 секунд.
- **Сами VPN-скиллы (setup-vpn-panel и т.д.)** — нужен тестовый VPS, выходит за рамки локальной проверки.

Эти проверки — отдельные сессии при необходимости.

---

*Документ создан: 2026-05-16. Если проверка показала проблемы — зафиксировать в `incidents/YYYY-MM-DD-checkplan-issues.md` и пофиксить отдельной сессией.*
