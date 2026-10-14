# Образцы записей и финального отчёта

Справка к скиллу `/setup-vpn-panel`. Открывать на **Шаге 7** (что именно писать в inventory
и в `infra-config.json`) и на **Шаге 8** (как выглядит финальный отчёт целиком).

Это образцы формы. Значения подставляются фактические — переписывать отсюда версии, порты
и домены нельзя (C.2).

---

# Шаг 7. Записи в inventory и конфиг

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

`infra-config.json` обновляется:

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
> поле и автоматически выводит протокол inbound: `ru-server → vless-tls` (без
> Reality, ADR-0045), `foreign-server → vless-reality`. На нём же стоит guard в
> `create-vless-inbound.sh` — Reality на `ru-server` блокируется на уровне кода.

---

# Шаг 8. Финальный отчёт

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

