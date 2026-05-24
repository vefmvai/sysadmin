---
knowledge_domain: vpn
layer: reference
last_researched: 2026-05-24
ttl_days: 60
sources_checked:
  - https://sing-box.sagernet.org/clients/
  - https://sing-box.sagernet.org/clients/apple/
  - https://sing-box.sagernet.org/clients/apple/features/
  - https://sing-box.sagernet.org/clients/android/
  - https://github.com/SagerNet/sing-box
  - https://github.com/SagerNet/sing-box/releases
  - https://github.com/SagerNet/sing-box/issues
  - https://github.com/SagerNet/sing-box-for-android
  - https://apps.apple.com/us/app/sing-box-vt/id6673731168
  - https://apps.apple.com/us/app/hiddify-proxy-vpn/id6596777532
  - https://apps.apple.com/us/app/karing/id6472431552
  - https://apps.apple.com/us/app/streisand/id6450534064
  - https://apps.apple.com/us/app/happ-proxy-utility/id6504287215
  - https://apps.apple.com/us/app/v2raytun/id6476628951
  - https://f-droid.org/packages/io.nekohasekai.sfa/
  - https://github.com/hiddify/hiddify-app/releases
  - https://github.com/KaringX/karing/releases
  - https://github.com/MatsuriDayo/NekoBoxForAndroid/releases
  - https://github.com/2dust/v2rayNG/releases
  - https://hiddify.com/app/URL-Scheme/
  - https://ntc.party/c/blocking/
  - https://www.happ.su/main/dev-docs/routing
  - https://www.happ.su/main/dev-docs/app-management
  - https://www.happ.su/main/dev-docs/examples-of-links-and-parameters
  - https://www.happ.su/main/dev-docs/ping
  - https://routing.happ.su/
---

# Клиентские приложения: карта на 2026-05-24
<!-- Happ-routing блок (§3.6) добавлен 2026-05-22 по отдельному исследованию -->
<!-- 2026-05-24: Happ назначен основным рекомендованным клиентом (ADR-0007),
     исправлена аргументация про удаление из RU App Store -->


