# Release Notes для v1.0.0

> **Этот файл — заготовка для GitHub Release.** `gh` CLI не аутентифицирован, поэтому релиз через API не создан. Скопируй содержимое ниже в UI GitHub:
>
> 1. Открой https://github.com/vefmvai/sysadmin/releases/new
> 2. Выбери тег `v1.0.0` (уже запушен)
> 3. Заголовок: `sysadmin v1.0.0 — первый публичный релиз`
> 4. В тело — скопируй блок ниже (между `---`)
> 5. Опционально: пометить как «Latest release»
> 6. Publish release
>
> После этого файл можно удалить из репо.

---

Первый публичный релиз агента-сисадмина для Claude Code.

## Установка

Открой Claude Code в любой папке и напиши:

> Установи агента sysadmin из репо `https://github.com/vefmvai/sysadmin` по инструкции в INSTALL.md.

Claude всё сделает сам за 5 минут. Подробнее — [README.md](https://github.com/vefmvai/sysadmin/blob/v1.0.0/README.md).

## Что внутри

**Агент с конституцией:**
- Трёхзонная политика безопасности (🟢 зелёная / 🟡 жёлтая / 🔴 красная)
- Защита от prompt-injection (urgency / authority / roleplay)
- Type-to-confirm для красной зоны
- Абсолютный запрет на выдумывание данных
- Ядро персоны 400 строк (hard cap ADR-0002) + 7 references-документов

**17 готовых скиллов:**

| Группа | Скиллы |
|---|---|
| Знакомство и настройка | `/sysadmin-meet`, `/sysadmin-init` |
| Настройка с нуля | `/bootstrap-new-server`, `/setup-secrets-vault`, `/setup-backups`, `/install-monitoring-stack` |
| Сеть и обход блокировок | `/setup-vpn-panel`, `/configure-vpn-routing`, `/setup-server-proxy`, `/generate-client-config` |
| Текущая работа | `/health-check`, `/inventory-scan`, `/deploy-service` |
| Безопасность | `/audit-security`, `/rotate-secrets` |
| Спецоперации | `/cleanup-existing-server`, `/migrate-server-to-server` |

Все скиллы агент выбирает сам по фразе оператора — не нужно запоминать команды.

**VPN-knowledge база** в `.claude/knowledge/networking/` — 2781 строка с источниками (vpn-research, singbox-clients, singbox-core, singbox-vs-xray).

**4 mermaid-шаблона диаграмм инфры** (topology, services-network, domains-routing, vpn-architecture) с правилом синхронности — при любом архитектурном изменении агент обновляет соответствующую диаграмму в `infra/inventory/diagrams/`.

**5 архитектурных ADR:** skill-canon, persona-canon, knowledge-architecture, evals-format, vpn-architecture.

## Архитектура «два репо»

- **Публичный `sysadmin/`** (этот) — мозг агента. Один и тот же у всех. Обновляется через `git pull` или команду «обнови sysadmin».
- **Приватный `infra/`** оператора — его данные (inventory серверов, ADR, knowledge, incidents, `sysadmin-config.json`). Создаётся при установке, не публикуется.

Связь — поле `infrastructure.root_path` в `sysadmin-config.json`.

## Автообновления

Раз в 14 дней агент сам проверит новые версии через `git fetch --tags` (в фоне, без задержки ответа). Если новая версия есть — добавит мягкую подсказку 💡 в следующее сообщение. Команда «обнови sysadmin» в любой момент — `git pull` + changelog + Yellow-Zone подтверждение.

## Системные требования

- macOS / Linux / Windows
- Claude Code
- `git`
- `jq`

## История работы

130+ коммитов от первичного релиза 2026-04-27 до текущего финального состояния 2026-05-16, включая полный рефакторинг по 4 каноническим ADR (skill / persona / knowledge / evals) и сессию VPN-блока с глубоким рисёрчем 4 параллельных тем.
