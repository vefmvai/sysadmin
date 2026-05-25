# Форматы ответа подписки (что приходит и как распознать)

Subscription URL — это HTTP(S)-endpoint, который при запросе возвращает список
VPN-серверов. Разные провайдеры отдают РАЗНЫЕ форматы. `parse-subscription.sh`
определяет формат сам и вызывает нужный парсер. Здесь — карта форматов с
фактурой из боевых подписок.

## Формат 1: base64-encoded список vless://

Самый частый у российских платных провайдеров (Blanc VPN, Bebra VPN). Тело —
одна длинная base64-строка. После декодирования:

```
vless://uuid-1@host1:443?type=tcp&security=reality&...#🇺🇸 USA-1
vless://uuid-2@host2:443?type=tcp&security=none#🇳🇱 NL-1
```

Распознаётся эвристикой: вся строка матчит `^[A-Za-z0-9+/=\s]+$` и не содержит
`://`. Разбирается через `parse-vless-link.sh` (по одной ссылке).

## Формат 2: Plain-text список vless://

То же, но без base64 — сразу строки `vless://...`. Распознаётся по наличию
`://`. Парсер тот же.

## Формат 3: Xray-JSON массив профилей (Panterra / Remnawave) — ГЛАВНЫЙ кейс

Современные провайдеры на панели **Remnawave** (Panterra, NurVPN) отдают НЕ
список ссылок, а **массив полноценных Xray-профилей**. Каждый элемент массива —
объект с ключами `dns`, `inbounds`, `outbounds`, `remarks`, `routing`:

```json
[
  {
    "remarks": "🇺🇸 США",
    "outbounds": [
      { "tag": "proxy",   "protocol": "vless", "settings": {...}, "streamSettings": {...} },
      { "tag": "proxy-2", "protocol": "vless", ... },
      { "tag": "direct",  "protocol": "freedom" },
      { "tag": "block",   "protocol": "blackhole" }
    ],
    "routing": {...}, "dns": {...}, "inbounds": [...]
  },
  { "remarks": "🇷🇺 Россия # 3 | Белый список", "outbounds": [ {...vless...} ], ... }
]
```

Сервера лежат в `.outbounds[] | select(.protocol=="vless")`. Разбирает
`parse-xray-json.sh`.

> ⚠️ **Именно этот формат старый скрипт НЕ понимал.** Он искал `vless://`-строки
> и, не найдя их в JSON, выдавал ложный «0 серверов» / «тупик». На самом деле
> сервера на месте — просто упакованы в Xray-профили.

**Особенность первого профиля `[0]`:** часто содержит НЕСКОЛЬКО vless-outbounds
(группа серверов одной страны под балансир) — теги `proxy`, `proxy-2`, ...
Остальные профили — по одному vless-outbound. `parse-xray-json.sh` разворачивает
многосерверный профиль в отдельные сервера.

### Структура vless-outbound (точные поля Xray)

| Что | Путь в JSON |
|---|---|
| адрес | `.settings.vnext[0].address` |
| порт | `.settings.vnext[0].port` |
| uuid | `.settings.vnext[0].users[0].id` |
| flow | `.settings.vnext[0].users[0].flow` |
| транспорт | `.streamSettings.network` (`tcp`/`xhttp`/`grpc`/`ws`) |
| security | `.streamSettings.security` (`reality`/`tls`/`none`) |
| reality | `.streamSettings.realitySettings.{serverName,publicKey,shortId,fingerprint}` |
| tls | `.streamSettings.tlsSettings.{serverName,fingerprint,alpn}` |
| xhttp | `.streamSettings.xhttpSettings.{mode,host,path}` |
| grpc | `.streamSettings.grpcSettings.{serviceName,authority}` |
| страна | `.remarks` профиля (эмодзи-флаг, напр. `🇺🇸 США`) |

`shortId` в reality **бывает отсутствует** (например, у tcp/reality в Panterra
его нет, а у xhttp/reality — есть). Парсер не выдумывает: нет поля → пустая
строка.

### Боевые комбинации transport × security (одна подписка Panterra, 35 серверов)

| transport / security | сколько |
|---|---|
| tcp / reality | 26 |
| grpc / reality | 5 |
| xhttp / reality | 3 |
| xhttp / none | 2 |
| xhttp / tls | 1 |

Все пять `parse-xray-json.sh` нормализует в единую схему.

## Формат 4: sing-box JSON

Некоторые провайдеры при sing-box-клиенте отдают sing-box-конфиг:

```json
{ "outbounds": [ { "type": "vless", "server": "host", "server_port": 443,
                   "uuid": "...", "tls": {...}, "transport": {...} } ] }
```

`parse-xray-json.sh` распознаёт и его (ветка sing-box: outbound с `type=vless`,
а не `protocol=vless`). У Panterra формат именно Xray, не sing-box, — но ветка
есть на случай других провайдеров.

## Формат 5: Clash YAML

Реже. `proxies:` со списком серверов. **Не поддерживается** этим скиллом —
сменить User-Agent (`v2rayN`) или попросить у провайдера прямой vless://-link.

## Заголовки ответа — мета-информация

Помимо тела, провайдер сообщает состояние через HTTP-заголовки. Их читает
`inspect-subscription.sh` (разведка):

| Заголовок | Что значит |
|---|---|
| `x-hwid-active: true` | HWID-механизм включён |
| `x-hwid-limit: true` | лимит устройств включён |
| `x-hwid-not-supported: true` | прислан не-Happ клиент → заглушка |
| `x-hwid-max-devices-reached: true` | слотов нет / HWID не в списке → заглушка |
| `subscription-userinfo: upload=…;download=…;total=…;expire=<unixts>` | расход и срок |
| `profile-title: base64:…` | название (декодировать) |
| `announce: base64:…` | сообщение провайдера (часто бот/инструкция) |

Детали HWID — `hwid-mechanism.md`.

## Заглушка (что приходит вместо серверов при HWID-замке)

```
vless://00000000-0000-0000-0000-000000000000@0.0.0.0:1?...#App%20not%20supported
```

Признаки: нулевой UUID, адрес `0.0.0.0`, текст «App not supported» / «лимит
устройств». `parse-subscription.sh` распознаёт и выходит с кодом **3** (а не
глухим «0 серверов»).

## Дебаг, если пришло что-то странное

1. `curl -sI <URL>` — посмотреть заголовки и Content-Type.
2. `curl -s <URL> | head -c 500` — первые 500 байт.
3. Видишь `0.0.0.0` / «App not supported» / нулевые UUID → HWID-locked
   (нужен HWID + свободный слот, см. `hwid-mechanism.md`).
4. Видишь `[{...,"outbounds":[...]}]` → Xray-JSON, это нормально, парсится.
5. Видишь `proxies:` (YAML) → Clash, не поддерживается, сменить User-Agent.

## Связанные документы

- `hwid-mechanism.md` — устройство HWID-привязки Remnawave, состояния, слоты.
- `../../configure-vpn-routing/references/subscription-formats.md` — список
  известных провайдеров и User-Agent-рекомендации.
