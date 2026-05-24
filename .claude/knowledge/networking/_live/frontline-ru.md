---
knowledge_domain: vpn
layer: live
geography: ru
last_researched: 2026-05-17
ttl_days: 14
sources_checked:
  - https://blog.cloudflare.com/russian-internet-users-are-unable-to-access-the-open-internet/
  - https://ooni.org/post/2024-russia-report/
  - https://habr.com/ru/news/901584/
  - https://xakep.ru/2025/04/17/rkn-white-lists/
  - https://en.zona.media/article/2025/06/27/cloud_confirmed
  - https://en.zona.media/article/2026/04/07/russian_internet_censorship_2026
  - https://meduza.io/en/news/2026/04/02/rbc-russia-asks-major-online-platforms-to-block-users-with-active-vpns-by-april-15
  - https://meduza.io/en/feature/2026/04/30/russia-blocks-vpn-access-to-major-platforms-moves-to-charge-for-mobile-vpn-traffic
  - https://themoscowtimes.com/2026/04/15/russian-websites-begin-blocking-vpn-users-as-internet-controls-tighten-a92511
  - https://themoscowtimes.com/2026/05/04/mobile-network-operators-warn-customers-of-internet-and-phone-disruptions-ahead-of-victory-day-a92674
  - https://reuters.com/world/russia-limits-mobile-internet-ahead-scaled-back-ww2-victory-parade-2026-05-05/
  - https://habr.com/ru/articles/1006424/
  - https://garant.ru/products/ipo/prime/doc/412901371/
  - https://jamestown.org/russian-directive-expands-internet-control/
  - https://ridl.io/russia-s-digital-crackdown/
  - https://reuters.com/technology/russia-goes-after-vpns-great-crackdown-gathers-pace-2026-03-31/
  - https://osw.waw.pl/en/publikacje/analyses/2026-04-17/russia-blocks-telegram-and-cracks-down-vpns
  - https://novayagazeta.eu/en/articles/2026/04/28/
  - https://techradar.com/vpn/vpn-services/russias-battle-against-vpns-is-entering-a-new-phase-heres-what-to-expect-in-2026
  - https://github.com/net4people/bbs/issues/589
  - https://habr.com/en/articles/990190/
  - https://habr.com/en/articles/990144/
  - https://roskomsvoboda.org/uploads/en__vpn_in_russia__from_blocking_services_to_blocking_protocols.pdf
---

# Фронт РФ: VPN-блокировки на 2026-05-17

## TL;DR

В РФ на середину мая 2026 — фаза агрессивной эскалации.

- **На прикладном уровне:** с 15 апреля 2026 крупные российские платформы (Sberbank, Yandex, VK, Ozon, Wildberries, Госуслуги, РЖД, Aviasales, ~20 компаний) **активно блокируют пользователей с обнаруженным VPN** — по требованию Минцифры под угрозой лишения IT-аккредитации и исключения из white-list.
- **На сетевом уровне:** работают **только маскирующиеся протоколы** (Banzaev/Amnezia, цитата HIGH). Это **VLESS+Reality**, **AmneziaWG 2.0**, **Hysteria2** с правильной конфигурацией, **Trojan**, **NaiveProxy** (через XRay). Голый WireGuard, OpenVPN, IKEv2, plain Shadowsocks — **заблокированы**.
- **На транспортном уровне:** с 9 июня 2025 действует **«16-килобайтный занавес»** — Cloudflare/Hetzner/DigitalOcean/OVH трафик дросселируется до ~16 KB на запрос, дальше TCP-reset (HTTP/1.1, HTTP/2, HTTP/3). Действует у Ростелекома, МТС, Мегафона, Билайна, МГТС.
- **На административном уровне:** с 1 марта 2026 действует **Постановление № 1667** — централизованное управление сетью связи, ФСБ может приказать отключить конкретные базовые станции.
- **Мобильные операторы (МТС/Мегафон/Билайн/T2):** работают по **white-list** ~500 сервисов; с 1 мая 2026 планируется доплата 150 руб/ГБ за foreign-трафик >15 ГБ/мес; с 1 апреля 2026 отключён Apple ID top-up через мобильный счёт.

