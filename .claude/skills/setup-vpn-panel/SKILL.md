---
name: setup-vpn-panel
description: |
  Установка эталонной панели управления VPN 3X-UI (MHSanaei/3x-ui) на VPS оператора.
  Полная атомарная операция: официальный install.sh с фиксацией версии,
  замена дефолтных кредов (smart-логин ≠ admin + 32-символьный пароль +
  нестандартный порт + случайный webBasePath), выпуск Let's Encrypt сертификата
  (3 метода: acme-standalone / acme-cloudflare / certbot), настройка UFW,
  запись секретов в менеджер паролей оператора, обновление inventory.
  Поддерживает два расположения сервера: ru-server (VLESS-TCP inbound) и
  foreign-server (VLESS+Reality inbound с валидацией serverName).
  Триггеры: «настрой VPN-панель», «поставь 3X-UI», «нужен свой VPN»,
  «хочу обойти блокировки на VPS», «setup 3x-ui», «свой VLESS на сервере».
  НЕ для маршрутизации/inbound/outbound на уже установленной панели —
  это `/configure-vpn-routing`. НЕ для серверного прокси —
  `/setup-server-proxy`. НЕ для клиентских конфигов — `/generate-client-config`.
  НЕ для форков 3X-UI — отказывает явно (см. ADR-0005).
allowed-tools: Bash, Read, Edit, Write
---

<role>
Я полностью настраиваю эталонную панель VPN 3X-UI на сервере оператора. Покрываю
всю атомарную операцию «от голого VPS до защищённой панели с HTTPS, на которую
оператор может зайти через браузер». Никакой VPN-конфигурации (inbound для
клиентов, outbound, маршрутизация) в этом скилле НЕТ — это работа
`/configure-vpn-routing`.
</role>

<context>
Предполагается:
- Свежий VPS или сервер, прошедший `/bootstrap-new-server` (есть UFW, SSH работает по ключу, без панели VPN).
- DNS: A-запись для DOMAIN указывает на IP сервера, распространение завершилось (`dig +short DOMAIN == server IP`).
- В `sysadmin-config.json` есть `secrets.manager` (keychain / pass / bw / op).
- Для `TLS_METHOD=acme-webroot` (дефолт): на сервере **установлен и запущен nginx** — этот метод не работает без работающего nginx.
- Для `TLS_METHOD=acme-standalone` (fallback): порт 80 свободен (acme сам займёт его на время выпуска).
- Целевая версия 3X-UI — эталонная `MHSanaei/3x-ui`, не форк.

НЕ предполагается:
- Существующая 3X-UI или другая VPN-панель (Marzban, X-UI, Hiddify) — это сценарий миграции, не покрывается.
- Доступ через панель провайдера для recovery — если сломается SSH, у оператора должен быть альтернативный путь.
- Готовые reality-параметры — скилл при `LOCATION=foreign-server` валидирует serverName сам.
</context>

<goals>
После выполнения должно стать TRUE:
- 3X-UI установлен и работает: `systemctl is-active x-ui` = active.
- Дефолтные креды заменены: логин ≠ admin (случайный 8 символов), пароль 32 символа.
- Порт панели — нестандартный из 1024-65535 (по умолчанию из 20000-60000).
- webBasePath — случайный 10-символьный (`/abc123xyz0/`).
- HTTPS работает: `curl -sI https://DOMAIN:PORT/WEB_BASE_PATH/` → 200 OK с валидным сертификатом.
- UFW настроен: PANEL_PORT/tcp открыт, 80 закрыт (если был временно открыт).
  При `LOCATION=foreign-server` — 443/tcp открыт для будущего VLESS+Reality inbound.
- Креды в менеджере паролей под именем `3xui-panel-${SERVER_ALIAS}` (URL, логин, пароль, notes).
- Inventory обновлён: блок про 3X-UI в `$INFRA/inventory/hosts/$SERVER/services.md`.
- В `sysadmin-config.json` обновлены поля `vpn.enabled=true`, `vpn.panel_url`, `vpn.panel_web_base_path`, `vpn.server_role` (= `$LOCATION`).
</goals>

# Параметры