> 🎯 **Основной рекомендованный клиент агента — `Happ`** («Happ — Proxy
> Utility», happ.su). Кроссплатформенный (iPhone, Android, Windows, macOS, Linux),
> на Xray-ядре, умеет on-device routing (§3.6). Hiddify, Karing, v2rayN, sing-box
> (sing-box-vt/SFA), v2rayNG — **альтернативы**. Обоснование выбора — ADR-0007.
>
> **Про установку (важно, исправлено 2026-05-24):** в RU App Store сейчас нет ни
> Happ, ни Hiddify. Поэтому для установки **любого** VPN-клиента на iPhone (если
> его ещё нет на устройстве) нужна **смена региона App Store** (Казахстан/Армения
> и т.п.; для бесплатных приложений оплата не требуется). На десктоп Happ ставится
> просто **с сайта happ.su** (все ссылки: https://www.happ.su/main/ru). Старый
> аргумент «рекомендуем Hiddify, потому что Happ удалён, а Hiddify — нет» больше
> **не работает**: удаление из RU App Store бьёт по обоим одинаково.


Этот документ — карта клиентских приложений для VPN-инфраструктуры,
организованной агентом-сисадмином. Покрывает приложения на двух ядрах
(sing-box и xray) для всех платформ (iOS, Android, macOS, Windows, Linux).

Читают: персона при ответах оператору «какой клиент поставить»;
скилл `/generate-client-config` при генерации конфигов под конкретное
приложение; косвенно — `/configure-vpn-routing` (формат subscription).

---

## 1. Главный вывод

> 📍 **Клиент — это канал подключения, а не инструмент маршрутизации.** При
> дефолтной модели (split на сервере, `routing-server-3xui.md`) клиент только
> подключается к РФ-серверу и гонит весь трафик туда — правила РФ/foreign/block
> исполняет сервер. Поэтому для дефолта **подойдёт любой клиент** из списка ниже.
>
> Гибкая маршрутизация **на устройстве** (route-правила в самом клиенте) —
> отдельный сценарий. Его умеют **Happ** (Xray-ядро, через импорт routing-профиля
> — основной клиент агента для on-device split, см. §3.6 и `routing-on-device-xray.md`)
> и **sing-box-ядро** (raw route, `routing-on-device-singbox.md`, для энтузиастов).
> **Hiddify для on-device split не годится** — он не исполняет произвольный raw
> route, а строит конфиг из подписки сам (см. §3.3). Это подтверждено практикой
> оператора (2026-05-22).

Карта запутанная из-за двух причин:
1. **Два ядра** — sing-box и xray. Конфиги между ними **не полностью
   совместимы** (xray не понимает sing-box JSON; sing-box не понимает
   часть xray-фич mux.cool, fragment, mkcp).
2. **iOS-боль 2024-2026** — оригинальное sing-box-приложение снято из
   App Store, замены отстают по версии ядра, массовое удаление VPN-приложений
   из RU App Store 27-28 марта 2026.

**Универсальный рецепт (основной — Happ, остальное — альтернативы):**
- **iOS** — `Happ` (основной) / `Hiddify` / `Karing`. В RU App Store сейчас нет
  ни Happ, ни Hiddify → для новой установки нужна смена региона App Store. Если
  какой-то клиент уже установлен — не удалять (переустановить без смены региона
  не получится).
- **Android** — `Happ` (основной) / `Hiddify` / `NekoBox` / `SFA` (sing-box
  официальный) / `v2rayNG` (xray). Happ — Google Play (`com.happproxy`) или APK
  с happ.su; остальные — GitHub Releases / Google Play.
- **macOS** — `Happ` (скачать с happ.su, основной) / `Hiddify` / `Karing` /
  sing-box CLI как brew-сервис.
- **Windows** — `Happ` (скачать с happ.su, основной) / `Hiddify` / `Karing` /
  sing-box CLI через WinTun.
- **Linux** — `Happ` (с happ.su) / Hiddify desktop / sing-box как systemd-сервис.

---

## 2. iOS — критическая зона

### 2.1 Хронология оригинального sing-box-приложения

| Дата | Событие |
|---|---|
| Июль 2023 | Появление в App Store (Sager Networks Ltd.) |
| 1 августа 2024 | **Unpublished** из App Store по «нетехническим причинам» |
| 13 августа 2024 | Issue #2024 в GitHub: «not available in your country» из множества регионов |
| Сентябрь 2024 | Появление `sing-box-vt` (ID 6673731168) от VIRAL TECH, INC. — де-факто продолжение под другим юр-лицом, © nekohasekai |
| 24 февраля 2025 | Последнее обновление `sing-box-vt` — v1.11.4 (с тех пор не обновлялся) |
| 27-28 марта 2026 | Массовое удаление VPN-приложений из RU App Store по запросу российских властей: Streisand, v2Box, v2RayTun, Happ |

**Источник по удалениям:** TechCrunch (2024-07-08), TheRegister (2024-09-26),
9to5Mac (2024-09-28), TechRadar, NovayaGazeta (2026-03-31 — Apple официально
признала удаление 190 приложений за три года).

### 2.2 Текущее состояние альтернатив на iOS (на 2026-05-15)

| Клиент | App Store ID | Ядро | Версия ядра | RU App Store |
|---|---|---|---|---|
| **Happ** | 6504287215 | Xray-core (по умолч.) + опция sing-box | трекает свежий Xray | Удалён в волне ~28.03.2026; на 2026-05-24 в RU App Store **нет** |
| **Hiddify Proxy & VPN** | 6596777532 | hiddify-sing-box + Xray | непроверено конкретный тег | На 2026-05-24 в RU App Store **нет** (наблюдение оператора) |
| **Karing** | 6472431552 | mihomo (clash.meta) + модифицированный sing-box | непроверено | Статус в RU App Store на 2026-05-24 — ❓ уточнить |
| **sing-box-vt** | 6673731168 | sing-box 1.11.x | 1.11.4 (24.02.2025) | Возможно удалено в волне 27-28.03.2026 — требует прямой проверки |
| Streisand | 6450534064 | Xray-core | n/a | **УДАЛЕНО** ~28.03.2026 |
| FoXray | 6448898396 | Xray-core | соответствует Xray | непроверено (под угрозой) |
| v2RayTun | 6476628951 | Xray-core (версия трекает релизы) | n/a | **УДАЛЕНО** ~28.03.2026 |

> ⚠️ **Ключевой вывод по RU App Store (на 2026-05-24).** В российском App Store
> сейчас **нет ни Happ, ни Hiddify** (наблюдение оператора 2026-05-24; happ.su
> при этом жив — HTTP 200). Значит «не удалён» больше **не аргумент** в пользу
> какого-либо клиента: для установки любого клиента на iPhone, если его ещё нет
> на устройстве, в любом случае нужна **смена региона App Store**. Колонка выше
> фиксирует и историческую волну удалений (~28.03.2026), и текущий статус — это
> разные вещи: волна была, и она затронула обоих кандидатов. Статус меняется
> волнами — при сомнении проверять напрямую / `/refresh-vpn-knowledge LAYER=live`.

**Рекомендация для iOS:**
- **Новое устройство в РФ** — `Happ` (основной; happ.su) — поставить через смену
  региона App Store. Альтернативы — `Hiddify Proxy & VPN`, `Karing` (тоже через
  смену региона, т.к. в RU App Store их сейчас нет).
- **Старое устройство, уже что-то стоит** — не удалять. Любой работающий клиент
  (Happ / Hiddify / sing-box-vt / Streisand / Karing) переустановить без смены
  региона не получится.
- **Энтузиаст с другим Apple ID** — переключить регион (Казахстан, Армения),
  поставить нужный клиент оттуда. Для бесплатных приложений оплата не нужна.

### 2.3 Ограничения iOS-конфигов sing-box

В TUN inbound на iOS **не реализованы** опции (Apple sandbox limit):
- `gso` — Generic Segmentation Offload.
- `strict_route`.
- `include_interface` / `exclude_interface`.
- `include_uid` / `exclude_uid`.
- Process-based: `process_name`, `process_path`, `process_path_regex` —
  недоступны на iOS И macOS («no permission» на обеих).

Routing rule `wifi_ssid` / `wifi_bssid` — **только iOS** (на macOS отсутствуют).

**Практический вывод для `/generate-client-config`:** при `platform=ios`
не использовать `strict_route`, не делать routing-rules по `process_name`.
Использовать только rule_set + ip_cidr + domain_*.

### 2.4 Критическое: версии ядра внутри iOS-клиентов

| Клиент | Версия ядра sing-box внутри | Отставание от мейнлайна (1.13.12) |
|---|---|---|
| sing-box-vt | 1.11.4 (Feb 2025) | -2 минора (нет 1.12, 1.13 фич) |
| Hiddify v4.1.1 (iOS) | непроверено (форк hiddify-sing-box) | предположительно 1.11-1.12 |
| Karing (iOS) | непроверено | mihomo + sing-box-fork |

**Это значит:** конфиги, использующие фичи sing-box 1.12+:
- `anytls` протокол — не работает на iOS.
- Новый формат DNS-сервера `{type, server}` — на iOS только старый
  `{address}`.
- `tls_fragment` в route-options — не работает на iOS.
- `evaluate` action — не работает (1.14+).
- `package_name_regex` — Android-only (на iOS вообще нет).

Скилл `/generate-client-config` при `platform=ios` **генерирует конфиги
под совместимость с sing-box 1.11** (нижняя планка), используя только
поля и фичи, доступные в этой ветке.

---

## 3. Android

### 3.1 Sing-box for Android (SFA) — официальный

| Параметр | Значение |
|---|---|
| Repo | github.com/SagerNet/sing-box-for-android |
| Developer на Google Play | Viral Tech, Inc. (та же связка что sing-box-vt iOS) |
| F-Droid | io.nekohasekai.sfa |
| F-Droid version | 1.13.11 (build 662, 24 апреля 2026, 91 MiB) |
| Min Android | 6.0+ |
| Google Play | 500K+ установок, рейтинг 3.9 |

**Доступность в РФ Google Play:** не проверено прямо. Google Play обычно
не блокирует VPN-приложения в РФ так массово как Apple. F-Droid доступен
без ограничений.

### 3.2 NekoBox для Android

| Параметр | Значение |
|---|---|
| Repo | github.com/MatsuriDayo/NekoBoxForAndroid |
| Ядро | sing-box (форк с суффиксом `-neko`) |
| Stable | 1.4.1 (30 октября 2025), sing-box `1.12.12-neko-1` |
| Preview | pre-1.4.2-20260202-1 (2 февраля 2026), sing-box `1.12.19-neko-1` |
| Min Android | 5.0+ |
| Поддерживаемые протоколы | Shadowsocks, VMess, VLESS, Trojan, Hysteria 1/2, TUIC, WireGuard, SOCKS, HTTP(S), SSH, AnyTLS, ShadowTLS, Trojan-Go, NaïveProxy, Mieru |
| Доступность | **Только GitHub Releases** (нет в Google Play официально) |

GitHub Releases доступен в РФ без ограничений → независимость от Google.

### 3.3 Hiddify Android

| Параметр | Значение |
|---|---|
| Repo | github.com/hiddify/hiddify-app |
| Google Play | app.hiddify.com |
| Текущая версия | v4.1.1 (5 марта 2026) |
| Ядро | hiddify-sing-box (форк, база ~1.8.x по тегам v1.8.8.h*) + опционально Xray-core |
| Версия sing-box внутри | непроверено конкретный тег (форк со своими отклонениями формата) |
| Raw route-правила руками | **НЕТ** — строит конфиг из подписки/пресетов, произвольный route не исполняет |

> ⚠️ **Hiddify — хороший клиент подключения, но НЕ инструмент on-device
> маршрутизации.** Для гибкого split на устройстве — sing-box-клиент
> (`routing-on-device-singbox.md`). Для дефолта (split на сервере) Hiddify
> отлично подходит как канал.

### 3.4 v2rayNG (Android, Xray)

| Параметр | Значение |
|---|---|
| Repo | github.com/2dust/v2rayNG |
| Ядро | **Xray-core**, не sing-box |
| Прямой импорт sing-box JSON | **Не поддерживается** |
| Принимает | vless://, vmess://, trojan://, ss://, subscription URL (base64) |

**Применение:** оператор использовал v2rayNG раньше — продолжает использовать.
Для новых установок — лучше Hiddify (универсальнее).

### 3.5 Karing Android

Тот же бинарь Karing, что и для iOS — Flutter-приложение, cross-platform.
Поддержка Clash / Sing-box / V2ray / Shadowsocks подписок.

### 3.6 Happ (cross-platform)

| Параметр | Значение |
|---|---|
| Repo | github.com/Happ-proxy/happ-android (репозиторий релизов/APK, не полный исходник) |
| Разработчик | Flyfrog LLC (по данным App Store) |
| Платформы | iOS, Android, macOS, Windows, Linux, TV (отдельный листинг id6748297274) |
| Десктоп (Win/macOS/Linux) | скачать прямо с **happ.su** (https://www.happ.su/main/ru) — смена региона стора не нужна |
| Google Play | com.happproxy |
| App Store (iOS/macOS) | id6504287215 — удалён в волне ~28.03.2026; на 2026-05-24 в RU App Store нет → ставить через смену региона (как и Hiddify, которого там тоже нет) |
| Ядро по умолчанию | **Xray-core** (актуальная версия меняется с релизами — уточнять при необходимости) |
| Опция sing-box / tun2proxy | На десктопе как TUN-движок; можно подложить свой sing-box-конфиг (`custom-tunnel-config`) |
| Хранение | Закрытое (encrypted on device), конфиг остаётся на устройстве |

#### 3.6.1 Happ умеет on-device split-routing (через JSON-профиль)

> В отличие от Hiddify (§3.3), Happ **умеет** гибкую маршрутизацию на устройстве —
> но не «накликать в UI», а через **импорт routing-профиля** (JSON). Способы импорта:
> deeplink `happ://routing/add/{base64}` (или `/onadd/` — добавить и активировать,
> `/off` — выключить), QR-код, строка в подписке. JSON удобно собирать в визуальном
> веб-конструкторе **routing.happ.su** (Happ Routing Builder), который выдаёт готовый
> base64-deeplink.

#### Точный формат профиля (офиц. дока `happ.su/main/dev-docs/routing`, проверено 2026-05-22)

> Поля — **с заглавной буквы**. `GlobalProxy` и `FakeDNS` — булевы **как строки**
> (`"true"`/`"false"`). Direct/Proxy/Block-массивы — массивы строк. `DnsHosts` —
> объект (домен→IP). Дубль `Name` обновляет существующий профиль.

```json
{
  "Name": "RU-direct",
  "GlobalProxy": "false",
  "RemoteDNSType": "DoH",
  "RemoteDNSDomain": "https://1.1.1.1/dns-query",
  "RemoteDNSIP": "1.1.1.1",
  "DomesticDNSType": "DoH",
  "DomesticDNSDomain": "https://common.dot.dns.yandex.net/dns-query",
  "DomesticDNSIP": "77.88.8.8",
  "Geoipurl": "",
  "Geositeurl": "",
  "DnsHosts": {},
  "DirectSites": ["geosite:category-ru"],
  "DirectIp": ["geoip:ru", "geoip:private"],
  "ProxySites": [],
  "ProxyIp": [],
  "BlockSites": ["geosite:category-ads-all"],
  "BlockIp": [],
  "DomainStrategy": "IPIfNonMatch",
  "FakeDNS": "false"
}
```

- geo-синтаксис в массивах: `"geoip:ru"`, `"geosite:category-ru"`, `"geosite:ads"`
  (lowercase). Кастомные базы — URL в `Geoipurl`/`Geositeurl`.
- **Импорт:** `happ://routing/add/{base64}` — добавить; `happ://routing/onadd/{base64}`
  — добавить и активировать; `happ://routing/off` — выключить routing. `{base64}` —
  **стандартный base64 RFC 4648** JSON-профиля. ✅ **Проверено на устройстве 2026-05-22:**
  QR со стандартным base64 импортируется в Happ (iOS) корректно, все поля переносятся
  1:1. Также работает QR-код и строка в подписке.

**Семантика `GlobalProxy` и порядок правил** (✅ проверено на устройстве, iOS, 2026-05-22 —
дока это не расписывала):

- **Порядок применения: `Block → Direct → Proxy`** (первое совпавшее).
- `GlobalProxy: "false"` — **дефолт = direct**: весь НЕперечисленный трафик идёт мимо
  прокси (direct). Block/Direct-списки — исключения. ⚠️ В этом режиме «всё прочее» НЕ
  идёт через прокси-сервер — для сценария «РФ→direct, остальное→сервер» он НЕ подходит.
- `GlobalProxy: "true"` — **дефолт = proxy**: весь НЕперечисленный трафик идёт через
  сервер. Direct-список — исключения (РФ→мимо прокси), Block→reject. **Это правильный
  режим** для «РФ→direct, реклама→block, остальное→через сервер».
- Цитата из UI Happ: «Если "Глобальный прокси" отключён, весь трафик идёт в обход
  прокси, за исключением указанных вами настроек маршрута».
- `FakeDNS: "false"` — поддельный DNS выкл; geo-базы Happ тянет сам (Loyalsoldier
  geosite.dat/geoip.dat), фича «урезать геофайлы» включена по дефолту.

**Per-app routing на Android** (офиц. `app-management`):
- `per-app-proxy-mode: [off / on / bypass]` — режим
- `per-app-proxy-list: [com.app1,com.app2]` — список приложений
- `per-app-proxy-list-invert: [...]` — применить ко ВСЕМ, кроме списка
- `per-app-proxy-list-set: [...]` — очистить текущее и задать только эти

**Оговорка:** провайдер может **глобально запретить** пользовательский routing
параметром `routing-enable` (`Disable routing`): `true`/`1` — включён, любое другое
непустое (`0`/`false`) — выключен. Доставляется в HTTP-заголовке или теле подписки
(`#routing-enable: 0`). На залоченной провайдером подписке ручных правил может не
быть. На своей инфре это не помеха.

Сценарий «РФ → direct, заграница → proxy, реклама → block» реализуется напрямую:
`DirectSites/DirectIp: ["geosite:category-ru","geoip:ru"]`, `BlockSites:
["geosite:category-ads"]`, остальное → proxy. Готовые наборы правил под РФ
раздают через deeplink (напр. репозитории `hydraponique/roscomvpn-routing`,
`demontmk/happ-routing`).

> 💡 **Для оператора с server-side routing** (`routing-server-3xui.md`):
> on-device routing в Happ почти всё **дублирует** серверный. Реально ценен один
> кейс — `geoip:ru → direct` **на устройстве**, чтобы РФ-трафик вообще не ходил на
> VPS (сервер этого не может — трафик уже пришёл к нему). Остальное — дублирование.
> Подробнее про on-device Xray-routing — `routing-on-device-xray.md`.

#### 3.6.2 Почему «все работают через Happ»

И популярность клиента, и формат подписок: у Happ свои `happ://` deeplink-схемы не
только для серверов, но и для **импорта routing-профилей**. Провайдеры раздают и
серверы, и готовые правила одной ссылкой — отсюда ощущение «всё через Happ». Это не
отдельный сетевой протокол, а схема импорта конфигов поверх обычного Xray/VLESS.

#### 3.6.3 Chain (multi-hop) в Happ: «быстрейший вход + фиксированный exit»

Запрос оператора: вход = автоматически быстрейший из пула, exit = всегда один
фиксированный сервер (один и тот же выходной IP). Что подтверждено по офиц. доке
(проверено напрямую 2026-05-22):

| Механизм | В Happ |
|---|---|
| Авто-выбор быстрейшего сервера (url-test / leastPing / «best») | **Нет нативно.** Ping-страница даёт только ручное измерение (ICMP/TCP/Proxy), auto-select/группы нет |
| Chain / dialerProxy в **routing-профиле** | **Нет** — поля профиля и параметры подписки про chain не знают |
| Импорт **полного кастомного Xray-JSON** | **Да.** Дока: *«this JSON configuration is passed exactly as is»* ядру Xray. **НО** *«standard HAPP routing rules and interface settings are not applied»* |

**Вывод:** схема реализуема **только через импорт полного Xray-конфига** в Happ —
в нём ты сам описываешь `balancer`+`observatory` на входном звене (быстрейший вход)
и `streamSettings.sockopt.dialerProxy` на фиксированный exit (ровно как в
`xray-mac-chain.md`). Xray это умеет, sing-box chain VLESS→VLESS — нет (issue
SagerNet/sing-box#1562, «not planned»).

**Trade-off (важно):** при импорте полного Xray-JSON **нативный Happ-routing
отключается** — весь split (geoip:ru→direct, ads→block) надо описать в том же
Xray-JSON, поля `DirectSites`/etc больше не действуют. То есть нельзя совместить
«удобный Happ-routing-профиль» и «chain» в одном конфиге — либо одно, либо другое.

> 🔑 **Для whitelist-сценария оператора** (когда сервер недоступен по белым
> спискам и маршрутизация нужна на клиенте): именно полный Xray-JSON с chain даёт
> максимум контроля. Структура chain-конфига — `xray-mac-chain.md` + Xray-routing
> в `routing-on-device-xray.md`.

> ⚠️ Не подтверждено на устройстве: точная структура, которую Happ ждёт при
> импорте «config as is» (полный xray.json vs только outbounds-секция), и
> совместимость balancer+observatory внутри Happ. Проверять импортом.

---

## 4. macOS

### 4.1 sing-box CLI

- Установка через Homebrew (`brew install sing-box`).
- Версия — мейнлайн **v1.13.12** (15.05.2026), идентично Linux.
- Запуск через `brew services start sing-box` или launchd plist.
- Конкретный путь brew formulae и launchd plist — непроверено в офиц.доке,
  но это стандартные практики.

### 4.2 GUI на macOS

| Клиент | Доступ | Особенности |
|---|---|---|
| `sing-box-vt` (он же SFM) | App Store, тот же ID что iOS, macOS 13.0+ | Версия 1.11.4 (отстаёт) |
| `Hiddify` | Mac Catalyst или отдельный DMG/PKG с GitHub | v4.1.1, требуется macOS 10.15+ |
| `Karing` | Mac Catalyst, тот же ID что iOS | Cross-platform Flutter |
| `FoXray` | App Store | Xray-core |

### 4.3 Системная интеграция

- **TUN-mode** через NetworkExtension (Apple sandbox).
- Те же ограничения, что и на iOS: `process_name`-routing недоступен.
- **Route-table modifications**: sing-box делает через NetworkExtension API;
  root не нужен для App Store-версий, но нужен для `sing-box-cli` как daemon.

---

## 5. Windows

### 5.1 sing-box CLI

- Скачать `sing-box-windows-amd64.zip` с GitHub Releases.
- Версия — мейнлайн v1.13.12.
- Запуск как Windows-сервис — через `nssm` или `sc create` (встроенного
  `install-service` нет).

### 5.2 GUI

| Клиент | Источник | Версия |
|---|---|---|
| `sing-box-windows` (сторонний) | github.com/xinggaoya/sing-box-windows | Modern GUI с подписками |
| `Hiddify` | github.com/hiddify/hiddify-app | v4.1.1, .msix / .exe / portable |
| `Karing` | github.com/KaringX/karing/releases | непроверено |
| **NekoRay** (NekoBox для desktop) | github.com/qr243vbi/nekobox (NyameBox-форк) | Qt-приложение |

### 5.3 TUN-драйвер

Sing-box на Windows использует **WinTun** (wintun.net) — лёгкий TUN-драйвер
от WireGuard. Альтернатива TAP-Windows не используется.

---

## 6. Linux

### 6.1 Sing-box как systemd-сервис

Установка через пакетный менеджер:
- Debian/Ubuntu: `apt install sing-box`
- Fedora/RHEL: `dnf install sing-box`
- Arch: `pacman -S sing-box`

systemd unit ставится автоматически: `systemctl enable --now sing-box`.

Capabilities в systemd unit:
- `CAP_NET_ADMIN` — TPROXY и TUN-интерфейс
- `CAP_NET_BIND_SERVICE` — порты <1024
- `CAP_NET_RAW` — ICMP и raw sockets
- `CAP_SYS_PTRACE` — process-based routing rules

### 6.2 GUI на Linux

- **Hiddify Desktop**: AppImage, .deb, .rpm для x86_64. v4.1.1, март 2026.
- **Karing Linux**: AppImage / deb.
- Стабильного нативного gtk/qt-клиента от SagerNet **нет**. Документация
  sing-box для desktop помечает «Working in progress».

---

## 7. Форматы импорта конфига

### 7.1 Сводная таблица

| Формат | Что внутри | Кто принимает |
|---|---|---|
| **vless:// / vmess:// / trojan:// / ss:// / tuic:// / hysteria2:// (URI)** | Один сервер с параметрами в URL | **Все** клиенты (xray + sing-box) — самый совместимый |
| **Subscription URL (HTTP)** | base64-список URI или sing-box JSON | sing-box-vt, SFA, Hiddify, Karing, Happ, NekoBox, v2rayNG, Streisand |
| **Sing-box JSON** | Полный конфиг с inbounds/outbounds/route | sing-box-vt, SFA, Hiddify, Karing, NekoBox |
| **Clash YAML** | proxies/rules/proxy-groups | Karing (нативно mihomo), NekoBox (через импорт) |
| **Hiddify-профиль** (`hiddify://`) | Расширенный URI с метаданными | Только Hiddify |
| **QR-код** | Кодирует одно из выше (обычно vless://) | Все клиенты с камерой |

### 7.2 Карта «какой клиент что принимает»

| Клиент | vless:// | subscription | sing-box JSON | Clash YAML | hiddify:// |
|---|---|---|---|---|---|
| sing-box-vt (iOS/macOS) | ✅ | ✅ | ✅ | ❌ | ❌ |
| SFA (Android) | ✅ | ✅ | ✅ | ❌ | ❌ |
| Hiddify (все платформы) | ✅ | ✅ | ✅ | ✅ | ✅ |
| Karing (все платформы) | ✅ | ✅ | ✅ | ✅ | ❌ |
| NekoBox (Android, desktop) | ✅ | ✅ | ✅ | ✅ | ❌ |
| v2rayNG (Android) | ✅ | ✅ | ❌ | ❌ | ❌ |
| Streisand (iOS) | ✅ | ✅ | ❌ | ❌ | ❌ |
| Happ (cross) | ✅ | ✅ | опционально | ❌ | ❌ |
| FoXray (iOS/macOS) | ✅ | ✅ | ❌ | ❌ | ❌ |
| v2RayTun (iOS/Android) | ✅ | ✅ | ❌ | ❌ | ❌ |

### 7.3 Что должен отдавать `/generate-client-config`

| Целевой клиент | Главный формат | Запасной |
|---|---|---|
| sing-box-vt, SFA, Hiddify, Karing | sing-box JSON через subscription URL | массив vless:// в base64 |
| NekoBox | sing-box JSON через subscription URL | vless:// |
| Streisand, FoXray, Happ, v2RayTun, v2rayNG | xray-совместимый subscription (массив vless://?security=reality...) | vless:// напрямую |
| Универсальный fallback | один vless:// URI + QR-код + текст | — |

---

## 8. Subscription URL: серверная сторона

Эндпоинт вида:
```
https://sub.example.com/<token>
```

Возвращает либо:
- Для xray-клиентов (Streisand, Happ, v2rayNG): `Content-Type: text/plain`,
  тело = base64-encoded `\n`-separated `vless://`/`vmess://` ссылки.
- Для sing-box-клиентов (sing-box-vt, SFA, Hiddify, Karing):
  `Content-Type: application/json`, тело = валидный sing-box JSON.
- Универсально (предпочтительно): оба формата по разным URL —
  `/sub/xray` и `/sub/singbox` — либо content-negotiation по `User-Agent`.

### 8.1 Hiddify URL Scheme — расширенный импорт

`hiddify://import/<sublink>#name` — импорт через URI Scheme.
Поддерживает HTTP-заголовки:
- `Profile-Title: My VPN` — название профиля в UI Hiddify. Поддерживает
  base64-кодирование: `Profile-Title: base64:SSDinaTvuI8gSGlkZGlmeQ==` →
  отображается как «I ❤️ Hiddify».
- `Content-Disposition` filename, URL fragment (`#name`) — fallback.
- `Subscription-Userinfo: upload=...; download=...; total=...; expire=...`
  — опционально для отображения квоты (стандарт clash, не подтверждено
  в основной странице URL-Scheme Hiddify).

### 8.2 Subscription из 3X-UI

3X-UI имеет встроенный subscription endpoint на отдельном `subPath`
(см. `3x-ui-api.md` §9). Скилл `/generate-client-config` берёт оттуда
готовую ссылку и:
1. Отдаёт оператору прямую URL.
2. Генерирует QR-код через `qrencode`.

---

## 9. Sing-box-ядро: совместимость по версиям

### 9.1 Карта версий

| Клиент | Версия ядра | Поколение |
|---|---|---|
| sing-box mainline CLI (Linux/Win/macOS) | 1.13.12 | Latest |
| SFA (Android, F-Droid) | 1.13.11 | Latest |
| NekoBox stable 1.4.1 | 1.12.12-neko-1 | -1 минор |
| NekoBox preview 1.4.2 | 1.12.19-neko-1 | -1 минор |
| sing-box-vt iOS/macOS | 1.11.4 | **-2 минора** |
| Hiddify v4.1.1 | непроверено (форк ветки 1.x) | предположительно 1.11-1.12 |
| Karing | непроверено | вероятно близко к мейнлайну |

### 9.2 Какие фичи доступны на каких ветках

| Фича | Минимальная версия |
|---|---|
| Auto-redirect (Linux TUN) | 1.10.0 |
| Inline rule-set | 1.10.0 |
| Rule actions (reject, sniff, resolve, route-options) | 1.11.0 |
| endpoints (WireGuard через endpoint) | 1.11.0 |
| Network strategy (multi-interface) | 1.11.0 |
| DNS-сервер новый формат `{type, server}` | 1.12.0 |
| AnyTLS протокол | 1.12.0 |
| TLS fragment в route-options | 1.12.0 |
| Domain resolver (заменяет domain_strategy) | 1.12.0 |
| reject с method (drop/reply) | 1.13.0 |
| bypass action (Linux auto_redirect) | 1.13.0 |
| evaluate action, tls_spoof | 1.14.0 (alpha) |

### 9.3 Стратегия совместимости для `/generate-client-config`

| Целевая платформа | Нижняя планка ядра | Запрещённые фичи |
|---|---|---|
| iOS | sing-box 1.11.x | AnyTLS, TLS fragment, новый DNS-формат, evaluate, package_name |
| Android (через Hiddify/NekoBox/SFA) | sing-box 1.12 | evaluate (1.14+) |
| Desktop (через mainline CLI / Hiddify) | sing-box 1.13 | evaluate (1.14+ alpha) |
| Универсальный (любая платформа) | sing-box 1.11.x | как iOS |

При сомнении — генерируется конфиг под **наинижшую планку** (iOS = 1.11),
он точно сработает на остальных платформах.

---

## 10. Расширения совместимости — выбор flow

`flow: "xtls-rprx-vision"` требует **совпадения версии XTLS на сервере
и клиенте**. На старых Xray (до 1.8) или старом sing-box (до 1.6) этого
flow не было.

Если серверный inbound настроен с `flow: "xtls-rprx-vision"`:
- Hiddify, Karing, sing-box-mainline — поддерживают.
- Старый v2rayNG (до Xray 1.8) — нет.
- Streisand на старых iOS — может быть нет.

При сомнениях — генерировать конфиг с пустым `flow` (это просто VLESS без
XTLS Vision). Деградация только в производительности (Vision splice
включает оптимизации TCP), функционально работает везде.

---

## 11. Связь с другими документами

- `vpn-protocols.md` — какие протоколы (VLESS/VMess/Trojan/...) принимают
  клиенты.
- `routing-server-3xui.md` — маршрутизация на сервере (дефолт). Клиент = канал.
- `routing-on-device-singbox.md` — маршрутизация на устройстве через sing-box
  (для энтузиастов; единственное ядро, честно исполняющее raw route).
- `routing-on-device-xray.md` — то же через Xray в терминале.
- `vpn-consultation-flow.md` — сценарий консультации (hub).
- `3x-ui-panel.md` — серверная сторона, генерация subscription endpoint.
- `3x-ui-api.md` — субскрипция через REST API, получение vless://-link
  по UUID клиента.

---

*Документ обновляется планово раз в 6 месяцев. Триггеры внеплановой
ревизии: обновление списков удалённых из App Store / Google Play VPN-приложений;
релиз новой минорной версии sing-box с breaking changes для клиентов;
обновление iOS/Android API, ломающее TUN inbound; смена политики Apple
по RU App Store.*
