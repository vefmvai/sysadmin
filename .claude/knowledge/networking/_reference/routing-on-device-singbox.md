---
knowledge_domain: vpn
layer: reference
last_researched: 2026-05-22
ttl_days: 60
sources_checked:
  - https://sing-box.sagernet.org/configuration/route/
  - https://sing-box.sagernet.org/clients/
  - https://github.com/SagerNet/sing-box/releases
  - https://github.com/GUI-for-Cores/GUI.for.SingBox
  - https://apps.apple.com/app/id6673731168
---

# Гибкая маршрутизация НА УСТРОЙСТВЕ через sing-box — для энтузиастов

Этот документ — **альтернативный, НЕ дефолтный** способ. Split (РФ → direct,
foreign → proxy, реклама → block) делается **на устройстве** в клиенте на ядре
sing-box, а не на сервере. Дефолт — серверная маршрутизация
(`routing-server-3xui.md`); этот путь выбирают, только если осознанно хотят
прямой выход РФ-трафика и готовы погрузиться в настройку.

Читают: персона при запросе «хочу маршрутизацию прямо на телефоне/компе»;
скилл `/generate-client-config` при `platform=*` с on-device routing.

Связан с:
- `routing-server-3xui.md` (дефолтный путь — split на сервере)
- `routing-on-device-xray.md` (то же, но на ядре Xray в терминале)
- `client-apps.md` (карта клиентов, версии ядер, форматы импорта)
- `vpn-consultation-flow.md` (сценарий консультации, TUN, hub)

---

## §0 Зачем и почему НЕ дефолт

**Зачем on-device split:** РФ-трафик выходит **напрямую** с устройства, минуя
РФ-сервер: `устройство → (direct) → РФ-сайт`. Экономит один hop (~10-20 мс),
РФ-сайт видит реальный домашний IP, сервер не грузится РФ-трафиком.

**Почему НЕ дефолт (по опыту оператора):**

1. **Выигрыш 10-20 мс не оправдывает сложность.** Для типового пользователя
   разница незаметна. Серверный split (`routing-server-3xui.md`) даёт то же
   разделение РФ/foreign без единой настройки на устройстве.
2. **Единственное ядро, которое честно исполняет произвольный raw route на
   устройстве — sing-box.** Hiddify не даёт править сырой route руками (строит
   из подписки сам, см. `client-apps.md`). То есть выбора клиентов мало.
3. **Состояние sing-box-клиентов на 2026-05-22 неровное** (см. §3): на iOS —
   только устаревшее ядро 1.11, на десктопе/Android — свежее, но требует
   разобраться с raw JSON.
4. **Раскол формата ядра 1.11↔1.12** (см. §2) — главная засада «одного конфига
   на все устройства».

Вывод для агента: предлагать этот путь только пользователю, который сам просит
прямой выход РФ-трафика и готов работать с raw JSON. Иначе — серверный split.

---

## §1 Механика: split исполняет ядро sing-box, не приложение

«Гибкая маршрутизация» — это **route-правила ядра sing-box**, а не фича
конкретного приложения. Приложение (SFA, GUI.for.SingBox) — лишь оболочка,
которая подаёт ядру JSON-конфиг. Поэтому:

- логика split привязана к **ядру sing-box**, не к бренду клиента;
- любой клиент на чистом sing-box-ядре исполнит одинаковый route;
- Hiddify — тоже на форке sing-box, но не даёт писать произвольный route руками,
  поэтому для on-device split не годится.

Структура route в sing-box JSON:

```json
"route": {
  "rules": [
    { "ip_is_private": true, "outbound": "direct" },
    { "rule_set": "geosite-category-ads-all", "action": "reject" },
    { "rule_set": ["geoip-ru", "geosite-ru"], "outbound": "direct" },
    { "domain_suffix": [".ru", ".su"], "outbound": "direct" }
  ],
  "final": "proxy",
  "rule_set": [ "...определения geoip-ru, geosite-ru, ads..." ]
}
```

