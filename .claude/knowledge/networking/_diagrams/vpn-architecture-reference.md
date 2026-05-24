# Эталонная VPN-архитектура (домашний сценарий обхода блокировок, РФ-2026)

Схема «включил и забыл» — один тумблер в клиенте, дальше всё работает само.
Вся маршрутизация (что куда) — **на сервере**, клиент ничего не настраивает.

---

## Главная схема — что куда идёт (split на сервере)

```mermaid
flowchart TD
    Phone["📱 Твоё устройство<br/>(iPhone / Mac / PC / Android)<br/><br/>📲 любой клиент:<br/>Hiddify · Happ · Karing · SFA<br/><br/>гонит ВЕСЬ трафик на сервер"]

    Phone -->|"Весь системный трафик<br/>(TUN-режим включён)"| RuVPS

    subgraph Server["🇷🇺 Твой VPS в России (3X-UI, ядро Xray)"]
      Router{"🎯 Routing на сервере<br/>смотрит на каждый запрос<br/>и решает куда отправить"}
      Router -->|"🟢 geoip:ru / *.ru /<br/>sber.ru, gosuslugi.ru, vk.com"| Direct
      Router -->|"🚫 реклама/трекеры<br/>(geosite:category-ads-all)"| Block["⛔ block"]
      Router -->|"🔵 youtube, chatgpt,<br/>github, всё остальное"| Up["⬆️ outbound upstream"]
    end

    RuVPS["вход: VLESS-TCP inbound"] --> Router

    Direct["☁️ outbound direct<br/>(с IP сервера, РФ)<br/><br/>🔒 РФ-сайт видит российский IP<br/>сервера — не банит"]

    Up --> Provider["🌍 Подписка VPN-провайдера<br/>(Blanc / AmneziaPremium / др.)<br/>или свой загр.VPS"]

    Provider --> World["🌐 Свободный интернет"]
    Direct --> WorldRu["🇷🇺 Российский интернет"]

    classDef ru fill:#ffe5e5,stroke:#cc0000,color:#000
    classDef directStyle fill:#e5ffe5,stroke:#00aa00,color:#000
    classDef vpn fill:#e5f3ff,stroke:#0066cc,color:#000
    classDef world fill:#fff5e5,stroke:#cc7700,color:#000

    class Phone,RuVPS,Router ru
    class Direct,WorldRu directStyle
    class Up,Provider vpn
    class World world
```

**Главная идея:**
- Клиент на устройстве гонит **весь** трафик на твой РФ-сервер — он ничего не решает сам
- **Сервер** разбирает: РФ-сайты → direct (с IP сервера), реклама → block, остальное → через провайдера в свободный интернет
- Ты настраиваешь правила **один раз на сервере**; на всех устройствах достаточно подписки и тумблера

> ⚠️ Раньше split рисовался **на клиенте** (Hiddify решает куда). Это не
> заработало на практике — Hiddify не исполняет произвольные правила. Новый
> дефолт — split на сервере (`_reference/routing-server-3xui.md`).
>
> 📡 Цена: РФ-трафик делает лишний hop через сервер (+10-20 мс) и выходит с IP
> сервера, а не домашним. Для Госуслуг/Сбера это ок. Прямой выход РФ-трафика —
> только при on-device split (для энтузиастов, `_reference/routing-on-device-singbox.md`).

---

## Зачем «крюк» через свой РФ-сервер?

Логичный вопрос: зачем городить «устройство → РФ-сервер → провайдер → интернет», если можно сразу «устройство → провайдер → интернет»?

```mermaid
flowchart LR
    subgraph WithoutRu["❌ Без РФ-сервера (плохо)"]
        Phone1["📱 Устройство<br/>в России"]
        Phone1 -->|"VPN-handshake<br/>через границу"| Prov1["🌍 VPN-провайдер<br/>за границей"]
        Prov1 --> Net1["🌐 интернет"]

        Note1["🚨 ТСПУ видит<br/>VPN-трафик<br/>пересекающий границу<br/>→ режет / троттлит"]
        Phone1 -.->|"наблюдает"| Note1
    end

    subgraph WithRu["✅ С РФ-сервером (правильно)"]
        Phone2["📱 Устройство<br/>в России"]
        Phone2 -->|"трафик ВНУТРИ РФ<br/>(ТСПУ не палит)"| RuS["🇷🇺 Твой РФ-VPS"]
        RuS -->|"трафик между серверами<br/>(B2B - режется мягче)"| Prov2["🌍 VPN-провайдер"]
        Prov2 --> Net2["🌐 интернет"]
    end

    classDef bad fill:#ffe5e5,stroke:#cc0000,color:#000
    classDef good fill:#e5ffe5,stroke:#00aa00,color:#000

    class Phone1,Prov1,Net1,Note1 bad
    class Phone2,RuS,Prov2,Net2 good
```