**Главные риски на 14 дней вперёд:**
- Точечные отключения мобильного в Москве/СПб «по запросу ФСБ» — без расписания, по событиям.
- Расширение списка платформ, блокирующих VPN-пользователей.
- Возможное введение доплаты за foreign-мобильный трафик (анонсировано на 1 мая, на 30 апреля ещё не введено).

---

## Шкала уверенности

- ✅ **работает** — подтверждено HIGH-источником ≤30 дней.
- 🔴 **не работает** — подтверждено HIGH-источником ≤30 дней.
- 🟡 **под угрозой** — есть MEDIUM-сигналы о деградации или планируемых мерах.
- ❓ **уточнить** — нет надёжного подтверждения.

---

## 🟢 Что работает (на 2026-05-17)

### Протоколы

| Протокол | Статус | Источник |
|---|---|---|
| **VLESS+Reality** (с правильным `dest`/`serverName`) | ✅ Работает | TechRadar/Banzaev (HIGH); Habr 990144 (MEDIUM): «неотличим от обычного HTTPS-трафика»; community-tutorials (MEDIUM) |
| **VMess (через XRay, с TLS/Reality)** | ✅ Работает с оговорками | Banzaev/Amnezia (HIGH) |
| **Trojan (через XRay)** | ✅ Работает с оговорками | Banzaev/Amnezia (HIGH) |
| **NaiveProxy** | ✅ Работает с оговорками | Banzaev/Amnezia (HIGH) |
| **AmneziaWG 2.0** (CPS, tagged I1–I5, range-based H1–H4) | ✅ Работает | net4people/bbs #589 (HIGH); Banzaev: «регулятор периодически блокирует сигнатуры — требуется регулярное обновление» |
| **Hysteria2** (с правильной обфускацией Salamander + masquerade) | ✅ Работает с оговорками | Banzaev/Amnezia (HIGH); community-репорты (MEDIUM) |
| **Shadowsocks SS2022** | 🟡 Работает в ограниченных сценариях | SIP022 spec (HIGH) даёт anti-active-probing; общественные репорты неоднозначны (см. §Открытые вопросы) |

### Транспорты

| Транспорт | Статус | Источник |
|---|---|---|
| **XHTTP (Xray-only)** | ✅ Работает; рекомендован при TLS 1.3 throttling | XTLS docs (HIGH); см. `_reference/transports.md` §3 |
| **HTTPUpgrade** | ✅ Работает (альтернатива WebSocket) | XTLS docs / sing-box docs (HIGH) |
| **TCP+Reality** | ✅ Работает | XTLS REALITY README (HIGH) |
| **gRPC** | 🟡 Работает, но больше DPI-внимания | community (MEDIUM) |
| **WebSocket с TLS** | 🟡 Работает с реальным сертификатом и доменом | community (MEDIUM) |
| **QUIC (как голый UDP-транспорт)** | 🔴 Не работает | Cloudflare blog (HIGH): неопознанный UDP блокируется |

### Стратегии

- ✅ **Multi-hop клиент → RU-VPS → загр.VPS**: работает (трансграничный B2B-трафик режется мягче, чем клиент→загр). См. `_reference/vpn-protocols.md` §4. Уязвимое звено — RU-сервер (см. § Под угрозой).
- ✅ **Reality с правильным donor** (без CDN в РФ — Microsoft с 2022 без CDN, github и т.п.). См. `_reference/fronting-strategies.md`.
- ✅ **iOS-клиенты через смену региона App Store.** Основной рекомендованный клиент — **Happ** (happ.su, кроссплатформенный); альтернативы — Hiddify, Karing. ⚠️ Обновление 2026-05-24 (наблюдение оператора): в RU App Store сейчас **нет ни Happ, ни Hiddify** — для установки любого клиента на iPhone нужна смена региона App Store; на десктоп Happ ставится с happ.su. Подробно — `_reference/client-apps.md`, событие — `timeline.md` (2026-05-24).

---

## 🔴 Что НЕ работает

### Заблокировано полностью