> Это **sing-box-синтаксис**, НЕ Xray. Серверные правила из
> `routing-server-3xui.md` (формат `{"type":"field","outboundTag":...}`) сюда не
> ложатся as is.

---

## §2 Раскол формата ядра 1.11 ↔ 1.12 — главная засада

Последняя stable ядра sing-box — **1.13.12 (15.05.2026)**. Но клиенты сидят на
разных версиях, и между 1.11 и 1.12 сломался формат конфига. Ключевые рубежи:

| Версия | Что сломалось в формате |
|---|---|
| 1.11.0 (2025-01-30) | rule actions: `type:"block"`/`type:"dns"` → `action:"reject"`/`"hijack-dns"` |
| **1.12.0 (2025-08-04)** | **Формат DNS:** старое `dns.servers[].address` (строка-URL) → новое `{type, server}`. WireGuard outbound → endpoints |
| 1.13.0 (2026-02-28) | legacy DNS-форматы deprecated, удаление в 1.14.0 |
| 1.14.0 (alpha) | полное удаление legacy DNS-формата. Stable ещё нет на 2026-05-22 |

**Практическое следствие — два DNS-профиля.** «Один конфиг на все устройства»
не работает, если в парке есть iOS на застрявшем 1.11 (см. §3):

- **legacy-профиль** (DNS строкой `"address":"https://1.1.1.1/dns-query"`,
  `"address":"local"`) — для iOS/macOS на ядре 1.11 и для Hiddify;
- **modern-профиль** (`{"type":"https","server":"1.1.1.1"}`) — для
  Android/desktop на ядре 1.12+.

Legacy-формат ещё принимается ядрами 1.12-1.13 с deprecation-warning, но
**сломается в stable 1.14.0**. То есть «один legacy-конфиг на всех» — рабочая, но
временная стратегия.

Полная карта «какая фича с какой версии» — `client-apps.md` §9.2.

---

## §3 Состояние sing-box-клиентов на 2026-05-22

Подробные ссылки и версии — `client-apps.md`. Сводка под on-device routing:

| Платформа | Клиент | Ядро | Raw JSON руками? | Заметка |
|---|---|---|---|---|
| **iOS** | SFI (офиц.) | свежее (TestFlight) | да, полностью | TestFlight только спонсорам |
| **iOS** | sing-box VT | **1.11.4 (заморожен)** | да, полностью | App Store, но устаревшее ядро — писать в legacy-формате |
| **iOS** | Karing | модиф. sing-box | модель «подписка», не подтверждено | App Store, активный |
| **Android** | SFA (офиц.) | **апстрим 1.13.x** | да, полностью | эталон стабильности, GitHub APK |
| **Android** | NekoBox | форк 1.12.x | **максимум** (3 слоя инъекции JSON) | краши в фоне, редкие апдейты |
| **Android** | husi | форк | модель NekoBox | живее NekoBox, Codeberg |
| **Desktop** | GUI.for.SingBox | **версия выбирается вручную** | да (Script-хук) | главный выбор для десктопа |
| **Desktop** | SFM (офиц.) | каноничное 1.13.x | да (внешний редактор) | `brew install --cask sfm` |
| **Desktop** | Throne | sing-box 1.13.12 | да, прямой доступ | форк nekoray, Qt |

**Ключевая боль iOS:** официальный SFI в App Store не обновляется, VT застрял на
1.11.4. То есть на iPhone через App Store доступно только **ядро 1.11** → нижняя
планка совместимости для «общего» конфига = 1.11. Свежее ядро на iOS — только
через TestFlight (спонсорство) или Karing (своя модель). На десктопе/Android
проблема снимается полностью.

---

## §4 Ограничения по платформам (из офиц. доки sing-box)

| Опция / правило | iOS | macOS | Android | Linux/Win |
|---|---|---|---|---|
| `strict_route` | ❌ not impl. | ✅ | ✅ | ✅ |
| `process_name` / `process_path` | ❌ no perm | ❌ no perm | — | ✅ |
| per-app по `package_name` | ❌ | ❌ | ✅ **только Android** | — |
| `wifi_ssid` / `wifi_bssid` | ✅ **только iOS** | ❌ | ❌ | ❌ |
| TUN | через NetworkExtension (unprivileged) | NE | VpnService | root/CAP_NET_ADMIN |

