# Шаблоны mermaid-диаграмм инфраструктуры

Эти 5 шаблонов лежат в публичном репо `sysadmin/` и копируются в `infra/inventory/diagrams/` оператора при первом запуске `/inventory-scan`. Дальше скилл заполняет их реальными данными из inventory.

## Состав

| Файл | Что показывает | Источник данных |
|---|---|---|
| `topology.mmd` | Высокоуровневая карта: VPS → группы сервисов → связи с внешним миром | `server.md`, `services.md`, `domains.md` |
| `services-network.mmd` | Docker-сети, какие контейнеры в каких сетях, порты | `networks.md`, `services.md` |
| `domains-routing.mmd` | Маршрутизация HTTPS: домен → nginx vhost → upstream-контейнер | `domains.md`, nginx-конфиги из snapshot |
| `vpn-architecture.mmd` | VPN-инфра: 3X-UI inbound/outbound/routing, server-proxy, клиенты | `sysadmin-config.json` секция vpn, `services.md`, `networks.md` |
| `automations.mmd` | Что работает само: триггеры (cron/timer/watcher/manual) → автоматизации → что трогают (БД/сервисы/внешние API) | `automations.md` (колонка `touches`), `cron.md`, `host-scripts.md`, `systemd-timers.txt`, `watchers.txt` |

## Когда какая диаграмма генерируется

- `topology.mmd`, `services-network.mmd`, `domains-routing.mmd` — **всегда**, если в `inventory/hosts/` есть хотя бы один сервер.
- `vpn-architecture.mmd` — **только если** `vpn.enabled: true` в `sysadmin-config.json`. Иначе пропускается.
- `automations.mmd` — **только если** на сервере есть хоть одна автоматизация (непустой `automations.md`). Иначе пропускается / удаляется (как `vpn-architecture.mmd`). Группа `automations` в `topology.mmd` появляется по тому же условию.

## Правила оформления (для будущих диаграмм)

1. **Каждый файл — рабочий mermaid**, открывается в любом mermaid-вьюере (VS Code с расширением, github.com через preview, mermaid.live).
2. **В начале файла — комментарий-документация** (строки начинающиеся с `%%`): что показывает, какие источники данных, какие условные обозначения.
3. **Стилизация через `classDef`** — цвет несёт смысл (зелёный = app, жёлтый = БД, синий = monitoring, розовый = VPN, фиолетовый `fill:#ede9fe,stroke:#7c3aed` = automation, серый = infrastructure / триггеры).
4. **Плейсхолдеры `<...>`** в шаблоне — заполняются скиллом из inventory. После заполнения плейсхолдеров быть не должно.
5. **Размер диаграммы** — должна читаться без скролла на экране 1920×1080. Если становится перегруженной — выделять подграфы в отдельный файл.

## Правило поддержания актуальности

См. `agents/sysadmin.md` §3.2 (Character — «Inventory ↔ реальность»):

> При архитектурных изменениях (новая сеть, новый сервис, новый домен, новая интеграция) — обновить соответствующую диаграмму в `infra/inventory/diagrams/`. Без этого задача **не считается завершённой**.

Если оператор сомневается «нужно ли обновлять диаграмму» — правило: затронуты ли **связи** между сущностями. Изменил версию контейнера — диаграмма не меняется. Поменял upstream nginx-vhost — меняется (`domains-routing.mmd`).
