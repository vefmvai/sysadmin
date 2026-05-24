---
name: generate-client-config
description: |
  Генерация клиентских VPN-конфигов для устройств оператора из существующих
  клиентов в его панели 3X-UI: vless://-URI, sing-box JSON под платформу
  (iOS / Android / desktop / universal), QR-код через qrencode. Использует
  REST API панели для чтения inbound и client UUID. Стратегия совместимости:
  нижняя планка sing-box 1.11.x (из-за застрявшего sing-box-vt на iOS),
  с учётом ограничений каждой платформы (iOS не имеет process_name/
  strict_route, Android умеет package_name, desktop — всё).
  Триггеры: «сделай VPN-конфиг для iPhone», «сгенерируй vless-ссылку», «QR-код
  для клиента», «sing-box JSON под Android», «выпусти конфиг для семьи».
  НЕ для установки панели — `/setup-vpn-panel`. НЕ для создания клиентов
  в панели — `/configure-vpn-routing`. НЕ для серверного прокси —
  `/setup-server-proxy`.
allowed-tools: Bash, Read, Write
---

<role>
Я генерирую клиентские артефакты — VPN-конфиги, QR-коды, sing-box JSON —
для устройств оператора и его близких. Читаю данные клиентов из его панели
3X-UI через REST API, формирую совместимые с iOS/Android/desktop конфиги
с учётом ограничений каждой платформы. Никаких изменений на сервере: только
чтение и генерация локальных файлов.
</role>

<context>
Предполагается:
- 3X-UI установлен и работает (`/setup-vpn-panel`).
- В панели есть inbound с клиентами (`/configure-vpn-routing` создал
  и inbound, и UUID).
- Креды панели в менеджере паролей (`3xui-panel-${SERVER_ALIAS}`).
- `qrencode` установлен локально (macOS: `brew install qrencode`;
  Linux: `apt install qrencode`).
- `parse-vless-link.sh` из соседнего скилла `/configure-vpn-routing`
  доступен (общая зависимость двух скиллов).

НЕ предполагается:
- SSH-доступ к устройствам оператора. Скилл генерирует файлы локально,
  оператор сам переносит их на устройства (через AirDrop, Telegram-saved
  messages, email, ssh-copy и т.д.).
- Изменения в панели. Это read-only скилл.
</context>

<goals>
После выполнения должно стать TRUE:
- Сгенерирован один или несколько артефактов:
  - vless://-URI (текст в stdout или в файл).
  - sing-box JSON для указанной платформы.
  - QR-код PNG (через qrencode).
- Артефакты сохранены в `${OUTPUT_DIR}` (default: `./vpn-clients/${CLIENT_NAME}/`).
- Файлы названы прозрачно: `vless.txt`, `singbox-{platform}.json`, `qr.png`.
- Если оператор хочет — итерируется по нескольким клиентам и генерирует пачкой.
</goals>

# Параметры

| Параметр | Required | Default | Описание |
|---|---|---|---|
| `SERVER_ALIAS` | да | — | Имя сервера для menager паролей |
| `PANEL_DOMAIN`, `PANEL_PORT`, `WEB_BASE_PATH` | да | из `vpn.*` в config | Параметры панели |
| `ADMIN_LOGIN`, `PASSWORD_REF` | да | автодетект | Креды панели |
| `INBOUND_ID` | да | — | ID inbound, из которого брать клиента |
| `CLIENT_NAME` | да | — | Email-метка клиента (или UUID) |
| `PLATFORM` | нет | `universal` | `ios` / `android` / `desktop` / `universal` |
| `OUTPUT_DIR` | нет | `./vpn-clients/${CLIENT_NAME}/` | Куда сохранить артефакты |
| `OUTPUT_FORMATS` | нет | `vless,singbox,qr` | Какие артефакты генерировать (CSV) |
| `USE_RULE_SET` | нет | `yes` | Добавить ли rule_set (geosite-ru → direct) в sing-box JSON |
| `PUBLIC_ADDRESS` | нет | `${PANEL_DOMAIN}` | Адрес VLESS-сервера для клиента (если отличается от домена панели) |

# Процедура

## Шаг 0a: Чтение конфига (STRICT)

Скилл — STRICT-режим: без `sysadmin-config.json` он не запускается. Нужны
`vpn.panel_url` и `vpn.panel_web_base_path`, чтобы знать, к какой панели
обращаться за данными клиента, и `secrets.manager` для доступа к кредам.
Эта проверка выполняется **до** Шага 0 (Pre-check qrencode/панели).

