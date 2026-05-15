---
last_verified: 2026-05-15
verification_interval: 6_months
sources:
  - https://www.postman.com/hsanaei/3x-ui/documentation/q1l5l0u/3x-ui
  - https://github.com/MHSanaei/3x-ui
  - https://github.com/MHSanaei/3x-ui/releases/tag/v3.0.1
  - https://github.com/iamhelitha/3xui-api-client
  - https://github.com/mehdikhody/3x-ui-js
  - https://packagist.org/packages/estaheri/3x-ui
  - https://pkg.go.dev/github.com/mhsanaei/3x-ui/v2/xray
  - https://deepwiki.com/MHSanaei/3x-ui/4.1-inbound-management
---

# 3X-UI REST API: cheatsheet для скиллов

REST API панели 3X-UI — **основной путь** взаимодействия скиллов сисадмина
с панелью. Прямая правка SQLite — fallback. Клики в UI — аварийный режим.

Этот документ — рабочий cheatsheet с примерами `curl`-запросов для всех
типовых операций. Документация-источник — публичная Postman-коллекция
от автора панели (`postman.com/hsanaei/3x-ui`), здесь — её выжимка
с примерами под скиллы.

Читают: все четыре скилла VPN-блока, персона при свободных вопросах
«можешь сделать X через API».

---

## 1. Базовая структура URL

```
https://{DOMAIN}:{PANEL_PORT}/{WEB_BASE_PATH}/panel/api/{ENDPOINT}
```

Где:
- `{DOMAIN}` — домен панели (например, `vpn.example.com`).
- `{PANEL_PORT}` — порт панели (нестандартный, из settings).
- `{WEB_BASE_PATH}` — случайный префикс пути (например, `abc123xyz0`),
  настроенный через `x-ui setting -webBasePath`. Если webBasePath пустой —
  префикс отсутствует, путь начинается прямо с `/panel/api/...`.
- `{ENDPOINT}` — конкретный путь эндпоинта.

**Полный пример URL для login:**
```
https://vpn.example.com:48391/abc123xyz0/login
```

> ⚠️ **webBasePath не входит в `/panel/api/...` префикс** — он стоит **до**
> него. То есть `https://domain:port/{WEB_BASE_PATH}/panel/api/...`, не
> `https://domain:port/panel/api/{WEB_BASE_PATH}/...`. Это типичная ошибка
> в комьюнити-туториалах.

---

## 2. Аутентификация и сессия

### 2.1 Логин

POST на `/login` (без префикса `/panel/api/`!) с form-data:

```bash
COOKIE_JAR=$(mktemp)

curl -s -c "$COOKIE_JAR" \
  -X POST "https://${DOMAIN}:${PORT}/${WEB_PATH}/login" \
  -d "username=${ADMIN_LOGIN}&password=${ADMIN_PASSWORD}"
```

Ответ — JSON:
```json
{ "success": true, "msg": "Login Successfully", "obj": null }
```

Если `success: false` — `msg` содержит причину (`Username or password is incorrect`,
`Login attempt limit exceeded` и т.п.).

Cookie сессии сохраняется в `$COOKIE_JAR` (формат Netscape, стандартный
для curl). Эта cookie используется во всех последующих запросах.

### 2.2 Использование сессии

```bash
curl -s -b "$COOKIE_JAR" \
  "https://${DOMAIN}:${PORT}/${WEB_PATH}/panel/api/inbounds/list"
```

### 2.3 Срок жизни сессии

Сессия живёт до явного logout или до перезапуска панели. Скилл, работающий
одной непрерывной сессией (создал inbound → клиенты → outbound → routing →
restart), может использовать одну cookie от начала до конца.

**Если сессия истекла** (например, между разными скиллами) — повторный
вызов `/login` создаст новую cookie.

### 2.4 Безопасная очистка

В конце скилла:

```bash
rm -f "$COOKIE_JAR"
```

(cookie содержит токен с правами админа панели — не должна валяться).

---

## 3. Helper-функция для скиллов

Все четыре VPN-скилла используют общий хелпер `scripts/_lib-api.sh`. Его
интерфейс:

```bash
# Загрузить хелпер
source "$(dirname "$0")/_lib-api.sh"

# Аутентифицироваться (читает из ENV или config)
api_login \
  --domain "$PANEL_DOMAIN" \
  --port "$PANEL_PORT" \
  --web-path "$WEB_BASE_PATH" \
  --admin "$ADMIN_LOGIN" \
  --password-ref "keychain:3xui-panel-${SERVER_ALIAS}"

# Выполнить запрос (cookie уже загружена)
api_call GET "/panel/api/inbounds/list"
api_call POST "/panel/api/inbounds/add" --json-body "$INBOUND_JSON"
api_call DELETE "/panel/api/inbounds/del/3"

# Перезапустить Xray
api_restart_xray

# Logout и очистка
api_logout
```

Хелпер абстрагирует:
- Получение пароля из менеджера паролей оператора (по ссылке в `password-ref`).
- Управление cookie-сессией.
- Парсинг `success: true/false` ответов.
- Retry с экспоненциальной задержкой при network errors.
- Паузы 100-200мс между массовыми запросами (защита от database lock,
  см. `3x-ui-panel.md` §7.4).

---

## 4. Inbounds — управление входными точками

### 4.1 Список всех inbound

```bash
api_call GET "/panel/api/inbounds/list"
```

Ответ:
```json
{
  "success": true,
  "msg": "",
  "obj": [
    {
      "id": 1,
      "up": 0, "down": 0, "total": 0,
      "remark": "vless-tcp-main",
      "enable": true,
      "expiryTime": 0,
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": "{\"clients\":[{\"id\":\"...\",\"flow\":\"\",\"email\":\"alice\"}],\"decryption\":\"none\",\"fallbacks\":[]}",
      "streamSettings": "{\"network\":\"tcp\",\"security\":\"none\",\"tcpSettings\":{...}}",
      "tag": "inbound-443",
      "sniffing": "{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"]}"
    }
  ]
}
```

**Важное:** поля `settings`, `streamSettings`, `sniffing` — это **строки**
со вложенным JSON. Для работы нужно `jq` с `fromjson` или промежуточная
обработка.

### 4.2 Получить один inbound

```bash
api_call GET "/panel/api/inbounds/get/1"
```

### 4.3 Добавить inbound

```bash
INBOUND_JSON='{
  "remark": "vless-tcp-main",
  "enable": true,
  "expiryTime": 0,
  "listen": "0.0.0.0",
  "port": 443,
  "protocol": "vless",
  "settings": "{\"clients\":[{\"id\":\"UUID-HERE\",\"flow\":\"\",\"email\":\"alice\"}],\"decryption\":\"none\",\"fallbacks\":[]}",
  "streamSettings": "{\"network\":\"tcp\",\"security\":\"none\",\"tcpSettings\":{\"header\":{\"type\":\"none\"}}}",
  "tag": "inbound-443",
  "sniffing": "{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"]}"
}'

api_call POST "/panel/api/inbounds/add" --json-body "$INBOUND_JSON"
```

### 4.4 Обновить inbound

```bash
api_call POST "/panel/api/inbounds/update/1" --json-body "$INBOUND_JSON"
```

### 4.5 Удалить inbound

```bash
api_call POST "/panel/api/inbounds/del/1"
```

(красная зона — type-to-confirm в скилле).

### 4.6 Шаблоны settings для разных протоколов

#### VLESS-TCP (без Reality, для внутреннего РФ-трафика)

```json
{
  "clients": [
    { "id": "UUID-1", "flow": "", "email": "alice", "limitIp": 0, "totalGB": 0, "expiryTime": 0, "enable": true }
  ],
  "decryption": "none",
  "fallbacks": []
}
```

streamSettings:
```json
{
  "network": "tcp",
  "security": "none",
  "tcpSettings": { "header": { "type": "none" } }
}
```

#### VLESS + Reality (для загр.VPS, маскировка от DPI)

streamSettings:
```json
{
  "network": "tcp",
  "security": "reality",
  "realitySettings": {
    "show": false,
    "xver": 0,
    "dest": "www.cloudflare.com:443",
    "serverNames": ["www.cloudflare.com"],
    "privateKey": "PRIVATE_KEY_FROM_KEYGEN",
    "shortIds": ["", "0123456789abcdef"],
    "settings": {
      "publicKey": "PUBLIC_KEY_FROM_KEYGEN",
      "fingerprint": "chrome",
      "serverName": "www.cloudflare.com",
      "spiderX": "/"
    }
  }
}
```

Генерация ключей перед созданием Reality inbound:

```bash
# на сервере с установленным Xray (внутри 3X-UI lежит в /usr/local/x-ui/bin/)
/usr/local/x-ui/bin/xray-linux-amd64 x25519
# вывод:
# Private key: UuMBgl7MXTPx9inmQp2UC7Jcnwc6XYbwDNebonM-FCc
# Public key:  9wjeUbiP8w8I4iVi3p9J3LbphTpW3ws5WjAGz6BiL14
```

#### Mixed (SOCKS5+HTTP на одном порту, для серверного прокси)

settings:
```json
{
  "auth": "noauth",
  "udp": false,
  "ip": "127.0.0.1"
}
```

streamSettings:
```json
{ "network": "tcp", "security": "none" }
```

`listen: "127.0.0.1"` — обязательно (mixed inbound не должен торчать в интернет).

---

## 5. Clients — управление пользователями

### 5.1 Добавить клиента к существующему inbound

```bash
CLIENT_JSON='{
  "id": 1,
  "settings": "{\"clients\":[{\"id\":\"NEW-UUID\",\"flow\":\"\",\"email\":\"bob\",\"limitIp\":0,\"totalGB\":0,\"expiryTime\":0,\"enable\":true}]}"
}'

api_call POST "/panel/api/inbounds/addClient" --json-body "$CLIENT_JSON"
```

Где `id: 1` — ID inbound (не клиента!). Структура `settings` — JSON-строка
с массивом `clients` (даже если добавляется один).

### 5.2 Массовое добавление клиентов

```bash
api_call POST "/panel/api/inbounds/addClientInbounds" --json-body "$BULK_JSON"
```

(см. дополнение к ТЗ Василия про этот эндпоинт).

### 5.3 Обновить клиента

```bash
# clientId здесь — UUID клиента, не его порядковый номер
api_call POST "/panel/api/inbounds/updateClient/UUID-HERE" --json-body "$CLIENT_JSON"
```

### 5.4 Удалить клиента

```bash
api_call POST "/panel/api/inbounds/${INBOUND_ID}/delClient/UUID-HERE"
```

### 5.5 Статистика трафика клиента

```bash
# по email
api_call GET "/panel/api/inbounds/getClientTrafficsByEmail/alice"

# по UUID
api_call GET "/panel/api/inbounds/getClientTrafficsById/UUID-HERE"
```

Ответ:
```json
{
  "success": true,
  "obj": {
    "id": 123, "inboundId": 1, "enable": true,
    "email": "alice", "up": 1234567, "down": 9876543,
    "expiryTime": 0, "total": 0, "reset": 0
  }
}
```

### 5.6 Сброс трафика

```bash
# одного клиента
api_call POST "/panel/api/inbounds/${INBOUND_ID}/resetClientTraffic/alice"

# всех клиентов всех inbound
api_call POST "/panel/api/inbounds/resetAllTraffics"

# всех клиентов одного inbound
api_call POST "/panel/api/inbounds/resetAllClientTraffics/${INBOUND_ID}"
```

### 5.7 IP-история клиента

```bash
api_call POST "/panel/api/inbounds/clientIps/alice"
```

```bash
api_call POST "/panel/api/inbounds/clearClientIps/alice"
```

### 5.8 Удаление исчерпавших трафик

```bash
api_call POST "/panel/api/inbounds/delDepletedClients/${INBOUND_ID}"
```

(удаляет всех клиентов, у которых `up+down >= total` или `expiryTime` прошёл).

### 5.9 Онлайн клиенты

```bash
api_call POST "/panel/api/inbounds/onlines"
```

Ответ:
```json
{ "success": true, "obj": ["alice", "bob"] }
```

---

## 6. Outbounds и routing

### 6.1 Особенность: outbounds не имеют отдельных API-эндпоинтов

В отличие от inbound, outbound и routing rules не имеют отдельных
CRUD-эндпоинтов. Они хранятся внутри **общего xray-конфига**, который
изменяется через специальные эндпоинты.

Текущий xray-конфиг:

```bash
api_call GET "/panel/api/inbounds/getXrayConfig"
```

(возвращает полный JSON Xray, включая outbounds, routing, balancers,
dns, log).

### 6.2 Обновить xray-конфиг (outbounds + routing)

```bash
api_call POST "/panel/api/inbounds/updateXrayConfig" --json-body "$NEW_XRAY_JSON"
```

Где `$NEW_XRAY_JSON` — полный xray-конфиг с обновлёнными outbounds /
routing / balancers. Скилл `/configure-vpn-routing`:
1. Получает текущий через `getXrayConfig`.
2. Парсит, добавляет/изменяет нужные секции.
3. Отправляет обновлённый через `updateXrayConfig`.
4. Перезапускает Xray (см. §7).

