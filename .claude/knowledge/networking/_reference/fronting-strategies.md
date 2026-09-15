---
knowledge_domain: vpn
layer: reference
last_researched: 2026-08-11
ttl_days: 60
sources_checked:
  - https://blog.cloudflare.com/russian-internet-users-are-unable-to-access-the-open-internet/
  - https://developers.cloudflare.com/support/troubleshooting/general-troubleshooting/service-disruption/
  - https://en.zona.media/article/2025/06/19/cloudflare
  - https://en.zona.media/article/2025/06/27/cloud_confirmed
  - https://en.zona.media/article/2026/04/07/russian_internet_censorship_2026
  - https://therecord.media/cloudflare-russia-restricting-access-crackdown
  - https://blog.cloudflare.com/2026-threat-report/
  - https://habr.com/en/articles/990542/
  - https://www.vpndada.com/bypass-internet-censorship-with-vless-cloudflare-warp/
  - https://xtls.github.io/en/document/level-2/warp.html
  - https://nvovpn.com/en/news/besplatnyi-vpn-v-2026-kakie-realno-rabotaiut-i-cem-riskuete
  - https://www.ioriver.io/blog/cloudflare-cdn-alternatives
  - https://bunny.net/vs/keycdn/
  - https://www.cdn07.com/en/global-top-50-cdn-providers-analysis
  - https://github.com/XTLS/REALITY/blob/main/README.en.md
  - https://habr.com/ru/articles/1044396/
  - https://habr.com/ru/articles/1047442/
  - https://ebyebots.ru/blog/rkn-«polozhil»-runet-massovyj-sboj-sajtov-na-hostingah-beget-timeweb-selectel-i-spaceweb-iz-za-obnovleniya-nastroek-tspu/
---

# Fronting-стратегии: маскировка под легитимный трафик

Этот документ — про стратегии **«маскировка под легитимный трафик»**: как сделать
так, чтобы VPN-сервер выглядел снаружи как обычный сайт, CDN-узел, или вообще
не отдельная сущность. Покрывает: Cloudflare-fronting, альтернативные CDN,
Cloudflare WARP, Reality+fallback, host fronting, uTLS, и опыт иранского/китайского
комьюнити (это они выработали большую часть рабочих паттернов).

Связан с `_reference/transports.md` (там — про сами транспорты), `_reference/vpn-protocols.md`
(про сами протоколы), `_live/frontline-ru.md` (текущий статус блокировок).

---

## §1 Зачем fronting

Цензор работает на трёх уровнях. Fronting помогает на 1-м и 2-м:

| Уровень блокировки | Что делает цензор | Что помогает |
|---|---|---|
| **1. DPI (анализ содержимого)** | Распознаёт сигнатуры протоколов, fingerprint TLS | Маскировка протокола, uTLS fingerprint, Reality |
| **2. IP-блокировка** | Блокирует конкретные адреса, а также подсети и целые AS по репутации (частный случай — сноска ниже) | Прятать сервер за инфраструктурой популярного CDN + выбирать хостинг по репутации AS |
| **3. Белые списки** | Пускает только в одобренные IP | Прятать сервер **внутри** одобренного списка (CF Workers, ArvanCloud для Ирана) |

**Важно:** fronting лечит DPI и IP-блокировку, но **не лечит белые списки**, если
ваш fronting-IP в них не входит. Это главный риск в РФ-2026 для мобильных
операторов: их white-list содержит ~500 сервисов, Cloudflare-IP туда не входят.

