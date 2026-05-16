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
- Порт 80 свободен (нужен для acme HTTP-01 challenge при `TLS_METHOD=acme-standalone`).
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
- В `sysadmin-config.json` обновлены поля `vpn.enabled=true`, `vpn.panel_url`, `vpn.panel_web_base_path`.
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
| `TLS_METHOD` | нет | `acme-standalone` | `acme-standalone` / `acme-cloudflare` / `certbot`. См. `references/tls-method-choice.md`. |
| `ADMIN_EMAIL` | нет | `admin@${DOMAIN}` | Email для Let's Encrypt уведомлений |
| `CLOUDFLARE_EMAIL`, `CLOUDFLARE_API_KEY` | условно | — | Только для `TLS_METHOD=acme-cloudflare` |
| `REALITY_DEST` | нет | `www.cloudflare.com` | Только для `LOCATION=foreign-server`. Домен-донор для Reality serverName. См. `references/panel-hardening.md`. |

# Процедура

## Шаг 0: Pre-check (Green Zone)

Скрипт `scripts/01-preflight.sh` запускается **до брифинга** — это безопасная
проверка, не меняющая состояние сервера. Что проверяет:

- SSH-доступность.
- ОС поддерживается официальным install.sh.
- cloud-init завершился (если есть).
- 3X-UI ещё не установлен.
- Порты 80, 443, PANEL_PORT свободны.
- jq установлен на сервере (или будет поставлен).
- DNS: DOMAIN резолвится в IP сервера.

**Если pre-check возвращает 1** (есть блокирующие проблемы) — STOP,
показываю оператору список проблем, не делаю ничего. Возможные причины
и решения:

- DNS не разрешается → попросить создать A-запись, подождать распространения (5-30 мин).
- 3X-UI уже стоит → предложить деинсталляцию через `/usr/local/x-ui/x-ui uninstall` или работать с существующей через `/configure-vpn-routing`.
- Порт 80 занят → проверить `systemctl status nginx/apache2`, остановить или выбрать `TLS_METHOD=acme-cloudflare`.

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

Скрипт `scripts/03-configure-tls.sh` — выбор пути по `TLS_METHOD`:

- **acme-standalone** (default) — через встроенный `/root/.acme.sh/acme.sh`
  с `--standalone` (HTTP-01). Открывает 80, останавливает nginx/apache,
  выпускает cert в `/root/cert/$DOMAIN/`, устанавливает hook
  `--reloadcmd "systemctl restart x-ui"`.
- **acme-cloudflare** — DNS-01 через CF_Email + CF_Key (Global API Key).
  Не трогает порт 80.
- **certbot** — `certbot certonly --standalone -d $DOMAIN`, копирует cert
  в `/root/cert/$DOMAIN/` (унифицированный путь).

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
- Закрывает 80 (если был открыт под acme).

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
  "server_proxy_enabled": false,
  "upstream_kind": "none",
  "default_reality_dest": "${REALITY_DEST}"
}
```

## Шаг 8: Финальный отчёт

```
✓ 3X-UI v$VERSION установлен на $SSH_TARGET
✓ Панель: https://$DOMAIN:$PANEL_PORT/$WEB_BASE_PATH/
✓ Логин/пароль: в $MANAGER (запись `3xui-panel-$SERVER_ALIAS`)
✓ HTTPS: валидный сертификат от Let's Encrypt
✓ UFW: open $PANEL_PORT (+ 443 для foreign-server), 80 closed
✓ Inventory обновлён: $INFRA/inventory/hosts/$SERVER_ALIAS/services.md
✓ Config обновлён: vpn.enabled=true, vpn.panel_url, vpn.panel_web_base_path

🔍 Smoke check: открой URL в браузере, должна быть страница логина
   (если 404 — проверь webBasePath; если timeout — проверь UFW).

➡️  Следующий шаг: `/configure-vpn-routing` для собственно настройки VPN
    (inbound для клиентов, outbound через подписку/свой загр.VPS,
    маршрутизация, добавление клиентов).
```

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
- `../../knowledge/networking/3x-ui-panel.md` — архитектура 3X-UI и подводные камни.
- `../../knowledge/networking/3x-ui-api.md` — REST API (для последующих скиллов).
- `../../knowledge/networking/vpn-protocols.md` — выбор протоколов inbound/outbound.
- `decisions/0005-vpn-architecture.md` — архитектурное решение.
- `evals/triggers.md` — фразы оператора для распознавания скилла.