| Параметр | Required | Default | Описание |
|---|---|---|---|
| `SSH_TARGET` | да | — | SSH-цель: alias из `~/.ssh/config` или `user@host` |
| `SERVER_ALIAS` | да | — | Короткое имя сервера для inventory и menager паролей (например, `vpn-de` или `prod`) |
| `DOMAIN` | да | — | Домен с действующей A-записью на IP сервера. Для HTTPS-сертификата. |
| `LOCATION` | нет | `ask` | `ru-server` / `foreign-server` / `ask`. Влияет на дальнейшую настройку (важно: только при `foreign-server` готовится 443/tcp под VLESS+Reality). |
| `VERSION` | нет | `v3.0.2` | Версия 3X-UI. Фиксированная для повторяемости. См. https://github.com/MHSanaei/3x-ui/releases |
| `PANEL_PORT` | нет | случайный из 20000-60000 | Порт панели (рекомендуется нестандартный) |
| `ADMIN_LOGIN` | нет | случайный 8 симв. | Логин администратора. **НЕ `admin`** — это первое, что брутят. |
| `WEB_BASE_PATH` | нет | случайный 10 симв. | webBasePath (`/abc123xyz0/`) — защита от сканеров |
| `TLS_METHOD` | нет | `acme-webroot` | `acme-webroot` (дефолт, требует nginx, не моргает) / `certbot-webroot` (то же на certbot) / `acme-standalone` (fallback для VPS-без-nginx, моргает) / `certbot-standalone` (то же на certbot) / `acme-cloudflare` (для РФ-операторов **не** рекомендуется — CF блокируется). См. `references/tls-method-choice.md`. |
| `ADMIN_EMAIL` | нет | `admin@${DOMAIN}` | Email для Let's Encrypt уведомлений |
| `WEBROOT_PATH` | нет | `/var/www/letsencrypt` | Только для `TLS_METHOD=acme-webroot`. Папка, куда nginx отдаёт ACME-челлендж. |
| `CLOUDFLARE_EMAIL`, `CLOUDFLARE_API_KEY` | условно | — | Только для `TLS_METHOD=acme-cloudflare`. Global API Key (полный доступ к аккаунту CF). Для РФ-операторов метод не рекомендуется — Cloudflare блокируется в РФ. |
| `REALITY_DEST` | нет | `www.cloudflare.com` | Только для `LOCATION=foreign-server`. Домен-донор для Reality serverName. См. `references/panel-hardening.md`. |

# Процедура

## Шаг 0a: Чтение конфига (STRICT)

Скилл — STRICT-режим: без `sysadmin-config.json` он не запускается. Конфиг
содержит `secrets.manager` (куда записать креды панели) и серверы — без них
скилл угадывал бы намерения. Эта проверка выполняется **до** запуска
`scripts/01-preflight.sh`, чтобы при отсутствии конфига оператор получил
понятную ошибку, а не падение на середине процедуры.

Используй общий helper `_lib/find-config.sh` (единая точка изменения для всех
STRICT/OPTIONAL скиллов — алгоритм идентичен Cold Start Protocol персоны).
`$SYSADMIN_ROOT` запоминается на Шаге 1 Cold Start.

```bash
source "$SYSADMIN_ROOT/.claude/skills/_lib/find-config.sh"

# STRICT: exit 1 если конфига нет
find_sysadmin_config strict

# secrets.manager обязателен — без него непонятно, куда сохранять креды панели
require_config_field "secrets.manager" \
    "Запусти /sysadmin-init --reconfigure и укажи менеджер паролей (keychain / pass / bw / op)."

# Чтение значений
SECRETS_MANAGER=$(get_config_field secrets.manager)
SERVER_ALIAS_FROM_CONFIG=$(get_config_field 'servers[0].alias')
REPORT_LANGUAGE=$(get_config_field language ru)
```

После успешного чтения переходим к Шагу 0 (Pre-check на сервере).

## Шаг 0: Pre-check (Green Zone)

Скрипт `scripts/01-preflight.sh` запускается **до брифинга** — это безопасная
проверка, не меняющая состояние сервера. Что проверяет:

- SSH-доступность.
- ОС поддерживается официальным install.sh.
- cloud-init завершился (если есть).
- 3X-UI ещё не установлен.
- Порт `PANEL_PORT` свободен.
- jq установлен на сервере (или будет поставлен).
- DNS: DOMAIN резолвится в IP сервера.
- **Для `TLS_METHOD` ∈ `acme-webroot` / `certbot-webroot`:** nginx установлен
  И запущен (`systemctl is-active nginx` = active), есть хотя бы один
  server-блок с `listen 80` для дефолта (или будет создан скиллом).
- **Для `TLS_METHOD` ∈ `acme-standalone` / `certbot-standalone`:** порт 80
  свободен (нет конкурирующего процесса на 80, кроме nginx, который скилл
  остановит на время выпуска).

**Если pre-check возвращает 1** (есть блокирующие проблемы) — STOP,
показываю оператору список проблем, не делаю ничего. Возможные причины
и решения:

- DNS не разрешается → попросить создать A-запись, подождать распространения (5-30 мин).
- 3X-UI уже стоит → предложить деинсталляцию через `/usr/local/x-ui/x-ui uninstall` или работать с существующей через `/configure-vpn-routing`.
- Порт 80 занят (при standalone-методах) → проверить `systemctl status nginx/apache2`, выбрать webroot-метод (если nginx есть) или остановить конкурента вручную.
- nginx отсутствует или не запущен (при webroot-методах) → предложить переключиться на standalone-метод (если nginx и не планируется) ИЛИ установить nginx сначала (если будут сайты — это **правильный** путь, см. рефлекс 3.8.8).

## Шаг 1: Сценарный диалог (если `LOCATION=ask`)

Применяю сеньор-обёртку (раздел 4.3 персоны):

1. **Контекст**: «У тебя сейчас один (или два) сервера? Один в РФ, другой за границей?»
2. **Мини-урок** (2-3 абзаца): «Если сервер в РФ — клиенты ходят на него внутри
   РФ, TSPU не работает на этом маршруте, маскировка не нужна, используем
   VLESS-TCP без Reality. Если сервер за границей — трафик клиент→сервер
   пересекает TSPU, маскировка обязательна, VLESS+Reality на 443.»
3. **Варианты**: ru-server / foreign-server.
4. **Рекомендация**: исходя из ответа оператора.
5. **Разрешение довериться**: «Могу выбрать сам, если не хочешь думать».
6. **Открытая дверь**: «Если интересно глубже про Reality — см. `vpn-protocols.md` §1.6».

При `LOCATION=foreign-server` дополнительно валидирую `REALITY_DEST` через
`scripts/06-validate-reality-dest.sh`. Если домен-кандидат не подходит
(нет TLS 1.3, redirect-only) — предлагаю из проверенного списка
(`www.cloudflare.com`, `dl.google.com`, `www.microsoft.com`, `www.amazon.com`,
`www.apple.com`).

### Шаг 1а (обязательная развязка): «панель» vs «VPN-инбаунды»

> 🔑 **Эту развязку проговариваю всегда — без неё оператор путает админку и
> клиентский трафик** (рефлекс персоны **3.8.8**, эталон
> `_reference/web-and-vpn-coexistence.md` §2.3).

Чётко формулирую оператору **до** установки:

> «Сразу важная развязка, иначе путаница неизбежна. Мы сейчас ставим
> **админку 3X-UI** — это веб-морда, куда заходишь **ты сам** через браузер,
> чтобы добавить клиента или поменять настройки. Она будет на отдельном
> секретном порту с длинным путём, и **за nginx её не прячут** — так
> советует автор 3X-UI, и так делает этот скилл.
>
> **VPN-двери для клиентов** (телефон, ноутбук, семья) — это **другая
> история**. В одной панели их можно делать сколько угодно, и каждая по
> своему правилу: тип XHTTP — за nginx (выглядит как сайт), тип Reality —
> напрямую на свой порт (например 8443), Hysteria — вообще по UDP мимо
> nginx. Этим займёмся **в следующем шаге** через `/configure-vpn-routing`,
> не сейчас.
>
> Запомни различие: **«куда ставить панель»** и **«куда ставить VPN-вход
> клиентов»** — это два **разных** вопроса, и ответы у них разные. Сейчас
> мы про первое».