**Слева (плохо):** VPN-handshake пересекает границу РФ → ТСПУ это видит → начинает резать или дросселировать.

**Справа (правильно):** трафик от тебя до своего РФ-VPS идёт **внутри РФ** — ТСПУ к таким маршрутам относится мягко. Дальше с РФ-VPS идёт «B2B-трафик между серверами», который тоже под более мягкой фильтрацией. Получаем стабильное соединение.

Это и есть смысл «крюка» — обход агрессивной фильтрации трансграничного VPN-трафика.

---

## TUN-режим — почему ВСЁ работает, а не только браузер

```mermaid
flowchart TD
    subgraph BadMode["❌ Старый режим: SOCKS5-прокси"]
        App1A["🌐 Браузер"] -.->|"знает про прокси,<br/>идёт через Hiddify"| H1["Hiddify"]
        App2A["💻 VSCode"] -.->|"НЕ знает про прокси,<br/>идёт МИМО Hiddify"| Net1["напрямую в интернет<br/>🚨 заблокировано"]
        App3A["📨 Telegram"] -.->|"идёт мимо"| Net1
        App4A["🛠 curl/git"] -.->|"иногда идёт мимо"| Net1
        H1 --> NetGood1["через VPN<br/>✅ работает"]
    end

    subgraph GoodMode["✅ TUN-режим: всё через VPN"]
        App1B["🌐 Браузер"] --> Tun["TUN<br/>(виртуальный<br/>сетевой адаптер)"]
        App2B["💻 VSCode"] --> Tun
        App3B["📨 Telegram"] --> Tun
        App4B["🛠 curl/git"] --> Tun
        App5B["🎵 Spotify"] --> Tun
        Tun --> H2["Hiddify"]
        H2 --> NetGood2["через VPN<br/>✅ все приложения работают"]
    end

    classDef bad fill:#ffe5e5,stroke:#cc0000,color:#000
    classDef good fill:#e5ffe5,stroke:#00aa00,color:#000

    class App1A,App2A,App3A,App4A,H1,Net1 bad
    class App1B,App2B,App3B,App4B,App5B,Tun,H2,NetGood2 good
```

**В чём проблема старого режима SOCKS5:**
- Hiddify запускает локальный «прокси» на `127.0.0.1:1080`
- Браузер знает что есть системный прокси → идёт через него
- VSCode, Telegram desktop, Spotify, curl → **не знают** что есть прокси → идут напрямую → попадают под блокировки

**Как лечит TUN:**
- TUN — это **виртуальный сетевой адаптер** в твоей системе
- Когда он включён, операционная система отправляет **ВЕСЬ исходящий трафик** через него
- Hiddify забирает всё что попадает в TUN и пропускает через свою маршрутизацию
- Приложения ничего не знают и не подозревают — они просто отправляют пакеты, а ядро ОС всё перенаправляет

**Default — только TUN.** SOCKS5-режим не используем.

---

## Опциональное расширение А: отдельный outbound для AI

Если хочешь чтобы Claude/ChatGPT/Perplexity видели **только твой персональный IP** (не shared с другими клиентами Blanc, не «грязный» от чужих ботов) — добавляешь второй outbound на свой собственный заграничный VPS.

Это требует:
- Свой загр.VPS (~800-1500₽/мес)
- Установить на нём вторую панель 3X-UI (это сделает агент-сисадмин)
- В РФ-панели добавить второй outbound на свой загр.VPS
- В правилах: AI-домены → этот личный outbound, остальное → подписка провайдера

```mermaid
flowchart TD
    Phone["📱 Устройство<br/>(любой клиент, весь трафик → сервер)"]
    Phone --> Router

    subgraph RuVPS["🇷🇺 Твой РФ-VPS (3X-UI)"]
      Router{"🎯 Routing на сервере"}
      Router -->|"🟢 РФ-сайты"| Direct["outbound direct"]
      Router -->|"🤖 AI-домены<br/>(chatgpt, claude, perplexity)"| ToMyVPS["⬆️ outbound: личный загр.VPS"]
      Router -->|"🔵 всё остальное"| ToProv["⬆️ outbound: подписка"]
    end

    ToMyVPS --> MyVPS["🌍 Твой ЛИЧНЫЙ загр.VPS<br/>(3X-UI)<br/>📌 чистый IP только для тебя"]
    ToProv --> Provider["🌍 Подписка провайдера<br/>(shared IP)"]

    MyVPS --> AI["🤖 ChatGPT / Claude"]
    Provider --> Net["🌐 интернет"]
    Direct --> NetRu["🇷🇺 РФ-интернет"]

    classDef ru fill:#ffe5e5,stroke:#cc0000,color:#000
    classDef ai fill:#fff5e5,stroke:#cc7700,color:#000
    classDef vpn fill:#e5f3ff,stroke:#0066cc,color:#000

    class Phone,Router,Direct,NetRu ru
    class MyVPS,AI ai
    class ToProv,Provider,ToMyVPS vpn
```

