# АРХИВ: правила маршрутизации на клиенте через Hiddify (модель отменена 2026-05-22)

> ⚠️ **Это не действующее знание.** Модель «гибкая маршрутизация на клиенте через
> Hiddify» отменена 22.05.2026: Hiddify не исполняет произвольные raw route-правила,
> он строит конфиг из подписки сам. Действующий дефолт — маршрутизация **на сервере**
> (`../_reference/routing-server-3xui.md`), клиентская — через sing-box
> (`../_reference/routing-on-device-singbox.md`).
>
> Синтаксис ниже — **sing-box**, а 3X-UI работает на Xray: это разные языки правил.
> Копировать отсюда в действующий конфиг нельзя.

**Почему файл существует.** До 05.08.2026 этот текст лежал внутри
`_reference/vpn-consultation-flow.md`, обёрнутый в HTML-комментарий. Комментарий прячет
текст от **рендера**, но агент читает **сырой файл** — 102 строки попадали в контекст
целиком и противоречили действующей модели, изложенной в том же документе. Плюс
оглавление врало: заголовки `### 6.5`-`### 6.8` были видны при обзоре структуры, а
разделов за ними не было.

Удалять не стали (история в git — не то же, что доступный текст), но и держать в рабочем
файле нельзя. Вынесено сюда, в слой `_archive/`, который **не входит в модель трёх слоёв
ADR-0006**, не имеет TTL и не подлежит актуализации.

**Что здесь ценного:** явный список российских доменов по категориям — банки, госуслуги,
маркетплейсы, контент, доставка, авто и работа, CDN. Он пригодится, если понадобится
собрать такой список заново; действующая версия живёт в
`../_reference/routing-server-3xui.md` §5 в синтаксисе Xray.

---

историческое содержимое §6.3-§6.8 (правила в sing-box-синтаксисе для Hiddify)
удалено 2026-05-22 при смене модели на server-side routing. Актуальные правила:
routing-server-3xui.md (Xray) и routing-on-device-singbox.md (sing-box). -->

**DNS: чего в базе нет, и это честный пробел.** Настройки резолвера для Xray **на
сервере** в базе знаний нет — ни в `routing-server-3xui.md`, ни где-либо ещё (проверено
поиском по всем файлам 05.08.2026). До этой даты здесь стояло «настраивается на сервере —
см. `routing-server-3xui.md`», и это отправляло читателя в файл, где о DNS нет ни строки.

Что в базе про DNS **есть**:
- зачем вообще DoH/DoT и блокируют ли резолверы в РФ — `fronting-strategies.md` §8;
- поля DNS в профиле клиента (`RemoteDNS*`, `DomesticDNS*`) —
  `happ-subscription-format.md` §4.1 и `client-apps.md`;
- разбор «российский сайт под VPN отдаёт капчу»: резолвинг ушёл к домашнему резолверу,
  маршрут — через зарубежный выход — `happ-subscription-format.md` §8;
- смена формата DNS в ядре sing-box 1.12 — `routing-on-device-singbox.md`.

```yaml
- domain: rzd.ru → direct
- domain: rzd-tour.ru → direct
- domain: aeroflot.ru → direct
- domain: aeroflot.com → direct
- domain: pochta.ru → direct

# IT-гиганты на не-.ru
- domain: yandex.com → direct
- domain: ya.ru → direct
- domain: vk.com → direct
- domain: max.app → direct
- domain: 2gis.com → direct
- domain: hh.io → direct

# Маркетплейсы
- domain: avito.ru → direct
- domain: ozon.ru → direct
- domain: ozon.com → direct
- domain: wildberries.ru → direct
- domain: wb.ru → direct
- domain: megamarket.ru → direct
- domain: sbermegamarket.ru → direct
- domain: lamoda.ru → direct
- domain: kuper.ru → direct  # бывший СберМаркет

# Контент
- domain: kinopoisk.ru → direct
- domain: ivi.ru → direct
- domain: start.ru → direct
- domain: okko.tv → direct
- domain: dzen.ru → direct

# Доставка/еда
- domain: delivery-club.ru → direct
- domain: yandex.eda → direct
- domain: samokat.ru → direct

# Auto/недвига/работа
- domain: drom.ru → direct
- domain: auto.ru → direct
- domain: cian.ru → direct
- domain: hh.ru → direct
- domain: headhunter.ru → direct
- domain: youla.ru → direct

# API/CDN российских сервисов
- domain: appmetrica.yandex.net → direct
- domain: vk-cdn.net → direct
- domain: vk-portal.net → direct
```

**Этот список должен периодически обновляться** — добавляться новые сервисы.
Хранится в виде massive sing-box rule или импортируется как rule-set.

### 6.5 Уровень 5: блок рекламы и трекеров

```yaml
- domain: geosite:category-ads-all → block
```

**Что ловит:** глобальный список рекламы и трекеров (Google Ads, DoubleClick,
Facebook Pixel, российские рекламные сети).

**Бонус:** ускоряет загрузку сайтов и экономит трафик.

### 6.6 Default правило

```yaml
- (всё что не подошло выше) → proxy (через РФ-сервер)
```

### 6.7 Порядок правил критичен

**В sing-box правила выполняются сверху вниз. Первое совпавшее применяется.** Поэтому
порядок:

1. `geoip:private → direct` (локальная сеть, безусловно)
2. `geosite:category-ads-all → block` (реклама — раньше всего)
3. `geoip:ru → direct`
4. `geosite:category-ru → direct`
5. Regex по .ru/.su/.рф → direct
6. Явный список российских .com/.io доменов → direct
7. Default → proxy

### 6.8 DNS-маршрутизация (защита от утечек)

В Hiddify (Settings → DNS):

```yaml
# Российские домены резолвятся через Yandex DNS (быстро, не утекает в Google)
- domain: regexp:.+\.(ru|su|рф)$ → 77.88.8.8
- domain: geosite:category-ru → 77.88.8.8

# Всё остальное через Cloudflare DoH (зашифровано, провайдер не видит DNS)
- (default) → https://1.1.1.1/dns-query
```

```