NEVER пропускать эту развязку. NEVER отвечать на вопрос оператора «а
почему панель не за nginx?» без проговаривания второй половины (про
инбаунды), иначе оператор унесёт ложное обобщение «3X-UI вообще не работает
за nginx» — это **неправда**, и она ломает следующий этап настройки
клиентских инбаундов.

## Шаг 2: Брифинг 6 пунктов (Yellow Zone)

Полный брифинг оператору:

1. **ЧТО ДЕЛАЮ**: устанавливаю эталонную 3X-UI ($VERSION) на $SSH_TARGET,
   выпускаю TLS-сертификат для $DOMAIN через $TLS_METHOD, открываю
   $PANEL_PORT в UFW (+ 443 при foreign-server), записываю креды в $MANAGER.
2. **ЗАЧЕМ**: получить защищённую панель управления VPN, к которой можно
   зайти через браузер. Без VLESS-конфигурации — это следующий скилл
   `/configure-vpn-routing`.
3. **ЧТО ПРОИЗОЙДЁТ**: ~5 минут установки + ~2 минуты выпуска cert. На
   время выпуска (при acme-standalone) — на 30-60 секунд недоступен порт 80
   (если что-то его использовало).
4. **ЧТО ПРОВЕРИЛ**: pre-check прошёл, ОС поддерживается, порты свободны,
   DNS резолвится корректно.
5. **РИСК + ПЛАН ОТКАТА**: при ошибке выпуска cert — откат к бэкапу SQLite-БД.
   При ошибке установки в целом — `ssh $SSH_TARGET '/usr/local/x-ui/x-ui
   uninstall'` (полное удаление панели, не трогает остальной сервер).
6. **СТРАХОВКА + ПРОВЕРКА**: после установки — smoke check `curl -sI
   https://$DOMAIN:$PANEL_PORT/$WEB_BASE_PATH/` → 200 OK.

После брифинга жду «ок» / «давай». Тишина = нет.

## Шаг 3: Установка панели

Скрипт `scripts/02-install-3x-ui.sh`:

1. Запускает официальный `install.sh` с фиксацией `VERSION`.
2. Отвечает 'n' на интерактивный вопрос про port settings.
3. Сразу после установки через `x-ui setting` меняет: `-username
   $ADMIN_LOGIN`, `-password $ADMIN_PASSWORD`, `-port $PANEL_PORT`,
   `-webBasePath /$WEB_BASE_PATH/`.
4. Рестартует `x-ui` для применения изменений.
5. Проверяет, что `systemctl is-active x-ui` = active.

**Verify:** `ssh $SSH_TARGET '/usr/local/x-ui/x-ui setting -show true'` —
показывает новые значения port, username, webBasePath.

## Шаг 4: Выпуск TLS-сертификата

Скрипт `scripts/03-configure-tls.sh` — выбор пути по `TLS_METHOD`. Полное
обоснование выбора метода — `references/tls-method-choice.md`.

- **acme-webroot** (default) — через `/root/.acme.sh/acme.sh` с `-w
  $WEBROOT_PATH` (HTTP-01 через работающий nginx). Шаги:
  1. Создаёт `$WEBROOT_PATH` (`/var/www/letsencrypt/` по умолчанию).
  2. Добавляет в дефолтный server-блок nginx `location ^~
     /.well-known/acme-challenge/ { root /var/www/letsencrypt; }` и
     перезагружает nginx (`nginx -t && systemctl reload nginx`).
  3. `acme.sh --issue -d $DOMAIN -w $WEBROOT_PATH --reloadcmd
     "systemctl restart x-ui"` — выпуск без остановки nginx.
  4. acme.sh кладёт cert в `/root/cert/$DOMAIN/` (унифицированный путь).
  5. Renew автоматический через `acme.sh.cron`, тоже без касания nginx.
  Метод не трогает порт 80 в UFW — он **остаётся открыт** (нужен для
  ACME-челленджа и редиректа `http://` → `https://`).

