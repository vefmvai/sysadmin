---
last_verified: 2026-05-15
verification_interval: 6_months
sources:
  - https://sing-box.sagernet.org/clients/
  - https://sing-box.sagernet.org/clients/apple/
  - https://sing-box.sagernet.org/clients/apple/features/
  - https://sing-box.sagernet.org/clients/android/
  - https://github.com/SagerNet/sing-box
  - https://github.com/SagerNet/sing-box/releases
  - https://github.com/SagerNet/sing-box/issues/2024
  - https://github.com/SagerNet/sing-box-for-android
  - https://apps.apple.com/us/app/sing-box-vt/id6673731168
  - https://apps.apple.com/us/app/hiddify-proxy-vpn/id6596777532
  - https://apps.apple.com/us/app/karing/id6472431552
  - https://apps.apple.com/us/app/streisand/id6450534064
  - https://apps.apple.com/us/app/happ-proxy-utility/id6504287215
  - https://apps.apple.com/us/app/v2raytun/id6476628951
  - https://f-droid.org/packages/io.nekohasekai.sfa/
  - https://github.com/hiddify/hiddify-app
  - https://github.com/KaringX/karing
  - https://github.com/MatsuriDayo/NekoBoxForAndroid
  - https://github.com/2dust/v2rayNG
  - https://hiddify.com/app/URL-Scheme/
  - https://techcrunch.com/2024/07/08/apple-removes-vpn-apps-at-request-of-russian-authorities-say-app-makers/
  - https://www.theregister.com/2024/09/26/apple_vpn_russia/
  - https://novayagazeta.eu/amp/articles/2026/03/31/apple-reveals-it-bowed-to-kremlin-pressure-to-remove-190-apps-from-russian-app-store-over-three-years-en-news
---

# Клиентские приложения: карта на 2026-05-15

Этот документ — карта клиентских приложений для VPN-инфраструктуры,
организованной агентом-сисадмином. Покрывает приложения на двух ядрах
(sing-box и xray) для всех платформ (iOS, Android, macOS, Windows, Linux).

Читают: персона при ответах оператору «какой клиент поставить»;
скилл `/generate-client-config` при генерации конфигов под конкретное
приложение; косвенно — `/configure-vpn-routing` (формат subscription).

---

## 1. Главный вывод

Карта запутанная из-за двух причин:
1. **Два ядра** — sing-box и xray. Конфиги между ними **не полностью
   совместимы** (xray не понимает sing-box JSON; sing-box не понимает
   часть xray-фич mux.cool, fragment, mkcp).
2. **iOS-боль 2024-2026** — оригинальное sing-box-приложение снято из
   App Store, замены отстают по версии ядра, массовое удаление VPN-приложений
   из RU App Store 27-28 марта 2026.

**Универсальный рецепт:**
- **iOS** — `Hiddify Proxy & VPN` или `Karing`. Если уже установлен другой —
  не удалять (переустановить из RU App Store не получится).
- **Android** — `Hiddify`, `NekoBox`, `SFA` (sing-box официальный) или
  `v2rayNG` (xray) — все доступны на GitHub Releases или Google Play.
- **macOS** — `Hiddify`, `Karing`, или sing-box CLI как brew-сервис.
- **Windows** — `Hiddify`, `Karing`, или sing-box CLI через WinTun.
- **Linux** — Hiddify desktop, sing-box как systemd-сервис.

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
| **sing-box-vt** | 6673731168 | sing-box 1.11.x | 1.11.4 (24.02.2025) | Не в списках удалённых по имени, но **возможно удалено** в волне 27-28.03.2026 — требует прямой проверки |
| **Hiddify Proxy & VPN** | 6596777532 | hiddify-sing-box + Xray | непроверено конкретный тег | **Не в списках удалённых** (на 15.05.2026) |
| **Karing** | 6472431552 | mihomo (clash.meta) + модифицированный sing-box | непроверено | **Не в списках удалённых** |
| Streisand | 6450534064 | Xray-core | n/a | **УДАЛЕНО** ~28.03.2026 |
| FoXray | 6448898396 | Xray-core | соответствует Xray | непроверено (под угрозой) |
| Happ | 6504287215 | Xray-core 26.3.27 (по умолчанию) + опция sing-box | Xray 26.3.27 | **УДАЛЕНО** ~28.03.2026 |
| v2RayTun | 6476628951 | Xray-core 25.10.15 | n/a | **УДАЛЕНО** ~28.03.2026 |

**Рекомендация для iOS:**
- **Новое устройство в РФ** — `Hiddify Proxy & VPN` (приоритет) или `Karing`.
- **Старое устройство, уже что-то стоит** — не удалять. Sing-box-vt /
  Streisand / Happ переустановить из RU App Store не получится.
- **Энтузиаст с другим Apple ID** — переключить регион (Казахстан, Армения),
  поставить `sing-box-vt` оттуда. Для бесплатных приложений оплата не нужна.

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
| Ядро | hiddify-sing-box (форк) + опционально Xray-core |
| Версия sing-box внутри | непроверено конкретный тег (форк 1.x) |

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

### 3.6 Happ Android

| Параметр | Значение |
|---|---|
| Repo | github.com/Happ-proxy/happ-android |
| Google Play | com.happproxy |
| Ядро по умолчанию | Xray |
| Опция sing-box | Через Preferences → Basic settings → Core |
| Хранение | Закрытое (encrypted on device) |

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
- `3x-ui-panel.md` — серверная сторона, генерация subscription endpoint.
- `3x-ui-api.md` — субскрипция через REST API, получение vless://-link
  по UUID клиента.

---

*Документ обновляется планово раз в 6 месяцев. Триггеры внеплановой
ревизии: обновление списков удалённых из App Store / Google Play VPN-приложений;
релиз новой минорной версии sing-box с breaking changes для клиентов;
обновление iOS/Android API, ломающее TUN inbound; смена политики Apple
по RU App Store.*
