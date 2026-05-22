---
knowledge_domain: vpn
layer: reference
last_researched: 2026-05-22
ttl_days: 60
sources_checked:
  - https://github.com/MHSanaei/3x-ui
  - https://xtls.github.io/en/config/routing.html
  - https://github.com/v2fly/domain-list-community
---

# Гибкая маршрутизация НА СЕРВЕРЕ (3X-UI / Xray) — приоритетный сценарий

Этот документ — **главный, дефолтный** способ организовать гибкую маршрутизацию
для неподготовленного пользователя. Все правила (РФ → direct, реклама → block,
зарубежное → upstream) живут **на сервере** в панели 3X-UI, прописываются
**самим сисадмином** под запросы пользователя. Пользователь на устройстве не
настраивает ничего, кроме одной подписки и тумблера.

Читают: персона при VPN-консультации; скиллы `/configure-vpn-routing`,
`/setup-server-proxy`, `/generate-client-config`.

Связан с:
- `vpn-consultation-flow.md` (сценарий консультации, interview, TUN, FAQ — hub)
- `3x-ui-panel.md` (архитектура панели, ядро Xray, балансировщики, observatory)
- `3x-ui-api.md` (как править routing через REST: getXrayConfig/updateXrayConfig)
- `routing-on-device-singbox.md`, `routing-on-device-xray.md` (альтернатива — split на устройстве, для энтузиастов)
- `_live/frontline-ru.md` (актуальный фронт блокировок)

---

## §0 Почему split на сервере — дефолт (а не на клиенте)

Исторически памятка курса предлагала split **на клиенте** через Hiddify
(«Hiddify смотрит на каждый запрос и решает куда»). **На практике это не
настраивается надёжно:** Hiddify не исполняет произвольные raw route-правила
так, как от него ожидали — он строит конфиг сам из подписки и пресетов и не даёт
править сырой route руками (см. `client-apps.md`). Единственный клиент, который
честно исполняет произвольные route-правила на устройстве — sing-box, но это
требует от пользователя глубоко погрузиться (см. `routing-on-device-singbox.md`).

**Поэтому дефолт перевёрнут:** клиент гонит ВЕСЬ трафик на РФ-сервер, а split
делается на сервере, где он:

1. **Настраивается один раз сисадмином** — пользователь на устройстве ничего не
   трогает, кроме импорта подписки и тумблера ON.
2. **Работает на любом клиенте** — Hiddify, Happ, Karing, v2rayNG, SFA — без
   разницы, потому что вся логика на сервере. Клиент — просто канал.
3. **Не зависит от версии ядра клиента** — раскол sing-box 1.11↔1.12 (см.
   `routing-on-device-singbox.md` §2) клиента не касается: правила исполняет
   Xray на сервере.
4. **Чинится централизованно** — поменялись блокировки → правишь один сервер,
   все устройства подхватывают через автообновление подписки.

**Цена:** РФ-трафик делает лишний hop через VPS:
`устройство → РФ-VPS → (direct) → РФ-сайт`. Это +10-20 мс и РФ-сайт видит IP
сервера, а не домашний. Для Госуслуг/Сбера это нормально — IP всё равно
российский, блокировки по «не-РФ IP» не срабатывают. Выигрыш от on-device split
(прямой выход РФ-трафика, минус hop) **не оправдывает** сложности настройки на
устройстве для типового пользователя. Если позже нужен прямой выход — РФ-сайты
можно вручную увести в direct прямо на клиенте (например, в Happ), не ломая
серверную модель.

---

## §1 Архитектура потока

```
[Устройство, любой клиент, TUN включён]
        │
        │  ВЕСЬ трафик → РФ-сервер (без split на клиенте)
        ▼
[РФ-VPS, 3X-UI, ядро Xray]
        │
        ├─ 🟢 geoip:ru / geosite:category-ru / *.ru / явный список → outbound: direct
        │       → РФ-сайт видит IP сервера (РФ), не блокирует
        ├─ 🚫 geosite:category-ads-all → block
        └─ 🔵 всё остальное → balancerTag: upstream-balancer
                                          │
                                  outbound 2..N: подписка провайдера / свой загр.VPS
                                          ▼
                                  свободный интернет
```

**Ключевое отличие от старой модели:** развилка РФ/foreign/block теперь
**внутри РФ-сервера**, а не в клиенте. Клиент шлёт всё на сервер одним потоком.

---