- **certbot-webroot** — то же, но через certbot вместо acme.sh. Шаги:
  1. Устанавливает certbot (`apt install certbot`).
  2. Создаёт `$WEBROOT_PATH` и добавляет тот же `location`-блок в nginx.
  3. `certbot certonly --webroot -w $WEBROOT_PATH -d $DOMAIN
     --non-interactive --agree-tos -m $ADMIN_EMAIL --deploy-hook
     "systemctl restart x-ui"`.
  4. Симлинк `/root/cert/$DOMAIN/fullchain.pem` →
     `/etc/letsencrypt/live/$DOMAIN/fullchain.pem` (и аналогично для
     `privkey.pem`) — для унификации пути с другими методами.
  5. Renew через `certbot.timer`, без касания nginx.
  Метод так же не трогает порт 80 в UFW.

- **acme-standalone** (fallback) — через `acme.sh --standalone`. Открывает
  80, останавливает nginx/apache (если есть), выпускает cert,
  восстанавливает сервисы, кладёт cert в `/root/cert/$DOMAIN/`. **Моргает
  nginx целиком при выпуске и каждом renew.** Брать только для VPS,
  где nginx нет и не будет.

- **certbot-standalone** — то же на certbot. `certbot certonly --standalone
  -d $DOMAIN`, копирует cert в `/root/cert/$DOMAIN/`. Те же ограничения.

- **acme-cloudflare** — DNS-01 через CF_Email + CF_Key (Global API Key).
  Не трогает порт 80. **Для РФ-операторов и доменов с российской аудиторией
  не рекомендуется** (Cloudflare блокируется в РФ). Брать только в узких
  случаях, когда домен уже на Cloudflare и аудитория нерусская — см. рефлекс
  персоны 3.8.9.

После выпуска — привязка к панели через **прямую правку SQLite** (нет CLI
для `webCertFile`):

```bash
# Бэкап БД обязателен!
cp /etc/x-ui/x-ui.db /etc/x-ui/x-ui.db.backup.$(date +%s)
systemctl stop x-ui
sqlite3 /etc/x-ui/x-ui.db "INSERT INTO settings (key, value) VALUES
    ('webCertFile', '/root/cert/$DOMAIN/fullchain.pem'),
    ('webKeyFile', '/root/cert/$DOMAIN/privkey.pem'),
    ('webDomain', '$DOMAIN')
ON CONFLICT(key) DO UPDATE SET value = excluded.value;"
systemctl start x-ui
```

**Verify:** `curl -sI https://$DOMAIN:$PANEL_PORT/$WEB_BASE_PATH/` →
HTTP/2 200, валидный TLS-сертификат.

## Шаг 5: UFW (Yellow Zone)

Скрипт `scripts/04-ufw-setup.sh`:

- Открывает `$PANEL_PORT/tcp`.
- При `LOCATION=foreign-server` — открывает 443/tcp (для VLESS+Reality inbound,
  который будет создан `/configure-vpn-routing`).
- **Порт 80 — условная логика:**
  - При `TLS_METHOD` ∈ `acme-webroot` / `certbot-webroot` → **80 остаётся
    открыт** (нужен для ACME-челленджа при renew и для редиректа `http://`
    → `https://` на nginx-сайтах).
  - При `TLS_METHOD` ∈ `acme-standalone` / `certbot-standalone` → 80
    **закрывается** только если на сервере **нет** запущенного nginx с
    сайтами (определяется по `systemctl is-active nginx` И отсутствию
    server-блоков с `listen 80` под чужие домены в `sites-enabled`). Иначе
    оставляем открытым.
  - При `TLS_METHOD=acme-cloudflare` → 80 трогать не нужно, оставляем
    статус-кво (если был открыт под существующие сайты — оставляем).

> 🔒 **NEVER молча закрывать 80**, если на сервере уже есть nginx с сайтами
> — это сломает их автопродление сертификатов и редирект `http://` → `https://`.
> Эталон: `_reference/web-and-vpn-coexistence.md` §2.4.

**Verify:** `ssh $SSH_TARGET 'ufw status verbose'` — открыты только нужные порты.

## Шаг 6: Запись секретов в менеджер паролей

Скрипт `scripts/05-record-secrets.sh` использует `api_store_secret()` из
`scripts/lib-api/3xui.sh`. Параметры берутся из `sysadmin-config.json`
(поле `secrets.manager`).

Запись имеет вид:

```
Service: 3xui-panel-$SERVER_ALIAS
Account: $ADMIN_LOGIN
Password: <32 символа>
URL: https://$DOMAIN:$PANEL_PORT/$WEB_BASE_PATH/
Notes: 3X-UI panel admin credentials, server=$SERVER_ALIAS
```

**Verify:** оператор может достать запись через CLI менеджера
(`security find-generic-password -s "3xui-panel-$SERVER_ALIAS" -w` для
macOS, аналогично для других).

## Шаг 7: Обновление inventory и конфига

Inventory:

```markdown
# inventory/hosts/$SERVER_ALIAS/services.md (раздел добавляется)

## VPN-панель 3X-UI

- **URL**: https://$DOMAIN:$PANEL_PORT/$WEB_BASE_PATH/
- **Версия**: $VERSION
- **Логин**: см. менеджер паролей, запись `3xui-panel-$SERVER_ALIAS`
- **Расположение**: $LOCATION (ru-server / foreign-server)
- **TLS**: Let's Encrypt через $TLS_METHOD, путь `/root/cert/$DOMAIN/`
- **Установлено**: YYYY-MM-DD
- **Inbound/outbound**: не настроены (см. `/configure-vpn-routing`)
```

`sysadmin-config.json` обновляется:

```jsonc
"vpn": {
  "enabled": true,
  "panel_url": "https://${DOMAIN}:${PANEL_PORT}",
  "panel_web_base_path": "/${WEB_BASE_PATH}/",
  "server_role": "${LOCATION}",          // ru-server | foreign-server
  "server_proxy_enabled": false,
  "upstream_kind": "none",
  "default_reality_dest": "${REALITY_DEST}"
}
```

> 🔒 **`server_role` — источник правды для выбора протокола.** Записывается
> здесь по выбранному `$LOCATION` (Шаг 1). `/configure-vpn-routing` читает это
> поле и автоматически выводит протокол inbound: `ru-server → vless-tcp` (без
> Reality), `foreign-server → vless-reality`. На нём же стоит guard в
> `create-vless-inbound.sh` — Reality на `ru-server` блокируется на уровне кода.

## Шаг 8: Финальный отчёт

```
✓ 3X-UI v$VERSION установлен на $SSH_TARGET
✓ Админка панели: https://$DOMAIN:$PANEL_PORT/$WEB_BASE_PATH/
✓ Логин/пароль: в $MANAGER (запись `3xui-panel-$SERVER_ALIAS`)
✓ HTTPS: валидный сертификат от Let's Encrypt (метод: $TLS_METHOD)
✓ UFW: open $PANEL_PORT (+ 443 для foreign-server), порт 80 — $PORT_80_STATUS
✓ Inventory обновлён: $INFRA/inventory/hosts/$SERVER_ALIAS/services.md
✓ Config обновлён: vpn.enabled=true, vpn.panel_url, vpn.panel_web_base_path

🔍 Smoke check: открой URL в браузере, должна быть страница логина
   (если 404 — проверь webBasePath; если timeout — проверь UFW).

ℹ️  Что мы поставили: только АДМИНКУ (веб-морду для тебя). Это НЕ VPN-сервер
   целиком. VPN-двери для клиентов (инбаунды) — это следующий шаг через
   `/configure-vpn-routing`. Там же решим, какие двери прячем за nginx
   (XHTTP), а какие выставляем напрямую (Reality на отдельный порт) — это
   ДРУГИЕ вопросы, не путать с тем, куда поставили админку.

✅ На этом установка панели ЗАВЕРШЕНА. Панель пустая: ни клиентов, ни
   outbound, ни маршрутизации — это нормально, это была отдельная операция.

➡️  Следующий шаг — ОТДЕЛЬНАЯ операция, запускается ПО ТВОЕМУ ЗАПРОСУ, не
    автоматически: `/configure-vpn-routing` (inbound для клиентов, outbound
    через подписку/свой загр.VPS, маршрутизация, добавление клиентов). Скажи
    когда будешь готов — и мы её начнём. Сам вперёд не забегаю.
```

> `$PORT_80_STATUS` принимает значения:
> - `open (для ACME renew + редирект http→https)` — при `*-webroot` методах
>   или если на сервере есть сайты на nginx.
> - `closed` — только при `*-standalone` методах И отсутствии сайтов.