Используй общий helper `_lib/find-config.sh` (единая точка изменения для всех
STRICT/OPTIONAL скиллов — алгоритм идентичен Cold Start Protocol персоны).
`$SYSADMIN_ROOT` запоминается на Шаге 1 Cold Start.

```bash
source "$SYSADMIN_ROOT/.claude/skills/_lib/find-config.sh"

# STRICT: exit 1 если конфига нет
find_sysadmin_config strict

# vpn.panel_url + vpn.panel_web_base_path обязательны
require_config_field "vpn.panel_url" \
    "Это значит 3X-UI ещё не установлен. Сначала /setup-vpn-panel → /configure-vpn-routing (создаст клиентов), потом сюда."
require_config_field "vpn.panel_web_base_path" \
    "Это значит 3X-UI ещё не установлен. Сначала /setup-vpn-panel → /configure-vpn-routing, потом сюда."

# Параметры (CLI override > конфиг)
PANEL_URL=$(get_config_field vpn.panel_url)
PANEL_WEB_BASE_PATH=$(get_config_field vpn.panel_web_base_path)
PANEL_DOMAIN="${PANEL_DOMAIN:-$(echo "$PANEL_URL" | sed -E 's|https?://||; s|:.*$||')}"
PANEL_PORT="${PANEL_PORT:-$(echo "$PANEL_URL" | sed -E 's|https?://[^:]+:||; s|/.*$||')}"
WEB_BASE_PATH="${WEB_BASE_PATH:-$PANEL_WEB_BASE_PATH}"
SECRETS_MANAGER=$(get_config_field secrets.manager keychain)
REPORT_LANGUAGE=$(get_config_field language ru)
```

После успешного чтения переходим к Шагу 0 (локальные зависимости и панель).

## Шаг 0: Pre-check (Green Zone)

- Локально установлен `qrencode` (если в `OUTPUT_FORMATS` есть `qr`).
- Панель отвечает (login проходит).
- `INBOUND_ID` существует и содержит клиента с указанным `CLIENT_NAME`.

Если проверка не прошла — STOP с конкретной причиной.

## Шаг 1: Получение данных клиента

`scripts/generate-vless-link.sh` через API:
1. Login.
2. `GET /panel/api/inbounds/get/${INBOUND_ID}` — читаем inbound.
3. Парсим settings.clients[], находим клиента по email/UUID.
4. Извлекаем UUID, flow, port, security (reality/tls/none), sni, fp, pbk,
   sid, spx (Reality) или другие параметры transport (ws/grpc).
5. Собираем vless://-URI с URL-encoding для tag и query-значений.

Выход — одна строка `vless://...`.

## Шаг 2: Генерация sing-box JSON

`scripts/generate-singbox-json.sh`:
1. Парсит сгенерированный vless://-link через `parse-vless-link.sh`
   из `/configure-vpn-routing` (общая зависимость).
2. По `PLATFORM` выбирает inbound:
   - `ios`/`android`: TUN с `inet4_address`+`inet6_address` (старый формат, для
     совместимости с sing-box 1.9-1.11).
   - `desktop`: TUN с `address` (1.10+) + `auto_redirect` + `strict_route`.
   - `universal`: mixed inbound на 127.0.0.1:2080 (Hiddify-app сам обернёт в TUN).
3. Outbound VLESS с Reality/TLS-блоком из vless-link.
4. Routing (если `USE_RULE_SET=yes`): `geoip-ru` + `geosite-category-ru`
   из `SagerNet/sing-geoip` + `SagerNet/sing-geosite` → direct, остальное → vless.
5. Pretty-printed через `jq`.

Файлы:
- `${OUTPUT_DIR}/singbox-${PLATFORM}.json`

## Шаг 3: QR-код

`scripts/generate-qr.sh`:
- Принимает vless://-URI на stdin или как аргумент.
- `qrencode -o ${OUTPUT_DIR}/qr.png -s 8 -m 2`.
- Опция `ASCII=1` — печать в терминал (для просмотра на хосте без графического интерфейса).

## Шаг 4: Сохранение vless как текст

Просто `echo "$VLESS_URI" > ${OUTPUT_DIR}/vless.txt`. Полезно для копирования
вручную или импорта в клиенты, которые не сканируют QR.

## Шаг 5: Финальный отчёт