Следствия:
- **per-app routing** (направить конкретное приложение через/мимо VPN) — реально
  только на **Android** через `package_name`. На iOS/macOS этого нет.
- **`wifi_ssid`** — iOS-эксклюзив: удобно «дома direct, в чужой сети → VPN».
- Лимит памяти Network Extension на iOS **~50 МБ** → jetsam-краши на speedtest
  100+ Мбит/с. Общая боль всех sing-box-клиентов на iOS, не зависит от приложения.

Для `/generate-client-config` при `platform=ios` — не использовать
`strict_route`, `process_name`; писать DNS в legacy-формате (ядро 1.11);
маршрутизация только через rule_set + ip_cidr + domain_*.

---

## §5 Ссылки на установку (проверено 2026-05-22)

Полный список с версиями — итог сегодняшнего исследования. Кратко:

**iOS:**
- SFI (офиц.): https://github.com/SagerNet/sing-box-for-apple — TestFlight только спонсорам (Telegram @yet_another_sponsor_bot)
- sing-box VT: https://apps.apple.com/app/id6673731168 (ядро 1.11.4; доступность в РФ App Store — проверять вручную)
- Karing: https://apps.apple.com/us/app/karing/id6472431552

**Android:**
- SFA (офиц., v1.13.12): https://github.com/SagerNet/sing-box/releases → `SFA-1.13.12-universal.apk` (брать с GitHub SagerNet — в Google Play издатель указан как Viral Tech)
- NekoBox (v1.4.2): https://github.com/MatsuriDayo/NekoBoxForAndroid/releases
- husi (v1.2.0): https://codeberg.org/xchacha20-poly1305/husi/releases (GitHub-зеркало заморожено на 1.0.2 — брать с Codeberg)

**Desktop (главный выбор — GUI.for.SingBox):**
- GUI.for.SingBox (v1.24.1): https://github.com/GUI-for-Cores/GUI.for.SingBox/releases — `.zip` под darwin-arm64/amd64, windows, linux-amd64. Версия ядра выбирается внутри приложения (вкладка Kernel)
- SFM (офиц., macOS): `brew install --cask sfm` ✅ или https://github.com/SagerNet/sing-box/releases/latest (`SFM-1.13.12-Universal.pkg`)
- Throne (v1.1.3, sing-box 1.13.12): https://github.com/throneproj/Throne/releases
- sing-box CLI: `brew install sing-box` ✅ / Linux пакеты на https://sing-box.sagernet.org/installation/package-manager/

Не подтверждено (проверять вручную): доступность VT в РФ App Store; точный
TestFlight-URL SFI; Homebrew cask для GUI.for.SingBox/Throne/Karing.

---

## §6 Рекомендация по выбору клиента под on-device split

| Платформа | Бери | Почему |
|---|---|---|
| macOS | GUI.for.SingBox (+ SFM для отладки) | сам выбираешь версию ядра, Script-хук = полный контроль route |
| Windows/Linux | GUI.for.SingBox | одна кодовая база, raw route через Script |
| Android | SFA (стабильность) или NekoBox (правка JSON в приложении) | SFA = чистое 1.13; NekoBox = глубже, но краши в фоне |
| iOS | SFI через TestFlight, иначе sing-box VT (legacy-конфиг 1.11) | произвольный raw JSON едят только эти двое |

---

## §7 Связи

- **Дефолтный путь (split на сервере):** `routing-server-3xui.md`
- **On-device через Xray (терминал):** `routing-on-device-xray.md`
- **Карта клиентов, версии ядер, форматы:** `client-apps.md`
- **Сценарий консультации, TUN, hub:** `vpn-consultation-flow.md`
- **Теория протоколов:** `vpn-protocols.md`
- **Транспорты:** `transports.md`
- **Фронт блокировок:** `_live/frontline-ru.md`
- **Скилл:** `/generate-client-config`