### 6.3 Шаблон outbound VLESS (для multi-hop)

```json
{
  "tag": "upstream-de",
  "protocol": "vless",
  "settings": {
    "vnext": [
      {
        "address": "de.example.com",
        "port": 443,
        "users": [
          {
            "id": "OUTBOUND-UUID",
            "encryption": "none",
            "flow": "xtls-rprx-vision"
          }
        ]
      }
    ]
  },
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
      "show": false,
      "fingerprint": "chrome",
      "serverName": "www.cloudflare.com",
      "publicKey": "PUBLIC-KEY-OF-UPSTREAM",
      "shortId": "0123456789abcdef",
      "spiderX": "/"
    }
  }
}
```

### 6.4 Шаблон routing rule

```json
{
  "type": "field",
  "outboundTag": "direct",
  "domain": ["geosite:category-ru", "regexp:.*\\.ru$"],
  "ip": ["geoip:ru"]
}
```

Или (если несколько upstream-ов через балансировщик):

```json
{
  "type": "field",
  "inboundTag": ["inbound-443", "inbound-1080"],
  "balancerTag": "upstream-balancer"
}
```

### 6.5 Шаблон балансировщика

```json
{
  "tag": "upstream-balancer",
  "selector": ["upstream"],
  "strategy": { "type": "leastPing" },
  "fallbackTag": "direct"
}
```

В блоке `observatory`:

```json
{
  "observatory": {
    "subjectSelector": ["upstream"],
    "probeUrl": "http://www.google.com/gen_204",
    "probeInterval": "30s"
  }
}
```

---

## 7. Перезапуск Xray (обязательно после изменений!)

```bash
api_call POST "/panel/api/inbounds/restartXrayService"
```

**Без перезапуска** изменения в SQLite не подхватываются работающим
Xray-процессом. Это та самая «грабля сохранения» из `3x-ui-panel.md` §7.8.

Перезапуск **не** прерывает сессии клиентов мгновенно — TCP-соединения
живы, но новые правила маршрутизации применяются к новым соединениям.

---

## 8. Системные операции

### 8.1 Статус сервера

```bash
api_call POST "/panel/api/server/status"
```

Возвращает CPU, RAM, Disk, uptime, версию Xray, версию 3X-UI, информацию
о сетевых интерфейсах.

### 8.2 Бэкап базы

```bash
api_call POST "/panel/api/inbounds/createbackup"
# скачивает x-ui-backup.db
```

Или отправка в Telegram:
```bash
api_call POST "/panel/api/inbounds/backuptotgbot"
```

### 8.3 Загрузка бэкапа

```bash
api_call POST "/panel/api/inbounds/uploadbackup" --file backup.db
```

(красная зона — перезаписывает текущую БД).

### 8.4 Информация о версии

```bash
api_call GET "/panel/api/server/getDb"
```

(возвращает версию панели и Xray-ядра).

---

## 9. Subscription endpoint

3X-UI отдаёт subscription по адресу:

```
https://{DOMAIN}:{PANEL_PORT}/{SUBSCRIPTION_PATH}/{CLIENT_UUID}
```

Где `SUBSCRIPTION_PATH` — отдельный путь (не `webBasePath`!), настраиваемый
в settings. Обычно `sub` или `subscribe`.

Содержание ответа — base64-encoded список `vless://...\nvmess://...` ссылок
от всех inbound, в которых есть данный UUID. Это формат, который понимают
все sing-box / xray клиенты.

**Применение в скилле `/generate-client-config`:** после создания клиента
скилл получает subscription URL и отдаёт оператору как:
1. Прямую ссылку на subscription (для импорта в Hiddify/Karing/NekoBox).
2. QR-код этой ссылки (для удобства).

---

## 10. Версии API: v1 REST vs v2 gRPC

### 10.1 Текущее состояние (2026-05)

- **v1 REST API** — рабочий, документированный, стабильный. Эндпоинты как
  выше (`/panel/api/...`).
- **v2 gRPC API** — внутренний, для управления самим Xray-ядром. Используется
  изнутри панели, для внешних скиллов **не предназначен**.

Скиллы сисадмина работают **только через v1 REST**. v2 gRPC появляется в
исходниках (`mhsanaei/3x-ui/v2/xray`), но это не публичный контракт.

### 10.2 In-panel API documentation (с v3.0.1)