```
✓ Сгенерированы артефакты для клиента $CLIENT_NAME (UUID=$UUID, платформа=$PLATFORM):
  - $OUTPUT_DIR/vless.txt
  - $OUTPUT_DIR/singbox-$PLATFORM.json
  - $OUTPUT_DIR/qr.png

📱 Как использовать (основной клиент — Happ; sing-box JSON — для sing-box-клиентов):
  iPhone:   Happ (основной) → импорт vless.txt / подписки / QR. Альтернативы —
            Hiddify/Karing (для них же подходит singbox-$PLATFORM.json).
  Android:  Happ (основной) / Hiddify / NekoBox / SFA → "Add config" → URL/JSON/QR.
  Desktop:  Happ (скачать с happ.su) → импорт vless/подписки; либо Hiddify Desktop
            → "Add Profile" → singbox-desktop.json.
  Примечание: Happ на Xray-ядре принимает vless://, subscription, QR нативно;
  sing-box JSON у него — опциональная подкладка (для sing-box-клиентов он основной).

⚠ Совместимость по версиям sing-box (для sing-box-клиентов):
  - На iOS реально работает 1.11.x (sing-box-vt застрял на 1.11.4 с февраля 2025).
  - Этот конфиг сгенерирован под нижнюю планку — должен работать на iOS, Android, desktop.
  - Happ (Xray-ядро) этим ограничением не связан.

⚠ RU App Store (на 2026-05-24):
  - В RU App Store сейчас НЕТ ни Happ, ни Hiddify (наблюдение оператора).
  - Streisand, Happ, v2RayTun — удалены ещё в волне 27-28 марта 2026.
  → При новой установке на iPhone — ставь основной Happ через СМЕНУ РЕГИОНА
    App Store (то же для Hiddify/Karing). На десктоп Happ — просто с happ.su.
```

# Откат

Этот скилл — read-only по отношению к серверу. Откат = удаление сгенерированных
файлов:

```bash
rm -rf "$OUTPUT_DIR"
```

# Failed attempts (граблекейс)

- **`vless://` с `&` в shell без quoting** — символ `&` ломает shell-парсинг.
  Всегда передавать в кавычках: `cmd "vless://...&..."`.
- **Конфиг с фичами 1.12+ для iOS** — на iPhone у sing-box-vt — 1.11.4. Скилл
  при `PLATFORM=ios` НЕ использует AnyTLS, TLS-fragment, evaluate, package_name_regex.
- **`flow=xtls-rprx-vision` на старом v2rayNG** — для клиентов на Xray-ядре
  с версией < 1.8 этот flow не работает. Скилл проверяет тип клиента через
  параметр `PLATFORM` (на ios/android Hiddify/Karing — поддерживают).
- **publicKey vs privateKey** — клиенту даётся **publicKey** (`pbk` в URI),
  никогда privateKey. PrivateKey хранится только на сервере.
- **qrencode НЕ сохраняет** на /dev/stdout некоторые версии — проверка:
  если выход на stdout — оператор должен перенаправлять `> file.png`.
- **Слишком плотный QR при больших URI** — sing-box JSON слишком большой для
  QR (50KB+). QR — только для vless://-URI. Для sing-box JSON оператор
  переносит файл руками.

# Граничные случаи

- **Клиент с FLOW=xtls-rprx-vision, а PLATFORM=ios на старом sing-box-vt** →
  Hiddify/Karing на iOS поддерживают, но если у оператора версия sing-box-vt
  старее 1.10 — может не работать. Предупреждаем в финальном отчёте.
- **Несколько клиентов** (`CLIENT_NAMES` массив) → скилл итерируется и
  создаёт отдельную папку для каждого: `vpn-clients/alice/`, `vpn-clients/bob/`.
- **Domain панели != public-адрес inbound** — например, панель на `panel.example.com`,
  а inbound слушает `vpn.example.com`. Передать `PUBLIC_ADDRESS=vpn.example.com`.
- **Inbound на 443 + панель на другой порт** — типично, `PUBLIC_ADDRESS` =
  домен, порт = 443 (берётся из inbound, не из PANEL_PORT).
- **Inbound с несколькими transport** (например, vless+ws) — скрипт
  `generate-vless-link.sh` извлекает все нужные параметры (`path`, `host`)
  и добавляет в URI как `path=...&host=...`.

# Связанные документы

- `references/singbox-config-recipes.md` — 6 готовых рецептов под разные
  сценарии.
- `references/platform-quirks.md` — ограничения каждой платформы.
- `../../knowledge/networking/_reference/client-apps.md` — карта клиентов sing-box/xray.
- `../../knowledge/networking/_reference/vpn-protocols.md` §1.7 — теория VLESS+Reality.
- `decisions/0005-vpn-architecture.md` §5 — стратегия совместимости.
- `evals/triggers.md` — фразы оператора.