**Когда нужно:**
- У тебя несколько аккаунтов AI и есть опасение что они «слипнутся» по shared IP
- AI начали тебя банить (но обычно причина не в IP)

**Когда НЕ нужно:**
- Стандартный сценарий — это избыточно
- В большинстве случаев достаточно подписки провайдера

---

## Опциональное расширение Б: вообще без подписки провайдера

Если хочешь **полную независимость** от платных VPN-провайдеров и согласен сам админить — можно вместо подписки поставить свой второй сервер за границей. Тогда не платишь провайдеру вообще, только за два VPS (РФ + заграница).

```mermaid
flowchart TD
    Phone["📱 Устройство<br/>(любой клиент, весь трафик → сервер)"]
    Phone --> Router

    subgraph RuVPS["🇷🇺 Твой РФ-VPS (3X-UI)"]
      Router{"🎯 Routing на сервере"}
      Router -->|"🟢 РФ-сайты"| Direct["outbound direct"]
      Router -->|"🔵 всё остальное"| ToForeign["⬆️ outbound: свой загр.VPS"]
    end

    ToForeign --> MyForeignVPS["🌍 Твой ВТОРОЙ VPS<br/>за границей (тоже 3X-UI)<br/>📌 ты сам админ<br/>📌 нет провайдера-посредника"]

    MyForeignVPS --> Net["🌐 интернет"]
    Direct --> NetRu["🇷🇺 РФ-интернет"]

    classDef ru fill:#ffe5e5,stroke:#cc0000,color:#000
    classDef self fill:#fff5e5,stroke:#cc7700,color:#000
    classDef inet fill:#e5ffe5,stroke:#00aa00,color:#000

    class Phone,Router,Direct,NetRu ru
    class MyForeignVPS,ToForeign self
    class Net inet
```

**📌 Что это значит на практике:**
- Платишь только за **два своих VPS** (РФ ~300₽/мес + заграница ~800-1500₽/мес = 1100-1800₽/мес)
- НЕ платишь VPN-провайдеру отдельно
- Полная privacy — никакой третьей стороны не видит твой трафик
- НО **админить оба сервера придётся самостоятельно** (с помощью агента-сисадмина):
  - Обновления панели 3X-UI на обоих
  - Следить за «грязностью» IP загр.VPS (если попал в blocklist Anthropic — менять)
  - Ротировать ключи Reality раз в несколько месяцев
  - Когда меняются правила блокировок РКН — переконфигурировать
- VPN-провайдер всё это делает **за тебя**. Свой сервер = больше контроля, но больше работы

**Когда выбирать этот путь:**
- Готов разобраться и взять на себя поддержку (агент-сисадмин помогает, но решения принимаешь ты)
- Хочешь полную приватность от провайдеров
- В долгосроке экономишь (провайдер 500-700₽/мес × 12 = 6000-8400₽/год, второй VPS 800-1500₽/мес × 12 = 9600-18000₽/год — выходит **дороже** в краткосроке, но без зависимости от третьей стороны)

**Когда НЕ выбирать:**
- Новичок — лучше начать с подписки провайдера, потом мигрировать если захочется
- Не хочешь думать про администрирование вообще
- Хочешь чтобы поломки решал не ты, а саппорт провайдера

---

*Связи:*
- *Сценарий консультации (hub) → `_reference/vpn-consultation-flow.md`*
- *Маршрутизация на сервере (дефолт) → `_reference/routing-server-3xui.md`*
- *Маршрутизация on-device → `_reference/routing-on-device-singbox.md`, `_reference/routing-on-device-xray.md`*
- *Технические детали протоколов → `_reference/vpn-protocols.md`*
- *Транспорты и fronting → `_reference/transports.md`, `_reference/fronting-strategies.md`*
- *Фронт блокировок РФ → `_live/frontline-ru.md`*