**Сноска к уровню 2 — РФ, с июня 2026 (частный случай, не общее правило):** ТСПУ
оценивает не отдельные адреса, а репутацию подсети и автономной системы целиком;
затронуты в том числе российские дата-центры (Selectel, Яндекс.Облако, Cloud.ru),
ограничение применяется одинаково на мобильных и домашних провайдерах. Следствие:
выбор хостинга (AS) стал самостоятельным фактором наравне с маскировкой за CDN
(MEDIUM: [Habr 1044396](https://habr.com/ru/articles/1044396/), 2026-06-06 —
наблюдения комьюнити, не спецификация ТСПУ; MEDIUM: [ebyebots](https://ebyebots.ru/blog/rkn-«polozhil»-runet-massovyj-sboj-sajtov-na-hostingah-beget-timeweb-selectel-i-spaceweb-iz-za-obnovleniya-nastroek-tspu/),
2026-06-05 — массовый сбой сайтов на хостингах Beget, TimeWeb, Selectel,
SpaceWeb из-за обновления настроек ТСПУ: независимое подтверждение того, что
фильтрация прилетает по хостингу целиком, а не по отдельным адресам).

---

## §2 Cloudflare fronting

### 2.1 Базовая идея

Ваш VPN-сервер (Xray, sing-box) **сидит за Cloudflare** как proxy. Снаружи:

- Cloudflare видит обычный HTTPS на свой IP
- Ваш origin виден только Cloudflare-у (через CF Tunnel или просто proxy)
- ТСПУ видит TLS-соединение к одному из миллионов IP Cloudflare

Заблокировать **отдельный IP вашего сервера** становится бессмысленно — он скрыт.
Заблокировать **весь Cloudflare** = обрушить миллионы легитимных сайтов.

### 2.2 Статус в РФ-2026 (КРИТИЧНО)

**С 9 июня 2025** Cloudflare-трафик в РФ **систематически дросселируется**:

> «ISPs within Russia are systematically throttling traffic to websites and services
> that rely on Cloudflare. ISPs are capping data transfers at just 16 kilobytes per
> request, rendering most websites nearly unusable.»
> — [Cloudflare blog, 2025-06-09](https://blog.cloudflare.com/russian-internet-users-are-unable-to-access-the-open-internet/) HIGH

Подтверждается в [Cloudflare Support Docs](https://developers.cloudflare.com/support/troubleshooting/general-troubleshooting/service-disruption/)
— официальный support-документ, не только blog.

**Что это значит для fronting в РФ-2026:**

- ✅ TLS handshake к CF проходит (handshake укладывается в 16 KB)
- ❌ Любая полезная нагрузка — обрезается на ~16 KB
- ❌ HTTP/3/QUIC — тоже under curtain
- 🟡 **Cloudflare-fronting в РФ практически непригоден для трафика >16 KB на
  запрос** = это значит непригоден почти ни для чего, кроме коротких API-вызовов

**Кому ещё пригоден CF-fronting:**
- Пользователи из **стран без 16-KB curtain** (любая некроссграничная локация)
- Корпоративные пользователи внутри РФ, которые попали в whitelist
- **Wi-Fi домашний vs мобильный** в РФ: мобильные white-list-блокировки CF не пускают, домашний — пускает но дросселирует. WiFi немного лучше, но всё равно curtain.

### 2.3 Cloudflare Workers

Cloudflare Workers — serverless runtime на edge. Можно сделать VPN-proxy внутри Workers, выходящий за CDN.

**Поддерживаемые transport для Workers** (HIGH: Xray discussion #2950):
- ✅ WebSocket
- ❌ HTTPUpgrade
- ❌ XHTTP (не поддерживается в общем случае, требует кастомных адаптеров)

Workers — **тот же CF**, тот же curtain в РФ-2026. Для РФ-задачи не лучше базовой CF.

### 2.4 White-list 75k IP и Cloudflare

❓ Cloudflare-IP в white-list 75k — **не подтверждено** (не уточнено: 2026-05-17).
РКН не публикует состав. Но логика «whitelist для корпоративных VPN» подразумевает,
что туда попадают IP, **поданные конкретными бизнесами с обоснованием**. Случайный
Cloudflare-IP — не подаётся.

---

## §3 Альтернативные CDN

Если Cloudflare уязвим — какие другие? Сравнительная таблица 2026:

| CDN | Free | Цена / GB | PoPs | Статус в РФ-2026 | Source |
|---|---|---|---|---|---|
| **Cloudflare** | ✅ | $0 (free) | 300+ | 🔴 16-KB curtain с 09.06.2025 | Cloudflare blog (HIGH) |
| **Bunny.net** | Trial | $0.01 | ~120 | ❓ Уточнить, нет данных по curtain | ioriver, bunny.net (MEDIUM) |
| **Fastly** | ❌ | $0.12 | ~100 | ❓ Уточнить | fastly blog (LOW — vendor) |
| **KeyCDN** | ❌ | $0.04 | ~50 | ❓ Уточнить | bunny.net comparison (MEDIUM) |
| **Akamai** | ❌ | Enterprise | 360k+ edge | ❓ Не использовался для VPN-fronting | inmotionhosting (LOW) |
| **AWS CloudFront** | Trial | $0.085 | ~400 | ❓ Уточнить, в РФ-2026 — AWS отозвал многих | cdn07 (MEDIUM) |
| **ArvanCloud (Iran)** | — | Iran-specific | Iran | ⚠️ Iran-only; в РФ — BGP-маршрут через Beeline (Cyberwarzone: «sanctions evasion pipeline») | cyberwarzone (MEDIUM) |
| **Alibaba CDN** | ❌ | China-tier | 2800+ (mostly China) | ❓ Не использовался для VPN-fronting на Запад | cdn07 (MEDIUM) |

### 3.1 Bunny.net как кандидат

[Bunny.net](https://bunny.net/) — словенский CDN, $0.01/GB (один из дешевейших).

**Плюсы:**
- Не в фокусе РКН (пока)
- Поддерживает WebSocket
- Дешевле CF Workers

**Минусы:**
- ❓ Нет подтверждённых данных о статусе в РФ-2026 (не подтверждено: 2026-05-17)
- Меньше PoPs (~120 vs CF 300+)
- ToS на VPN — формально запрещено, но enforcement мягкий

### 3.2 Fastly

[Fastly](https://www.fastly.com/) — премиальный edge CDN, $0.12/GB.

- ✅ Sophisticated edge compute (Varnish Configuration Language)
- ❌ Дорого
- ❓ Статус в РФ — нужно подтверждение замером (не подтверждено: 2026-05-17)

### 3.3 ArvanCloud (иранский CDN) — особый случай

Иранский CDN, в основном для иранского рынка. Cyberwarzone (MEDIUM) обнаружили
**BGP-маршрут**: ArvanCloud → VimpelCom (Beeline в РФ) → Yandex infrastructure.

**Что это значит:**
- Для иранского трафика через ArvanCloud — путь идёт через РФ.
- Использовать ArvanCloud как fronting для РФ-обхода — **не имеет смысла** (он
  специализирован под Иран, на Запад идёт окольно).

---

## §4 Cloudflare WARP как outbound

WARP — VPN-сервис от Cloudflare на базе WireGuard. **Бесплатный** для персональных
пользователей. Не fronting в строгом смысле, но **полезный outbound** для своего
Xray-сервера.

### 4.1 Архитектура

```
Клиент → ваш VPS (Xray inbound) → WARP outbound → интернет
                                    (WireGuard к engage.cloudflareclient.com)
```

Зачем:
- ✅ **Anti-AI-blocking:** многие AI-сервисы (Anthropic, OpenAI) блокируют VPS-IP. WARP даёт CF-IP, который выглядит как обычный пользовательский.
- ✅ **Дополнительная защита от blacklisting** вашего VPS-IP западными сервисами.
- ✅ **Обход «не любит запросы из РФ»** — WARP-IP не выглядит как «российский».

### 4.2 Статус WARP в РФ-2026

**WARP из РФ напрямую — не работает** (NVOVPN MEDIUM):
- WARP не меняет регион — вы остаётесь «из РФ»
- YouTube заблокирован РКН? WARP не помогает
- Это **outbound** для VPS, **не клиентский VPN** для РФ

### 4.3 Конфигурация в Xray (официальная)

HIGH: [xtls.github.io/document/level-2/warp](https://xtls.github.io/en/document/level-2/warp.html)

```jsonc
{
  "outbounds": [
    {
      "protocol": "wireguard",
      "settings": {
        "secretKey": "My_Private_Key",
        "peers": [
          {
            "publicKey": "Warp_Public_Key",
            "endpoint": "engage.cloudflareclient.com:2408"
          }
        ],
        "reserved": [0, 0, 0]
      }
    }
  ]
}
```

WARP secret keys получаются через `warp-cli` на сервере, затем переносятся в Xray-конфиг.

### 4.4 Известные проблемы (VPNDada troubleshooting)

| Симптом | Причина | Решение |
|---|---|---|
| WARP подключён, но AI всё равно блокирует | WARP-IP попал в blocklist | `warp-cli disconnect && warp-cli connect` — получить новый CF-IP |
| Работает для одних сайтов, не для других | Домен не в routing rules | Добавить домен в warp-out domain list в config.json, перезапустить Xray |
| Высокая latency | VPS далеко от вас | Выбрать VPS ближе к локации |
| После reboot WARP не работает | WARP не reconnect-нулся | `systemctl status warp-svc`, добавить в startup |

### 4.5 Когда брать WARP outbound

- ✅ Если ваш VPS-IP попадает в blocklist западных AI-сервисов
- ✅ Как «дополнительный hop» для anonymity
- ❌ Не для замены VPN-серверу — это **outbound**, не **inbound**

---

## §5 Reality + fallback to real site

Reality сам по себе — **встроенная fronting-стратегия** на TLS-уровне.

### 5.1 Как работает Reality fallback

См. `_reference/transports.md` §13 для детального разбора. Кратко:

1. Клиент инициирует TLS handshake к вашему серверу (sees handshake к, например, `www.microsoft.com`)
2. Сервер Reality перехватывает handshake
3. Если у клиента **правильный** pubkey/shortId — соединение переключается на VPN
4. Если **нет** (или это вообще не Reality-клиент — например, активное probing цензора) — сервер **проксирует на реальный microsoft.com**, который видит легитимный TLS handshake и отдаёт реальный сертификат

Цензор при active probing получает **настоящий ответ от Microsoft** — никакого индикатора VPN.

### 5.2 Выбор `dest`/`serverName` в РФ-2026

См. `_reference/transports.md` §13.2. Кратко:

- ❌ **НЕ Cloudflare** (16-KB curtain + он становится port-forward для CF)
- ❌ **НЕ Yandex / Google** в РФ (имеют локальный CDN — соединение к **локальному** IP, а вы реально соединяетесь с зарубежным = mismatch)
- ✅ **Microsoft** (с 2022 без CDN в РФ): `www.microsoft.com`, `update.microsoft.com`
- ✅ **GitHub**: `github.com`, `objects.githubusercontent.com`
- ✅ **Apple**: `www.apple.com`, `swdist.apple.com`

### 5.3 Reality как «нативный fronting» — главное преимущество

Reality **не требует своего домена и своего сертификата**. Просто **паразитирует**
на репутации donor-сайта. Это уникальная фишка vs всех остальных fronting-стратегий
(которые требуют свой домен + LE-сертификат).

---

## §6 uTLS fingerprint (TLS-уровневый fronting)

Когда ваш клиент посылает TLS ClientHello — у него есть **fingerprint** (JA3/JA4):
порядок cipher-suites, расширения, эллиптические кривые, etc.

Без uTLS — Xray/sing-box использует Go stdlib `crypto/tls` → fingerprint = «Go».
DPI может различить: «это не Chrome/Firefox, это какая-то библиотека = подозрительно».

**uTLS** имитирует fingerprint реального браузера. Параметр `fingerprint` в Reality
и других protocols:

- `"chrome"` — default; имитирует актуальный Chrome (⚠️ для РФ-2026 подозрителен —
  см. рекомендацию ниже)
- `"firefox"` — Firefox
- `"safari"` — Safari
- `"edge"` — Edge (новее Chrome-варианта)
- `"random"` / `"randomized"` — каждое соединение — новый fingerprint
- ⚠️ `"chrome_pq"` — **СЛОМАН** с VLESS+XTLS-REALITY (sing-box #2084, Xray #4852)

**Рекомендация для РФ-2026 (пересмотрено 2026-08-11):** `firefox` или `edge`.
С июня 2026 ТСПУ относит к подозрительным отпечатки `chrome`, `safari`, `ios`;
`firefox`, `edge`, Android OkHttp у большинства операторов пока проходят
(MEDIUM: [Habr 1044396](https://habr.com/ru/articles/1044396/) от 2026-06-06,
апдейт от 2026-06-16 — наблюдения комьюнити, не спецификация ТСПУ). Само
разделение отпечатков подтверждено только этой статьёй, второго источника
на него нет. Апдейт от 2026-06-16, судя по тексту статьи, убрал «длинную
заморозку» на 10 минут — поэтому цифра 600 с в файл сознательно не внесена:
источник её отозвал, а независимого подтверждения нет.

Отпечаток сам по себе блокировку не даёт — он одно из условий связки
«подозрительная подсеть/AS + подозрительный отпечаток + более 3 параллельных
TLS-хендшейков к одному SNI за 60 с»; штраф — заморозка соединений на 120 с
(MEDIUM: [Habr 1047442](https://habr.com/ru/articles/1047442/) от 2026-06-15 —
наблюдения комьюнити, не спецификация ТСПУ).
`random` больше не нейтральный выбор: гарантии, что случайный профиль не
окажется chrome-подобным, нет, поэтому до следующей проверки фиксирую явный
`firefox`/`edge`. Менять отпечаток на лету, когда заморозка уже наступила,
не следует.

---

## §7 Иранская / китайская школа fronting

Иранское и китайское комьюнити **на 2-3 года опережают** РФ-сообщество в выработке
fronting-практик. Их наработки придут к нам.

### 7.1 Что выработали в Иране (актуально для РФ)

- **XHTTP за реальным Nginx** на TLS 1.2 (обход TLS 1.3 throttling)
- **Reality с правильным donor** (Microsoft, GitHub — без локального CDN)
- **Hysteria2 с masquerade под HTTPS-сервер** (mode `proxy` upstream на legitimate site)
- **WARP outbound** для anti-AI-blocking
- **Multi-hop через множественные ASN** (Iran → Turkey → Western)

См. [Habr 990542](https://habr.com/en/articles/990542/) — полный туториал по VLESS+WARP+Reality на основе иранской школы.

### 7.2 Что в Китае (опережает РФ)

- **GFW активно блокирует XHTTP с 2025** — придёт в РФ в Q3-Q4 2026 (прогноз)
- **uTLS chrome_pq** — Китай уже сломал его как fingerprint (см. issue trackers)
- **CDN-rotation strategies** — клиенты rotate между несколькими CDN-серверами на лету

Подробнее — `_live/frontline-cn.md` и `_live/frontline-ir.md`.

---

## §8 DNS-уровень: новый аспект в РФ-2026

С февраля 2026 — **РКН удалил из NSDI (Национальная система доменных имён) домены
YouTube, Facebook, WhatsApp, крупные иностранные СМИ** (HIGH: Mediazona).

Mediazona проверила 10 000 самых популярных доменов от Cloudflare DNS — большая
часть удалённых доменов уже была заблокирована другими способами.

**Практический эффект пока ограничен:**
- 1.1.1.1 (Cloudflare DNS), 8.8.8.8 (Google DNS) — **остаются доступны** в РФ
- Пользователи могут переключиться на foreign DNS и обойти

**Но:** прогноз — следующая волна попытается блокировать сами foreign DNS.

**Контр-мера:** DoH/DoT (DNS over HTTPS/TLS). Сервер VPN должен сам резолвить
домены через шифрованный DNS, не полагаться на провайдерский.

---

## §9 Decision tree: какая стратегия под задачу

```
Цель: спрятать сервер за инфраструктурой популярного CDN
├── Бюджет $0 + готов на 16-KB curtain в РФ
│   └── Cloudflare Workers + WebSocket — но в РФ деградирует с 9.06.2025
├── Бюджет $0.01-0.04/GB + хочу нестандартного donor
│   └── Bunny.net + WebSocket (❓ статус в РФ — уточнить)
└── Цель — обойти 16-KB curtain в РФ
    └── XHTTP за СВОИМ Nginx с LE-сертификатом (НЕ за CDN); см. _reference/transports.md §3

Цель: спрятать VPN-протокол на TLS-уровне
├── Лучший выбор: VLESS+Reality+Vision+uTLS(firefox|edge) с donor=microsoft.com или github
└── Дополнительно: мультиплексирование — одно долгоживущее соединение вместо
    нескольких параллельных. С июня 2026 заморозку в РФ включает связка
    «более 3 параллельных TLS-хендшейков к одному SNI, идущих всплеском
    (~350-400 мс между хендшейками), в пределах 60 с» на подозрительной
    подсети (MEDIUM: Habr 1044396 от 2026-06-06, Habr 1047442 от 2026-06-15).
    Отпечаток при этом фиксируем firefox/edge (см. §6), менять его на лету
    во время активной заморозки не следует.

Цель: обойти blacklist VPS-IP западными AI-сервисами
└── WARP outbound в Xray (см. §4)

Цель: продержаться на iOS-клиенте
├── Hiddify или Karing (sing-box внутри) → Reality без Vision, WebSocket, HTTPUpgrade
└── НЕ XHTTP — sing-box не поддерживает

Цель: обойти DNS-блокировки в РФ
└── DoH/DoT на сервере VPN, fallback на foreign DNS (1.1.1.1, 8.8.8.8)
```

---

## §10 Связи

- `_reference/transports.md` §3 (XHTTP), §13 (Reality donor best practices)
- `_reference/vpn-protocols.md` §1.7 (VLESS+Reality)
- `_live/frontline-ru.md` §🔴 (Cloudflare curtain status)
- `_live/timeline.md` 2025-06-09 (старт 16-KB curtain)
- `_meta/conflicts.md` КОНФЛИКТ-003 (whitelist 75k vs 57k)
- `_live/frontline-cn.md` (что Китай блокирует первым → прогноз для РФ)
- `_live/frontline-ir.md` (иранский опыт fronting — арсенал-донор для РФ)