## §2 Синтаксис: это Xray, НЕ sing-box

> ⚠️ **Критично.** 3X-UI работает на **ядре Xray-core** (см. `3x-ui-panel.md`
> §1.1). Правила маршрутизации пишутся в **Xray-синтаксисе** (`routing.rules`
> в xray.json), а НЕ в sing-box-формате. Не путать:

| Что | Xray (сервер, 3X-UI) | sing-box (on-device) |
|---|---|---|
| Объект правила | `{"type":"field", "outboundTag":..., "domain":[...], "ip":[...]}` | `{"domain":[...], "outbound":...}` или rule actions |
| РФ-домены | `"domain": ["geosite:category-ru"]` | `"rule_set"` / `"geosite"` |
| РФ-IP | `"ip": ["geoip:ru"]` | `"geoip"` / `"ip_cidr"` |
| Блок | `"outboundTag": "blocked"` (блэкхол-outbound) | `"action": "reject"` (1.11+) |
| Ссылка на балансировщик | `"balancerTag": "..."` | нет (sing-box использует outbound напрямую) |
| Порядок | сверху вниз, первое совпавшее | сверху вниз, первое совпавшее |

Правила из этого документа НЕ ложатся в sing-box-клиент as is — для on-device
см. `routing-on-device-singbox.md`.

---

## §3 Серверная конфигурация в 3X-UI

### 3.1 Inbound (приём клиентов)

```
- Protocol: VLESS
- Network: TCP (без Reality, без TLS — трафик внутри РФ, см. vpn-consultation-flow.md §4)
- Port: любой (например 443 для маскировки)
- Listen IP: 0.0.0.0
- Clients: по одному UUID на устройство/человека
- Sniffing: ENABLED  ← обязательно, иначе domain-правила не сработают (см. §6)
```

### 3.2 Outbounds

```
- Outbound "direct"          → type: freedom (РФ-трафик выходит с IP сервера)
- Outbound "blocked"         → type: blackhole (для рекламы)
- Outbound "upstream-XX" 2..N → VLESS upstream: подписка провайдера ИЛИ свой загр.VPS
```

`direct` и `blackhole` есть в 3X-UI по умолчанию. Upstream-ы добавляются либо
через подписку провайдера (Xray Settings → Outbounds → Add Subscription), либо
вручную как VLESS-outbound на свой загр.VPS (шаблон — `3x-ui-api.md` §6.3).

### 3.3 Балансировщик (если upstream-ов несколько)

```json
{
  "tag": "upstream-balancer",
  "selector": ["upstream"],
  "strategy": { "type": "leastPing" },
  "fallbackTag": "direct"
}
```

`selector: ["upstream"]` ловит все outbound с tag, начинающимся на `upstream`.
`leastPing`/`leastLoad` требуют `observatory` (см. `3x-ui-panel.md` §1.3-1.4):

```json
{
  "observatory": {
    "subjectSelector": ["upstream"],
    "probeUrl": "http://www.google.com/gen_204",
    "probeInterval": "30s"
  }
}
```

> ⚠️ В старых конфигах встречается `pingConfig` — устаревшее имя, в свежем Xray
> не работает. Использовать `probeUrl` + `probeInterval`.

---

## §4 Правила маршрутизации — порядок критичен

В Xray правила выполняются **сверху вниз, первое совпавшее применяется**.
Порядок (в массиве `routing.rules`):

1. `geoip:private → direct` — локальная сеть (192.168.x, 10.x), безусловно
2. `geosite:category-ads-all → blocked` — реклама раньше всего
3. `geoip:ru → direct`
4. `geosite:category-ru → direct`
5. regex по `.ru`/`.su`/`.рф` → direct
6. явный список РФ-доменов на не-РФ TLD → direct (§5)
7. default (всё остальное) → `balancerTag: upstream-balancer`

### 4.1 Полный массив правил (Xray-формат)

```json
"rules": [
  {
    "type": "field",
    "ip": ["geoip:private"],
    "outboundTag": "direct"
  },
  {
    "type": "field",
    "domain": ["geosite:category-ads-all"],
    "outboundTag": "blocked"
  },
  {
    "type": "field",
    "ip": ["geoip:ru"],
    "outboundTag": "direct"
  },
  {
    "type": "field",
    "domain": [
      "geosite:category-ru",
      "regexp:.+\\.ru$",
      "regexp:.+\\.su$",
      "regexp:.+\\.xn--p1ai$"
    ],
    "outboundTag": "direct"
  },
  {
    "type": "field",
    "domain": [ "...явный список из §5..." ],
    "outboundTag": "direct"
  },
  {
    "type": "field",
    "inboundTag": ["vless-in"],
    "balancerTag": "upstream-balancer"
  }
]
```