С версии 3.0.1 в самой панели есть встроенная страница API documentation —
доступна как `/{WEB_BASE_PATH}/panel/api-docs/` (требует авторизации).

Если версия панели ≥ 3.0.1 — скилл может проверить актуальность эндпоинтов
через эту страницу, не лезя в Postman.

---

## 11. Готовые клиентские библиотеки

Не обязательны для использования (скиллы работают через `curl`), но
полезны как **референс**:

| Язык | Библиотека | Где |
|---|---|---|
| Node.js | `iamhelitha/3xui-api-client` | github.com/iamhelitha/3xui-api-client |
| Node.js | `mehdikhody/3x-ui-js` | github.com/mehdikhody/3x-ui-js |
| PHP | `estaheri/3x-ui` | packagist.org/packages/estaheri/3x-ui |
| Go (internal) | `mhsanaei/3x-ui/v2/xray` | pkg.go.dev (gRPC, не REST!) |

Когда сомнения «как вызвать X через API» — посмотреть код любой из библиотек,
обычно там понятный маппинг «метод → эндпоинт».

---

## 12. Защитные паттерны при работе через API

### 12.1 Пауза 100-200мс между массовыми запросами

Защита от database locking (см. `3x-ui-panel.md` §7.4).

```bash
for client in "${CLIENTS[@]}"; do
  api_call POST "/panel/api/inbounds/addClient" --json-body "$CLIENT_JSON"
  sleep 0.15
done
```

### 12.2 Retry с экспоненциальной задержкой

При network errors или 500 Internal Server Error — повтор 3 раза с
интервалами 1с, 2с, 4с. Реализовано в `_lib-api.sh`.

### 12.3 Откат при ошибке посередине сложной операции

Если скилл делает: «добавить inbound → добавить 5 клиентов → обновить
routing → restart Xray» — и на шаге 3 произошёл сбой:

- Скилл **не оставляет систему в полу-настроенном состоянии**.
- Либо откатывает inbound (delete) и клиенты, либо продолжает с явным
  ретраем и логом «откат не нужен, повторяю».
- В любом случае — restart Xray в конце, чтобы либо все изменения
  применились, либо их не было.

### 12.4 Не доверять полю `success: true` слепо

3X-UI возвращает `success: true` даже на некоторые семантические ошибки.
Скилл проверяет результат **функционально**: после добавления inbound —
делает `getXrayConfig` или `list inbounds` и убеждается, что новый inbound
действительно появился. После restart Xray — проверяет, что `systemctl
status x-ui` остался `active (running)`.

---

## 13. Когда API не справляется: fallback к SQLite

Не все сценарии покрыты REST API. Известные кейсы:

- **Кастомные настройки sniffing** глубже чем `destOverride` — могут
  потребовать прямой правки в SQLite.
- **Изменение `webBasePath`** через API не предусмотрено — только через
  `x-ui setting -webBasePath` CLI или прямую правку таблицы `settings`.
- **Восстановление из бэкапа с миграцией структуры** — через `uploadbackup`
  API не всегда корректно работает между сильно разнесёнными версиями.

В таких случаях скилл переходит к **прямой правке SQLite**:

```bash
# Бэкап обязателен
cp /etc/x-ui/x-ui.db /etc/x-ui/x-ui.db.backup.$(date +%s)

# Остановить панель
systemctl stop x-ui

# Правка через sqlite3
sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value='/new-path/' WHERE key='webBasePath';"

# Запуск
systemctl start x-ui

# Проверка
sleep 2
systemctl status x-ui | grep "active (running)" || echo "FAIL"
```

**Третий уровень fallback** — попросить оператора нажать что-то в UI
панели вручную (с подробным брифингом). Это аварийный режим, применяется
**только если API + SQLite не сработали**, и каждый такой случай — повод
для todo «обновить скилл, когда узнаю, как делать X через API».

---

## 14. Связь с другими документами

- `vpn-protocols.md` — какие протоколы можно настраивать через API
  (см. шаблоны settings в §4.6).
- `3x-ui-panel.md` — операционные грабли панели, перезапуск Xray,
  бэкап SQLite.
- `client-apps.md` — какие subscription-форматы какие клиенты понимают.

---

*Документ обновляется планово раз в 6 месяцев. Триггеры внеплановой
ревизии: breaking changes в API между мажорными версиями 3X-UI,
появление v2 REST (если станет публичным), переименование эндпоинтов,
изменение схемы JSON в `settings`/`streamSettings`.*