| Объект | С когда | Источник |
|---|---|---|
| **WireGuard plain** (без обфускации) | Первые блокировки — сентябрь 2021 (Rostelecom, Beeline); массово — 2024-Q3 | wireguard mailing list HIGH; RoskomSvoboda HIGH; к 2026 — plain WG заблокирован у всех крупных провайдеров (HIGH) |
| **OpenVPN plain** (TCP/UDP, со стандартным P-ACK signature) | Документировано как detectable DPI | Banzaev/Amnezia (HIGH); RelyVPN tier-list (MEDIUM) |
| **IKEv2 plain** | Documented DPI signature | Banzaev/Amnezia (HIGH) |
| **Shadowsocks plain (без plugin'ов)** | К 2026 — заблокирован массово | Fexyn (MEDIUM); Mediazona (HIGH): «детектируется энтропийным анализом» |
| **Cloudflare ECH (Encrypted Client Hello)** | Ноябрь 2024 | The Insider HIGH; ppc.land HIGH |
| **VLESS без маскировки** (TLS без Reality, или TCP open) | Октябрь 2025 (массовая блокировка) | Mediazona (HIGH): РКН через ТСПУ блокировал VLESS как один из самых продвинутых — провайдеры выпустили новые конфиги |

### Сильно деградировано (>50% потерь / throttling)

| Объект | Эффект | С когда | Источник |
|---|---|---|---|
| **TLS-трафик к Cloudflare ASN AS13335** | 16-KB curtain: после ~16 KB соединение reset | 9 июня 2025 | Cloudflare blog (HIGH); ZONA (HIGH); BleepingComputer (MEDIUM) |
| **TLS-трафик к Hetzner провайдеру** | 16-KB curtain | июнь 2025 | Cloudflare blog (HIGH) — на уровне провайдера, не строго ASN |
| **TLS-трафик к DigitalOcean** | 16-KB curtain | июнь 2025 | Cloudflare blog (HIGH) |
| **TLS-трафик к OVH** | Throttling/UDP-блокировка (механизм формально не идентичен 16 KB curtain) | конец мая 2025 | ZONA (HIGH); ? уточнить точный механизм (не подтверждено: 2026-05-17) |
| **HTTP/3 (QUIC) к подозрительным ASN** | Same 16-KB curtain — также затронут | 9 июня 2025 | Cloudflare blog (HIGH) |
| **Доступ к Sberbank/Yandex/VK/Ozon/Wildberries/Госуслугам/РЖД с VPN** | Платформы блокируют запросы с VPN-IP по требованию Минцифры | дедлайн 15 апреля 2026 | Meduza (HIGH); Moscow Times (HIGH); OSW Warsaw (HIGH) |

### Платформенные удары (не сетевой уровень)

- 🔴 **Apple ID пополнение через мобильный счёт** — отключено у МТС, Билайн, Мегафон, T2 с 1 апреля 2026 (HIGH: Meduza, ZONA). Цель — затруднить покупку VPN в App Store.
- 🔴 **Массовое удаление VPN-приложений из RU App Store** — документировано в 2024-2026 как сплошной процесс. На 2026-05-17 в RU App Store сохранились: Hiddify, Karing (см. `_reference/client-apps.md`).

---

## 🟡 Под угрозой в ближайшие 14 дней

| Объект | Природа угрозы | Источник |
|---|---|---|
| **Доплата 150 ₽/ГБ foreign-трафика >15 ГБ/мес на мобильных** | Анонсировано на 1 мая 2026, на 30 апреля ещё не введено. Может быть введено в любой момент | Meduza (HIGH); RIDL (MEDIUM); Russiable (LOW) |
| **Расширение списка платформ, блокирующих VPN** | Меньшие игроки следуют за Sber/Yandex; точечные платформы могут добавляться | Meduza HIGH; OSW HIGH |
| **Точечные отключения мобильного в Москве по запросу ФСБ** | В марте 2026 — почти 3 недели в центре Москвы; механизм действующий | ZONA (HIGH); RIDL (MEDIUM) |
| **Multi-hop через RU-сервер: блокировка исходящих foreign-IP с российских VPS** | Постановление № 1667 (с 1 марта 2026) даёт РКН технические возможности «перенаправлять трафик через ТСПУ». Прогноз: первая волна — Q3-Q4 2026 (Jamestown). Сейчас работает | Jamestown (MEDIUM); Habr 1006424 (HIGH) |
| **Reality с serverName cloudflare.com в РФ** | Сама cloudflare в 16-KB curtain → handshake может выглядеть нормально, но downlink дросселируется | Cloudflare blog HIGH; ? уточнить специфику Reality (не подтверждено: 2026-05-17) |
| **WebSocket и gRPC под TLS 1.3 к подозрительным ASN** | Покрываются 16-KB curtain как любой TLS-трафик | Cloudflare blog HIGH |

> **Примечание про обратную параллель «иностранный турист в РФ».**
> Field-report 2026-05-17 из Шанхая (см. `_live/frontline-cn.md` §4.5 и
> `_meta/conflicts.md` КОНФЛИКТ-004) показал что **российские VPN-сервисы
> работают с обычного китайского WiFi** — потому что их ASN не в приоритетном
> target list GFW (китайцам интересна «диссидент-инфраструктура» в HK/SG/TW,
> а не «инфраструктура для иностранцев» на Hetzner/OVH/Aeza).
>
> По симметричной логике можно предположить (❓ не подтверждено: 2026-05-17,
> ждёт field-report от китайского туриста в РФ): китайский турист с китайским
> VPN-сервисом, арендованным под китайский внутренний рынок (Alibaba Cloud /
> Tencent Cloud / другие CN-tier ASN), **может в РФ испытывать меньше проблем**,
> чем российский пользователь с русским VPN — потому что РКН не приоритизирует
> блокировку китайских VPN-серверов (это не «протестная инфраструктура для
> россиян»). Прогноз требует валидации, но логика приоритизации ASN — общая.
>
> **Практическое следствие для оператора:** если планируется делегирование
> доступа иностранному пользователю в РФ — иностранный VPN-сервис из его
> родного региона может быть оптимальнее «универсального» решения.

---

## Свежие удары (с 2026-05-01 по 2026-05-17)

| Дата | Событие | Источник | Влияние |
|---|---|---|---|
| 2026-05-02 | Массовые сбои домашнего интернета Москва+Подмосковье | Yahoo/Reuters (HIGH) | Перебои даже у whitelisted-сервисов |
| 2026-05-04..09 | Victory Day shutdowns: МТС, T2, Билайн, Yota в Москве и СПб; Билайн первый разослал SMS-предупреждения | Moscow Times (HIGH); Reuters (HIGH) | Рекомендовали использовать WiFi; ожидались сбои whitelisted-сервисов и SMS |

---

## Различия по операторам РФ-2026

| Оператор | Политика | Источник | Заметки |
|---|---|---|---|
| **МТС** | DPI + участие во всех мерах (Apple ID top-up off, 16 KB curtain) | Cloudflare blog HIGH; Meduza HIGH | Большой провайдер; все массовые меры применяются |
| **Мегафон** | DPI + участие во всех мерах | Cloudflare blog HIGH; Meduza HIGH | Yota — MVNO Мегафона |
| **Билайн (Vimpelcom)** | DPI + участие; **CEO Sergey Anokhin (осень 2025) — инициатор концепции white-list** | RIDL HIGH; Meduza HIGH | Первый рассылает SMS-предупреждения о shutdowns |
| **T2 (бывший Tele2)** | DPI + участие во всех мерах | Meduza HIGH | T2 = бывший Tele2 после ребрендинга |
| **Yota** | Через инфраструктуру Мегафона; отдельной политики не документировано | Moscow Times (упомянут в 5-9 мая 2026) | MVNO Мегафона |
| **Ростелеком (мобильный/MVNO)** | Через T2-инфраструктуру | Cloudflare blog HIGH (как ASN-уровень 16 KB) | Ростелеком как мобильный — через T2 |
| **Ростелеком (домашний/фиксированный)** | TSPU + 16 KB curtain | Cloudflare blog HIGH | Фиксированный (домашний) менее агрессивный по фильтрации, **но 16 KB curtain действует** |
| **МГТС (домашний)** | 16 KB curtain | Cloudflare blog HIGH | Внутри сети МТС |

**Общий вывод по операторам:**
- На уровне 16-KB curtain: единый механизм у Ростелеком, Мегафон, Билайн, МТС, МГТС.
- На уровне платформы: единые «большая четвёрка» (МТС, Мегафон, Билайн, T2) выполняют решения Минцифры синхронно.
- **Индивидуальных различий в технике DPI / white-list между этими 4 операторами не документировано** (HIGH).

---

## Региональные различия

| Регион | Заметки | Источник |
|---|---|---|
| **Москва, СПб** | Наиболее интенсивные ограничения; почти 3 недели shutdowns мобильного в центре Москвы в марте 2026 (по приказу ФСБ); Victory Day shutdowns 5-9 мая 2026 | ZONA HIGH; Reuters HIGH |
| **57 регионов РФ** | Включены в white-list-deployment по состоянию на март 2024 | reclaimthenet HIGH |
| **Краснодарский край** | Telegram продолжает работать без VPN (в отличие от Москвы, где недоступен) | Moscow Times MEDIUM |
| **Татарстан** | ❓ Уточнить (отдельной фактуры в собранных источниках нет; не подтверждено: 2026-05-17) |
| **Другие регионы (Дагестан, Урал, Сибирь, ДВ)** | ❓ Уточнить — данных нет; известно общее «большинство регионов испытывают ежедневные сбои» (Moscow Times MEDIUM) |

---

## Конкретные стратегии — что выбрать СЕГОДНЯ

| Сценарий | Рекомендация | Запасной | Confidence |
|---|---|---|---|
| Wi-Fi домашний (любой ISP) | VLESS+Reality (dest=microsoft.com или dl.google.com) на своём загр.VPS | XHTTP за реальным Nginx с Let's Encrypt | HIGH |
| Мобильный (МТС/Мегафон/Билайн/T2) | Multi-hop через RU-VPS → загр.VPS; или AmneziaWG 2.0 напрямую | XHTTP за Cloudflare (с оговоркой 16-KB curtain) | MEDIUM |
| Корпоративный (white-listed) | Только белый IP в реестре РКН | — (только legal путь) | HIGH |
| Доступ к российским платформам с VPN | Отключать VPN для Sber/Yandex/VK/Ozon/WB/Госуслуг/РЖД/Aviasales | Split-tunneling с geosite:category-ru → direct | HIGH |
| iOS-клиент | **Happ** (основной, happ.su) — ставить через смену региона App Store (в RU App Store на 2026-05-24 нет ни Happ, ни Hiddify) | Hiddify / Karing (тоже через смену региона) | HIGH (клиент); MEDIUM (статус стора — наблюдение, меняется волнами) |
| Anthropic/OpenAI API с сервера в РФ | `/setup-server-proxy` через свой загр.VPS | — | HIGH (см. также `setup-server-proxy` скилл) |

---

## Открытые вопросы (требуют уточнения)

- ❓ **Конкретные ASN/IP-диапазоны в whitelist 75 000 IP** — РКН не публикует. (не подтверждено: 2026-05-17)
- ❓ **Точная процедура подачи заявки бизнесом на whitelist** — описано общо, пошаговой инструкции в открытых источниках нет.
- ❓ **Расхождение цифр 75 000 vs 57 000 IP** (total whitelist vs corporate subset) — см. `_meta/conflicts.md`.
- ❓ **Конкретный gfw.report отчёт 2026 по статусу SS в Китае** — нужен для калибровки SS в РФ.
- ❓ **Прямой источник «разница в active probing для SS DC-to-DC vs клиент-сервер»** — наблюдение оператора, нужно подтверждение.
- ❓ **Эпизодические фейлы Reality с serverName=cloudflare.com в Татарстане/Самарской области** — упомянуто в чужой сессии разговора, в собранных источниках не подтверждено.
- ❓ **Точная Xray-версия, в которой добавлен XHTTP (XHTTP консолидация от SplitHTTP)** — v24.9.30 подтверждено; точные предыстория (v24.x с SplitHTTP) — см. `_reference/transports.md`.

---

## Источники

См. `sources_checked` во frontmatter. Веса источников и правила использования — `_meta/sources-registry.md`. Зафиксированные противоречия — `_meta/conflicts.md`.