> Примечание про `.рф`: в Xray regexp работает по punycode-форме домена, поэтому
> `.рф` записывается как `regexp:.+\\.xn--p1ai$`. Прямой `regexp:.+\\.рф$` может
> не сработать в зависимости от того, нормализует ли сборка Xray Unicode —
> **проверять на конкретной версии**, по умолчанию использовать punycode.

### 4.2 Что ловит каждый уровень

| Уровень | Ловит | НЕ ловит |
|---|---|---|
| geoip:private | локальная сеть, роутер, NAS | — |
| category-ads-all | глобальная реклама + трекеры | свежие рекламные домены вне списка |
| geoip:ru | все IP в российских подсетях | РФ-сайты на иностранном CDN (Cloudflare/Akamai) |
| geosite:category-ru | РФ-домены из [v2fly/domain-list-community](https://github.com/v2fly/domain-list-community/blob/master/data/category-ru) | домены, добавленные после обновления geosite.dat |
| regex по TLD | свежие домены в .ru/.su/.рф | РФ-сервисы на .com/.io/.app |
| явный список | РФ-сервисы на не-РФ TLD (§5) | то, что забыли добавить |

---

## §5 Явный список РФ-доменов на не-РФ TLD

Эти домены не попадают под geoip:ru (иностранный CDN) и под regex по TLD
(не .ru). Их нужно перечислить явно в правиле уровня 6.

```
# Банки
tinkoff.com, t-bank.ru, alfabank.ru, sber.ru, sberbank.ru,
online.sberbank.ru, gazprombank.ru, vtb.ru, raiffeisen.ru

# Госуслуги и государство
gosuslugi.ru, gosuslugi.com, rosreestr.ru, rosreestr.gov.ru,
nalog.ru, nalog.gov.ru, mos.ru

# Транспорт
rzd.ru, rzd-tour.ru, aeroflot.ru, aeroflot.com, pochta.ru

# IT-гиганты на не-.ru
yandex.com, ya.ru, vk.com, max.app, 2gis.com, hh.io

# Маркетплейсы
avito.ru, ozon.ru, ozon.com, wildberries.ru, wb.ru, megamarket.ru,
sbermegamarket.ru, lamoda.ru, kuper.ru

# Контент
kinopoisk.ru, ivi.ru, start.ru, okko.tv, dzen.ru

# Доставка/еда
delivery-club.ru, yandex.eda, samokat.ru

# Auto/недвига/работа
drom.ru, auto.ru, cian.ru, hh.ru, headhunter.ru, youla.ru

# API/CDN российских сервисов
appmetrica.yandex.net, vk-cdn.net, vk-portal.net
```

В Xray-правиле каждый домен — `"domain:example.com"` (точное совпадение домена
и поддоменов) или просто `"example.com"` (substring). Этот список нужно
периодически дополнять. Хранить как часть `updateXrayConfig`-шаблона скилла
`/configure-vpn-routing`.

---

## §6 Sniffing — обязательное условие domain-маршрутизации

> 🚨 **Без sniffing на inbound domain-правила (§4 уровни 2,4,6) не работают.**

Когда клиент шлёт трафик, Xray на сервере видит только IP назначения (домен
зашифрован в TLS SNI / HTTP Host). Sniffing — это инспекция первых пакетов, чтобы
извлечь домен из ClientHello (TLS) или Host-заголовка (HTTP). Без него правило
`geosite:category-ru → direct` нечем сопоставить — домена нет.

В 3X-UI: на inbound включить **Sniffing** (`destOverride`: tls, http, quic).
В терминах xray.json:

```json
"sniffing": {
  "enabled": true,
  "destOverride": ["http", "tls", "quic"]
}
```

geoip-правила (уровни 1,3) работают и без sniffing — они по IP.

---

## §7 Применение через REST API (скилл /configure-vpn-routing)

3X-UI **не имеет** отдельных эндпоинтов для outbound/routing — они правятся
целиком через xray-конфиг (см. `3x-ui-api.md` §6):

```bash
# 1. Получить текущий конфиг
api_call GET "/panel/api/inbounds/getXrayConfig"

# 2. Локально изменить outbounds + routing.rules + balancers + observatory

# 3. Отправить обновлённый
api_call POST "/panel/api/inbounds/updateXrayConfig" --json-body "$NEW_XRAY_JSON"

# 4. ОБЯЗАТЕЛЬНО перезапустить Xray
api_call POST "/panel/api/inbounds/restartXrayService"
```

> ⚠️ Без `restartXrayService` изменения остаются в SQLite, но не в работающем
> Xray (грабля `3x-ui-panel.md` §7.8). Перезапуск не рвёт живые TCP — новые
> правила применяются к новым соединениям.

**Перед правкой — бэкап БД** (`3x-ui-panel.md` §3.2):
`cp /etc/x-ui/x-ui.db /etc/x-ui/x-ui.db.backup.$(date +%Y%m%d-%H%M%S)`

---

## §8 Подписка для клиента

После настройки routing на сервере клиент получает **одну подписку** и больше
ничего не настраивает.

```
https://{DOMAIN}:{PANEL_PORT}/{SUBSCRIPTION_PATH}/{CLIENT_UUID}
```

`SUBSCRIPTION_PATH` — отдельный путь (не webBasePath!), обычно `sub` (см.
`3x-ui-api.md` §9). Ответ — base64-список `vless://`-ссылок. Импортируется в
любой клиент (Hiddify/Happ/Karing/v2rayNG/SFA) → клиент подключается к серверу,
а вся маршрутизация уже на сервере.

> Важно: при server-side split подписка отдаёт **только адрес сервера**
> (vless://), правила маршрутизации НЕ передаются клиенту — они исполняются на
> сервере. Это и есть смысл модели: клиенту знать про правила не нужно.

Генерация — скилл `/generate-client-config`: прямая ссылка + QR-код через
`qrencode`.

---

## §9 Расширение: отдельный outbound для AI (чистый IP)

Если нужно, чтобы AI-сервисы (Claude/ChatGPT/Perplexity) выходили через
отдельный чистый IP — добавить правило ВЫШЕ default, направляющее AI-домены на
персональный загр.VPS:

```json
{
  "type": "field",
  "domain": ["geosite:openai", "anthropic.com", "claude.ai", "perplexity.ai"],
  "outboundTag": "my-personal-foreign-vps"
}
```

Ставится между уровнем 6 и default (§4). На клиенте ничего не меняется. Детали
выбора загр.VPS и админских обязанностей — `vpn-consultation-flow.md` §9-10.

---

## §10 Диагностика server-side routing

```
☐ 1. На inbound включён Sniffing? (без него domain-правила мертвы — §6)
☐ 2. Порядок rules правильный? (private → ads → ru → default — §4)
☐ 3. После правки был restartXrayService? (§7)
☐ 4. Outbound "direct" есть и type=freedom?
☐ 5. Upstream-ы живы? (observatory probe проходит — 3x-ui-panel.md §1.4)
☐ 6. РФ-сайт открывается? → значит direct-правило сработало
☐ 7. Зарубежный сайт открывается? → значит upstream-balancer жив
☐ 8. Реклама блокируется? → category-ads-all → blocked сработало
```

Проверка с сервера (не через VPN):
```bash
# IP, с которого выходит РФ-трафик (должен быть IP сервера):
curl -s --interface direct ifconfig.me   # концептуально; на практике — проверка с клиента
```

С клиента: открыть РФ-сайт (sber.ru) и зарубежный (youtube.com) — оба должны
работать, реклама на страницах — резаться.

---

## §11 Связи

- **Сценарий консультации (hub):** `vpn-consultation-flow.md` (interview, TUN, выбор протокола, FAQ)
- **Архитектура панели:** `3x-ui-panel.md` (ядро Xray, балансировщики, observatory, грабли)
- **REST API:** `3x-ui-api.md` (getXrayConfig/updateXrayConfig, subscription endpoint)
- **Альтернатива (split на устройстве):** `routing-on-device-singbox.md`, `routing-on-device-xray.md`
- **Клиенты подключения:** `client-apps.md` (какой клиент что принимает)
- **Фронт блокировок:** `_live/frontline-ru.md`
- **Скиллы:** `/configure-vpn-routing`, `/setup-vpn-panel`, `/generate-client-config`, `/setup-server-proxy`
- **Визуальные схемы:** `_diagrams/vpn-architecture-student.md`