> ⚠️ **Граница этапа (рефлекс персоны 3.8.4).** После этого отчёта агент
> **останавливается** и ждёт. Не предлагает «давай сразу настроим первый
> профиль», не создаёт inbound/outbound по своей инициативе. Установка
> панели и настройка маршрутизации — две разные операции; смешивать их в
> одном проходе нельзя — это путает оператора (он перестаёт понимать, какой
> шаг завершён). Переход к `/configure-vpn-routing` — только по явному
> запросу оператора.

# Откат

Если что-то пошло не так на любом шаге:

```bash
# Полный uninstall — официальный путь
ssh $SSH_TARGET '/usr/local/x-ui/x-ui uninstall'

# Закрытие портов в UFW
ssh $SSH_TARGET "ufw delete allow $PANEL_PORT/tcp; ufw delete allow 443/tcp; ufw reload"

# Удаление сертификата
ssh $SSH_TARGET "rm -rf /root/cert/$DOMAIN; /root/.acme.sh/acme.sh --revoke -d $DOMAIN"

# Удаление записи из менеджера паролей
# (manual — оператор удаляет через CLI/UI своего менеджера)
```

# Failed attempts (граблекейс)

- **«admin/admin» как креды по умолчанию (Docker-вариант)** — первое, что брутят.
  Скилл всегда меняет на сгенерированные. NEVER оставлять `admin`.
- **Сертификат на IP вместо домена** — 6-дневный shortlived от Let's Encrypt,
  требует renew каждые 4 дня. Скилл не поддерживает — слишком хрупко для
  типового домашнего сценария.
- **Установка без `n` ответа на интерактив установщика** — установщик зависает
  и таймаутит. Решение: `echo "n" | bash install.sh` (см. `02-install-3x-ui.sh`).
- **TLS-выпуск через standalone когда занят 80** — acme падает, скилл откатывается.
  Pre-check ловит это в Шаге 0.
- **CLI `x-ui setting -webCertFile`** — такого флага НЕТ. Только через прямой
  SQLite UPDATE. Документировано в `tls-method-choice.md` и `03-configure-tls.sh`.
- **Форк 3X-UI** — установщик ставит эталонную mhsanaei всегда (это
  github.com/mhsanaei/3x-ui/install.sh), форки оператор ставит вручную мимо
  этого скилла. Если оператор уже поставил форк до запуска — pre-check
  обнаружит `/usr/local/x-ui` и STOP с предложением `/usr/local/x-ui/x-ui uninstall`.

# Граничные случаи

- **Свежий VPS без `/bootstrap-new-server`** → большинство шагов работают,
  но без UFW (нужен) и без fail2ban (отдельная защита). Скилл предупреждает
  и предлагает сначала `/bootstrap-new-server`.
- **Сервер за NAT** → DNS на внешний IP, не на внутренний. Pre-check сравнит
  внешний IP сервера (через `curl ifconfig.me`) с DNS A-записью.
- **Несколько доменов на один IP** → не проблема, 3X-UI слушает только указанный
  `$DOMAIN`. Параллельный nginx с другими сайтами — допустим, см. acme-cloudflare
  чтобы не трогать порт 80.
- **Cloudflare proxy ENABLED на A-записи** → cert через standalone не выпустится
  (Cloudflare маскирует IP). Решение: отключить «proxy» (серое облако) на время
  выпуска, или сразу `TLS_METHOD=acme-cloudflare`.
- **Истёкший Let's Encrypt rate limit на домен** → 5 повторов в неделю для
  identicалa. Скилл показывает ошибку с предложением подождать или сменить
  identicалу.

# Связанные документы

- `references/tls-method-choice.md` — обоснование 3 методов TLS.
- `references/panel-hardening.md` — чек-лист безопасности панели.
- `../../knowledge/networking/_reference/3x-ui-panel.md` — архитектура 3X-UI и подводные камни.
- `../../knowledge/networking/_reference/3x-ui-api.md` — REST API (для последующих скиллов).
- `../../knowledge/networking/_reference/vpn-protocols.md` — выбор протоколов inbound/outbound.
- `decisions/0005-vpn-architecture.md` — архитектурное решение.
- `evals/triggers.md` — фразы оператора для распознавания скилла.
