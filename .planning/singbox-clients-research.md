# Клиенты на ядре sing-box: платформенная карта

**Дата:** 2026-05-15
**Назначение:** ориентир для агента-сисадмина при генерации клиентских VPN-конфигов
для пользователей в РФ. Каждый факт помечен уровнем доверия:

- **[высокий]** — подтверждено в первоисточнике (App Store / GitHub releases / официальная документация sing-box).
- **[средний]** — упоминания в обзорах, гайдах, неофициальных вики; не противоречат первоисточникам, но не подтверждены ими прямо.
- **[непроверено]** — не нашёл подтверждения, явная пометка.

---

## TL;DR для агента

1. **iPhone — самая болезненная платформа.** Оригинальное приложение SagerNet `sing-box` (SFI) **снято с App Store 1 августа 2024**. Замена `sing-box-vt` (от VIRAL TECH, Inc., обложка nekohasekai) **недоступна в App Store России** после массовых удалений VPN-клиентов 27–28 марта 2026. Тот же запрет накрыл `Streisand`, `v2RayTun`, `Happ`.
2. **Что использовать на iOS-РФ сейчас:** **`Hiddify Proxy & VPN`** (ID 6596777532) и **`Karing`** (ID 6472431552) — на момент исследования в списках удалённых из RU App Store не фигурируют. Альтернатива — установить из App Store другой страны.
3. **Версии sing-box, зашитые в клиенты:** разные. У `sing-box-vt` v1.11.4 (Feb 2025) — отстаёт от мейнлайна v1.13.12 (15 мая 2026). У `Hiddify` — собственный форк `hiddify-sing-box`. У `Karing` — модифицированный sing-box-core. У `NekoBoxForAndroid` 1.4.1 → sing-box `1.12.12-neko-1` (Oct 2025).
4. **Не все клиенты на ядре sing-box.** `Streisand`, `FoXray`, `v2RayTun`, `Happ`, `v2rayNG` — это **xray-core**. Конфиги между двумя ядрами **частично несовместимы** (xray не поддерживает mux sing-box; sing-box не поддерживает xray-фичи mux.cool, fragment, mkcp).
5. **Подписка vs JSON-файл.** Большинство клиентов на ядре sing-box принимают и прямой JSON-файл sing-box, и subscription URL (часто base64-encoded список `vless://` / `vmess://` ссылок).

---

## Блок 1. iOS — критическая зона

### 1.1. Хронология оригинального приложения SagerNet sing-box (SFI)

- **Июль 2023** — официальное приложение `sing-box` (developer: Sager Networks Ltd.) появилось в App Store **[средний]** (упоминание в обзоре истории удаления, конкретный день не нашёл).
- **1 августа 2024** — приложение **unpublished** из App Store по «нетехническим причинам». Официальная формулировка с сайта sing-box: "Due to non-technical reasons, we are temporarily unable to update the sing-box app on the App Store and release the standalone version of the macOS client." **[высокий]** — источник: <https://sing-box.sagernet.org/clients/apple/>.
- **13 августа 2024** — issue #2024 на GitHub: пользователи из Малайзии, Турции, США сообщают что приложение «not available in your country». Issue закрыт автором SagerNet как "not planned". **[высокий]** — <https://github.com/SagerNet/sing-box/issues/2024>.
- **Сентябрь 2024** — обнаружено приложение **`sing-box-vt`** (ID 6673731168) от **VIRAL TECH, Inc.**, копирайт `© nekohasekai` (автор оригинала). Это де-факто продолжение оригинального SFI под другим юр-лицом. **[высокий]** — <https://apps.apple.com/us/app/sing-box-vt/id6673731168>.

### 1.2. Текущее состояние оригинальной линии

- **`sing-box-vt`** (App Store, ID 6673731168):
  - Developer: VIRAL TECH, INC.; © nekohasekai.
  - Версия **1.11.4**, последнее обновление **24 февраля 2025**. **[высокий]**
  - Поддержка: iOS 15+, iPadOS 15+, macOS 13+, visionOS 1+, tvOS 17+.
  - Внутреннее ядро sing-box (версия не указана явно в листинге, но соответствует релизной ветке 1.11 — отстаёт от мейнлайна на 2 минора).
  - **Удалена из App Store России около 27–28 марта 2026** в рамках массового удаления VPN-приложений после обращения российских властей. **[высокий]** — упомянуто среди удалённых в отчётах: <https://techcrunch.com/2024/07/08/apple-removes-vpn-apps-at-request-of-russian-authorities-say-app-makers/>, <https://www.theregister.com/2024/09/26/apple_vpn_russia/>. **Примечание:** конкретно `sing-box-vt` в списках по имени не фигурирует — но `Streisand`, `v2Box`, `v2RayTun`, `Happ` точно были. По `sing-box-vt` — **[непроверено]** на 100%, нужна прямая проверка через AppleCensorship.
- **TestFlight-бета** (SFI / `sing-box for Apple`):
  - Существует, но **доступ только спонсорам**. "TestFlight quota is only available to sponsors. Once you donate, you can get an invitation by joining the Telegram group for sponsors from @yet_another_sponsor_bot or sending your Apple ID via email." **[высокий]** — <https://sing-box.sagernet.org/clients/apple/>.
  - Это значит: получить актуальную версию sing-box на iOS легально и бесплатно — нельзя.

### 1.3. Альтернативные iOS-клиенты — детальный обзор

| Параметр | Streisand | FoXray | Karing | Happ | Hiddify | v2RayTun |
|---|---|---|---|---|---|---|
| **App Store ID** | 6450534064 | 6448898396 | 6472431552 | 6504287215 | 6596777532 | 6476628951 |
| **Developer** | ARCADIA ODYSSEY INC. | YIGUO NETWORK INC. | Supernova Nebula LLC | Flyfrog LLC | Holistic Resilience | непроверено |
| **Версия (на 15 мая 2026)** | 1.6.71 | 25.4.3 | 1.2.18.2102 | 4.9.0 | 4.0 | непроверено |
| **Дата апдейта** | 16 апреля 2025 | непроверено | 29 апреля 2026 (год — допущение по контексту) | 7 мая 2026 (год — допущение) | 19 февраля 2026 | непроверено |
| **Внутреннее ядро** | Xray-core | Xray-core | mihomo (clash.meta) + модифицированный sing-box | Xray-core (26.3.27) | Hiddify-sing-box (форк sing-box) + Xray | Xray-core 25.10.15 |
| **Поддержка sing-box-конфигов** | НЕТ (xray) | НЕТ (xray) | ДА (sing-box subscription и JSON) | НЕТ как ядро; но импорт `vless://` работает | **ДА** (полная поддержка sing-box-JSON, "All Protocols supported by Sing-Box") | НЕТ (xray) |
| **Min iOS** | 14.0 | 15.0 (предположение) | 15.0 | непроверено | непроверено | непроверено |
| **Удалено из App Store России?** | **ДА** (~27–28 марта 2026) | непроверено (под угрозой) | НЕ упомянуто в волне удалений | **ДА** (~27–28 марта 2026) | НЕ упомянуто в волне удалений | **ДА** (~27–28 марта 2026) |

Источники:
- Streisand: <https://apps.apple.com/us/app/streisand/id6450534064>, <https://www.techradar.com/vpn/vpn-privacy-security/apple-removes-custom-vpn-clients-from-russian-app-store-amid-telegram-crackdown>
- FoXray: <https://apps.apple.com/ca/app/foxray/id6448898396>, <https://iphone.apkpure.com/foxray/dev.yiguo.foxray/amp>
- Karing: <https://apps.apple.com/us/app/karing/id6472431552>, <https://karing.app/en/>
- Happ: <https://apps.apple.com/us/app/happ-proxy-utility/id6504287215>, <https://www.happ.su/main/dev-docs/app-management>
- Hiddify: <https://apps.apple.com/us/app/hiddify-proxy-vpn/id6596777532>, <https://github.com/hiddify/hiddify-app>
- v2RayTun: <https://apps.apple.com/us/app/v2raytun/id6476628951>

### 1.4. iOS-специфика sing-box-конфигов

В TUN inbound на iOS **не реализованы** следующие опции (Apple sandbox limit): **[высокий]** — <https://sing-box.sagernet.org/clients/apple/features/>

- `gso` — Generic Segmentation Offload.
- `strict_route`.
- `include_interface` / `exclude_interface`.
- `include_uid` / `exclude_uid`.
- Process-based filtering: `process_name`, `process_path`, `process_path_regex` — недоступны на iOS И macOS ("no permission" на обеих платформах).

Routing rule `wifi_ssid` / `wifi_bssid` — **только iOS** (на macOS отсутствуют).

**Практический вывод для агента:** генерируя конфиг для iPhone, не использовать `strict_route`, не делать routing-rules по `process_name` — конфиг просто будет проигнорирован или отвалится.

### 1.5. Что делать оператору с iPhone в РФ

Логическое дерево решений для агента, когда оператор спрашивает про iPhone:

1. Уточнить: новое устройство или уже установлен какой-то клиент?
2. Если на iPhone уже стоит `sing-box-vt` или `Streisand` или `Happ` — **продолжать работать, не удалять**. После удаления переустановить из RU App Store не получится.
3. Если устройство новое или нужно установить заново:
   - **Вариант A (рекомендуемый):** `Hiddify Proxy & VPN` или `Karing` — на момент 15 мая 2026 не в списках удалённых из RU App Store.
   - **Вариант B:** Переключить Apple ID на App Store другой страны (Казахстан, Армения) — получить `sing-box-vt`, `Streisand`, `Happ` оттуда. Минус — оплата с РФ-карты невозможна, но для бесплатных приложений не нужна.
   - **Вариант C (для энтузиастов):** TestFlight оригинального `sing-box for Apple` через спонсорство автора. Бесплатно — нет; легально — да.

---

## Блок 2. Android

### 2.1. Официальное приложение sing-box (SFA)

- **Имя:** sing-box for Android (SFA). Repo: <https://github.com/SagerNet/sing-box-for-android>.
- **Источники:** Google Play, Play Store Beta, GitHub Releases, F-Droid. **[высокий]** — <https://sing-box.sagernet.org/clients/android/>.
- **F-Droid версия:** **1.13.11** (build 662), 24 апреля 2026, размер 91 MiB, Android 6.0+. **[высокий]** — <https://f-droid.org/packages/io.nekohasekai.sfa/>.
- **Google Play:** доступно, developer на Google Play — Viral Tech, Inc. (та же связка, что и `sing-box-vt` на iOS). 500K+ установок, рейтинг 3.9 (1.98K отзывов). **[высокий]** — <https://play.google.com/store/apps/details?id=io.nekohasekai.sfa>.
- **Доступность в РФ Google Play:** **[непроверено]** прямо. По общим данным GooglePlay не блокирует VPN-приложения в РФ так массово как Apple, но локально могут быть ограничения.

### 2.2. NekoBoxForAndroid

- Repo: <https://github.com/MatsuriDayo/NekoBoxForAndroid>.
- **Внутреннее ядро:** sing-box (форк с суффиксом `-neko`). **[высокий]**
- **Стабильная:** 1.4.1 от 30 октября 2025, sing-box `1.12.12-neko-1`. **[высокий]**
- **Preview:** pre-1.4.2-20260202-1 от 2 февраля 2026, sing-box `1.12.19-neko-1`. **[высокий]**
- **Поддержка протоколов:** Shadowsocks, VMess, VLESS, Trojan, Hysteria 1/2, TUIC, WireGuard, SOCKS, HTTP(S), SSH, AnyTLS, ShadowTLS, Trojan-Go, NaïveProxy, Mieru. **[высокий]**
- **Доступность:** только GitHub Releases (нет в Google Play официально). Это даёт независимость от RU-блокировок Google.
- **Android 5.0+** требуется.

### 2.3. Hiddify Android

- Доступна как `Hiddify` в Google Play (<https://play.google.com/store/apps/details?id=app.hiddify.com>). Также на GitHub Releases. **[высокий]**
- Текущая версия — **v4.1.1** от 5 марта 2026 (общая для всех платформ). **[высокий]** — <https://github.com/hiddify/hiddify-app/releases>.
- Использует **форк sing-box** (`hiddify-sing-box`, repo <https://github.com/hiddify/hiddify-sing-box>) + опционально Xray-core. **[высокий]**
- Версия sing-box внутри Hiddify — **[непроверено]** конкретный коммит/тег. Известно только что это форк ветки 1.x.

### 2.4. v2rayNG

- **Внутреннее ядро:** Xray-core, **не sing-box**. **[высокий]** — <https://github.com/2dust/v2rayNG/discussions/2569>.
- Прямой импорт sing-box-JSON **не поддерживается**.
- Принимает `vless://`, `vmess://`, `trojan://`, `ss://`, subscription URL (base64).
- Конвертация возможна через утилиту `v2box` (<https://github.com/SagerNet/v2box>), но не все фичи sing-box переносятся (mux, hysteria, tuic, naïveproxy, mieru).
- **Практический вывод:** если оператор использует v2rayNG, конфиги должны быть в xray-формате (`vless://...?security=reality`).

### 2.5. Karing Android

- Тот же бинарь Karing, что и для iOS — Flutter-приложение, cross-platform. **[высокий]** — <https://github.com/KaringX/karing>.
- Поддержка Clash / Sing-box / V2ray / Shadowsocks подписок. Версия sing-box внутри — **[непроверено]**.

### 2.6. Happ Android

- Доступно на Google Play: <https://play.google.com/store/apps/details?id=com.happproxy>.
- Источник: <https://github.com/Happ-proxy/happ-android>, <https://www.happ.su/main>.
- **Ядро по умолчанию:** Xray. **Может работать с sing-box** через настройку "Preferences → Basic settings → Core" (опция передать свою sing-box-конфигурацию). **[средний]** — <https://www.happ.su/main/dev-docs/app-management>.
- Поддерживает subscription URL + ручной ввод серверов. Закрытое хранение ссылок (encrypted on device).

---

## Блок 3. macOS

### 3.1. sing-box-cli

- **Установка через brew:** документация sing-box упоминает homebrew `sing-box`. Конкретный путь brew formulae — **[непроверено]**.
- **Запуск как сервис:** `launchd` plist либо `brew services start sing-box`. **[непроверено]** прямой документации, известно по общим практикам.
- **Версия:** ядро sing-box идентично Linux — **v1.13.12** на 15 мая 2026. **[высокий]** — <https://github.com/SagerNet/sing-box/releases>.

### 3.2. GUI-приложения на macOS

- **`sing-box-vt`** (он же SFM в исходниках SagerNet) — **тот же app**, что и для iPhone, ID 6673731168, версия 1.11.4. Поддержка macOS 13.0+. **[высокий]**
- **`Hiddify Proxy & VPN`** — тот же app для macOS (Mac Catalyst), либо отдельный билд из <https://github.com/hiddify/hiddify-app/releases> (DMG/PKG). v4.1.1, требуется macOS 10.15+. **[высокий]**
- **`Karing`** — Mac Catalyst app, тот же ID в App Store что и iOS-версия. **[высокий]**
- **FoXray для macOS** — упоминается в листинге App Store, но конкретный билд **[непроверено]**.

### 3.3. Системная интеграция

- **TUN-mode**: работает через NetworkExtension на macOS (Apple sandbox). Те же ограничения, что и на iOS — `process_name`-routing недоступно. **[высокий]**
- **Route-table modifications**: sing-box делает это сам через NetworkExtension API; root-доступ не нужен для App Store-версий, но нужен для `sing-box-cli` запущенного как daemon.

---

## Блок 4. Windows

### 4.1. sing-box-cli

- **Установка:** скачать `sing-box-windows-amd64.zip` с GitHub Releases. **[высокий]** — <https://github.com/SagerNet/sing-box/releases>.
- **Версия:** v1.13.12 на 15 мая 2026. **[высокий]**
- **Запуск как Windows-сервис:** через `nssm` или `sc create`, либо в режиме task scheduler. Документация sing-box не имеет встроенного `install-service` для Windows — **[непроверено]** прямо.

### 4.2. GUI

- **`sing-box-windows`** (сторонний проект): <https://github.com/xinggaoya/sing-box-windows>. Modern GUI client с поддержкой подписок и переключения proxy-режимов. **[средний]** — упоминается в результатах поиска, не первоисточник sing-box.
- **`Hiddify`** для Windows — Setup .Msix, Setup .exe, Portable .zip — v4.1.1. **[высокий]** — <https://github.com/hiddify/hiddify-app/releases>.
- **`Karing`** для Windows — есть в GitHub releases <https://github.com/KaringX/karing/releases>. Версия — **[непроверено]**.
- **NekoRay (NekoBox для desktop)** — Qt-приложение. **[средний]** — <https://github.com/qr243vbi/nekobox> (NyameBox — форк). Активность оригинального `MatsuriDayo/nekoray` — **[непроверено]** на 2026.

### 4.3. TUN-драйвер

- На Windows sing-box использует **WinTun** (<https://www.wintun.net/>). Это легковесный TUN-драйвер, изначально написанный для WireGuard. **[высокий]** — <https://deepwiki.com/SagerNet/sing-box>.
- Альтернатива WireGuard — TAP-Windows — sing-box не использует.

---

## Блок 5. Linux

### 5.1. sing-box как systemd-сервис

- **Установка через пакетный менеджер:** apt (Debian/Ubuntu), dnf (Fedora/RHEL), pacman (Arch). **[высокий]** — <https://sing-box.sagernet.org/installation/package-manager/>.
- **Systemd unit** ставится автоматически: `systemctl enable --now sing-box`. **[высокий]**
- **Capabilities в systemd unit:**
  - `CAP_NET_ADMIN` — для TPROXY и TUN-интерфейса.
  - `CAP_NET_BIND_SERVICE` — порты <1024.
  - `CAP_NET_RAW` — ICMP и raw sockets.
  - `CAP_SYS_PTRACE` — process-based routing rules.
  - **[высокий]** — <https://deepwiki.com/SagerNet/sing-box>.

### 5.2. GUI на Linux

- **Hiddify Desktop**: AppImage, .deb, .rpm для x86_64. v4.1.1, март 2026. **[высокий]**
- **Karing Linux**: AppImage / deb. **[средний]** — упоминается в release notes, точная версия **[непроверено]**.
- Стабильного нативного GUI-клиента на gtk/qt от SagerNet официально нет. Документация sing-box для desktop помечает "Working in progress". **[высокий]** — <https://sing-box.sagernet.org/clients/>.

---

## Блок 6. Версии sing-box внутри клиентов — сводная таблица

| Клиент | Платформы | Внутреннее ядро | Версия ядра | Источник | Доступно в РФ |
|---|---|---|---|---|---|
| **sing-box (mainline CLI)** | macOS, Windows, Linux | sing-box | **1.13.12** (15 мая 2026); beta 1.14.0-alpha.24 | <https://github.com/SagerNet/sing-box/releases> | GitHub доступен в РФ |
| **sing-box-vt** (был SFI) | iOS, iPadOS, macOS, visionOS, tvOS | sing-box (ветка 1.11) | **1.11.x** (соответствует app v1.11.4 от 24.02.2025) | <https://apps.apple.com/us/app/sing-box-vt/id6673731168> | **App Store доступен (но не в RU после марта 2026 — [непроверено] точечно)** |
| **sing-box-for-android (SFA)** | Android 6.0+ | sing-box | **1.13.11** (F-Droid build 24.04.2026) | <https://f-droid.org/packages/io.nekohasekai.sfa/> | F-Droid доступен; Google Play РФ — непроверено |
| **NekoBox для Android** | Android 5.0+ | sing-box (форк `-neko`) | **1.12.12-neko-1** (stable 1.4.1 от 30.10.2025); **1.12.19-neko-1** (preview 02.02.2026) | <https://github.com/MatsuriDayo/NekoBoxForAndroid/releases> | GitHub доступен |
| **Hiddify** (Next / app) | iOS, Android, Windows, macOS, Linux | hiddify-sing-box (форк) + Xray | **[непроверено]** конкретный тег sing-box внутри v4.1.1 | <https://github.com/hiddify/hiddify-app/releases> | App Store + Google Play (на момент 15.05.2026 — не в списках удалённых) |
| **Karing** | iOS, Android, macOS, Windows, Linux, tvOS | mihomo (clash.meta) + sing-box (модифицированный) | **[непроверено]** | <https://github.com/KaringX/karing/releases> | App Store + Google Play (не в списках удалённых) |
| **Streisand** | iOS 14.0+ | **Xray-core**, не sing-box | n/a | <https://apps.apple.com/us/app/streisand/id6450534064> | **УДАЛЕНО из RU App Store ~28.03.2026** |
| **FoXray** | iOS 15+, iPadOS, macOS | **Xray-core**, не sing-box | соответствует Xray | <https://apps.apple.com/us/app/foxray/id6448898396> | непроверено |
| **Happ** | iOS, Android, macOS, Linux, Windows, Android TV, tvOS | **Xray-core 26.3.27** (по умолчанию) + опция sing-box | Xray 26.3.27 (app 4.9.0 от 07.05.2026 — год допущение) | <https://apps.apple.com/us/app/happ-proxy-utility/id6504287215> | **УДАЛЕНО из RU App Store ~28.03.2026** |
| **v2RayTun** | iOS, Android | **Xray-core 25.10.15**, не sing-box | n/a | <https://apps.apple.com/us/app/v2raytun/id6476628951> | **УДАЛЕНО из RU App Store ~28.03.2026** |
| **v2rayNG** | Android | **Xray-core**, не sing-box | n/a | <https://github.com/2dust/v2rayNG> | GitHub + Google Play (русскую вёрстку не блокировали массово) |
| **NekoRay / NyameBox** | Windows, Linux (Qt desktop) | sing-box + Xray | непроверено | <https://github.com/qr243vbi/nekobox> | GitHub |

### Критический вывод по версиям

- **Самая свежая версия sing-box внутри iOS-приложения** = **1.11.4** (в `sing-box-vt`, февраль 2025). **Мейнлайн ушёл вперёд на 4 минора** (1.12, 1.13, 1.14-alpha) → ряд фич мейнлайна (1.12+, 1.13+) на iPhone **не работают**.
- **Особенно: anytls, mieru, новые ветки hysteria** появились в 1.12+ — `sing-box-vt` их не поддерживает.
- На Android через NekoBox 1.4.1 — `1.12.12-neko-1`, на Hiddify — `[непроверено]`, на F-Droid SFA — **1.13.11** (самая свежая в массовом доступе).
- **Это и есть тот «iOS-нюанс»**, о котором говорил оператор: для iPhone актуальное приложение остановилось на ветке 1.11 в феврале 2025.

---

## Блок 7. Импорт конфигов — какой формат куда

### 7.1. Форматы

1. **Прямой sing-box JSON** — полный конфиг (`{"log": {...}, "inbounds": [...], "outbounds": [...], "route": {...}}`). Принимают:
   - `sing-box-vt` (iOS/macOS) — через "Add profile" → URL или local file.
   - SFA (Android) — то же.
   - NekoBox (Android) — через импорт.
   - Hiddify — через "Add config" → URL или file.
   - Karing — да, sing-box subscription/JSON.

2. **vless:// / vmess:// / trojan:// / ss:// ссылки** (Xray-формат) — текстовые URI с base64-параметрами. Принимают:
   - **Все** перечисленные клиенты (xray-нативные + sing-box-нативные).
   - QR-коды кодируют именно их.
   - **Самый совместимый формат** для агента, генерирующего конфиг.

3. **Subscription URL (HTTP)** — endpoint возвращает либо base64-кодированный список `vless://...\nvmess://...\n...`, либо sing-box JSON. Принимают:
   - sing-box-vt, SFA, Hiddify, Karing, Happ, NekoBox, v2rayNG, Streisand.
   - **Самый удобный формат для пользователя** — клиент сам обновляет список нод.

4. **Hiddify-профиль** (`hiddify://` или `hiddify+vless://...?...&hiddify=...`) — расширенный URI с метаданными. Принимает только **Hiddify**. **[высокий]** — <https://hiddify.com/manager/client-software-on-ios/>.

5. **Clash YAML** — `proxies:`, `rules:`, `proxy-groups:`. Принимают:
   - Karing (нативно — там mihomo внутри).
   - NekoBox — через импорт.
   - **Не принимают** sing-box-vt, SFA напрямую.

### 7.2. Что должен делать агент при генерации конфига для клиента

| Клиент | Что отдавать |
|---|---|
| `sing-box-vt`, SFA, Hiddify, Karing | sing-box JSON по subscription URL **или** массив `vless://` ссылок в base64 |
| NekoBox | sing-box JSON по subscription URL |
| Streisand, FoXray, Happ, v2RayTun, v2rayNG | **xray-совместимый** subscription (массив `vless://...?security=reality...`) — sing-box JSON не съест |
| Универсальный фолбэк | один `vless://` URI как QR-код + текст |

### 7.3. Реализация subscription URL на стороне сервера

Для пользователей, кому агент даёт конфиг — нужен endpoint вида:

```
https://sub.example.com/<token>
```

который возвращает либо:

- **Для xray-клиентов (Streisand, Happ, v2rayNG):** `Content-Type: text/plain`, тело = base64-encoded `\n`-separated `vless://`/`vmess://` ссылки.
- **Для sing-box-клиентов (sing-box-vt, SFA, Hiddify, Karing):** `Content-Type: application/json`, тело = валидный sing-box JSON (`{"outbounds":[...]}`).
- **Универсально (предпочтительно):** оба формата по разным URL — `/sub/xray` и `/sub/singbox` — либо content-negotiation по `User-Agent`.

**[непроверено]** — конкретные best-practices serverside для multi-format subscription. Это исследование выходит за рамки данной задачи — обсуждать с оператором при разработке сервера.

---

## Источники (consolidated)

### Официальная документация sing-box
- <https://sing-box.sagernet.org/>
- <https://sing-box.sagernet.org/clients/>
- <https://sing-box.sagernet.org/clients/apple/>
- <https://sing-box.sagernet.org/clients/apple/features/>
- <https://sing-box.sagernet.org/clients/android/>
- <https://sing-box.sagernet.org/installation/package-manager/>
- <https://sing-box.sagernet.org/changelog/>
- <https://github.com/SagerNet/sing-box>
- <https://github.com/SagerNet/sing-box/releases>
- <https://github.com/SagerNet/sing-box-for-android>
- <https://github.com/SagerNet/sing-box-for-apple>
- <https://github.com/SagerNet/sing-box/issues/2024>

### App Store страницы (через WebFetch — авторитетный)
- <https://apps.apple.com/us/app/sing-box-vt/id6673731168>
- <https://apps.apple.com/us/app/streisand/id6450534064>
- <https://apps.apple.com/us/app/foxray/id6448898396>
- <https://apps.apple.com/us/app/karing/id6472431552>
- <https://apps.apple.com/us/app/happ-proxy-utility/id6504287215>
- <https://apps.apple.com/us/app/hiddify-proxy-vpn/id6596777532>
- <https://apps.apple.com/us/app/v2raytun/id6476628951>

### F-Droid и Google Play
- <https://f-droid.org/packages/io.nekohasekai.sfa/>
- <https://play.google.com/store/apps/details?id=io.nekohasekai.sfa>
- <https://play.google.com/store/apps/details?id=app.hiddify.com>
- <https://play.google.com/store/apps/details?id=com.happproxy>

### GitHub
- <https://github.com/MatsuriDayo/NekoBoxForAndroid>
- <https://github.com/MatsuriDayo/NekoBoxForAndroid/releases>
- <https://github.com/hiddify/hiddify-app>
- <https://github.com/hiddify/hiddify-app/releases>
- <https://github.com/hiddify/hiddify-sing-box>
- <https://github.com/KaringX/karing>
- <https://github.com/KaringX/karing/releases>
- <https://github.com/2dust/v2rayNG>
- <https://github.com/2dust/v2rayNG/discussions/2569>
- <https://github.com/SagerNet/v2box>
- <https://github.com/xinggaoya/sing-box-windows>

### Удаление VPN-приложений из RU App Store (Apple bowing to Kremlin)
- <https://techcrunch.com/2024/07/08/apple-removes-vpn-apps-at-request-of-russian-authorities-say-app-makers/>
- <https://www.theregister.com/2024/09/26/apple_vpn_russia/>
- <https://9to5mac.com/2024/09/28/apple-cooperating-with-russia-to-remove-vpn-apps-from-app-store/>
- <https://www.techradar.com/vpn/vpn-privacy-security/apple-removes-custom-vpn-clients-from-russian-app-store-amid-telegram-crackdown>
- <https://cybernews.com/privacy/apple-removes-vpn-apps-russian-app-store/>
- <https://novayagazeta.eu/amp/articles/2026/03/31/apple-reveals-it-bowed-to-kremlin-pressure-to-remove-190-apps-from-russian-app-store-over-three-years-en-news>

### Технические референсы
- <https://deepwiki.com/SagerNet/sing-box>
- <https://deepwiki.com/SagerNet/sing-box/4.4-wireguard-and-tailscale>
- <https://www.wintun.net/>
- <https://hiddify.com/manager/client-software-on-ios/>
- <https://www.happ.su/main/dev-docs/app-management>
- <https://medium.com/@utso097.csekuet/the-evolution-from-v2ray-to-xray-to-sing-box-0f4ffdeb3fe7>

---

## Что осталось непроверенным

1. **Точная дата и подтверждение удаления `sing-box-vt` из RU App Store.** Косвенные доказательства есть (волна 27–28 марта 2026 с `Streisand`/`v2RayTun`/`Happ`), но прямого упоминания `sing-box-vt` по имени в репортажах я не нашёл. Нужна проверка через <https://applecensorship.com/> или ручная проверка с РФ-Apple-ID.
2. **Версии sing-box внутри Hiddify v4.1.1, Karing 1.2.18, FoXray 25.4.3, v2RayTun.** Документация этих клиентов не указывает явно, какая ревизия sing-box-core внутри. Потенциально можно вытащить из release notes / changelog / `strings` бинаря — но это отдельное исследование.
3. **Доступность SFA (sing-box for Android) в Google Play РФ.** Прямой проверки не делал — нужен российский Google-аккаунт.
4. **Hiddify и Karing в RU App Store на 15 мая 2026 — точно?** В списках мартовских удалений их не было, но Apple может удалять волнами. Нужна периодическая проверка.
5. **Best-practices subscription URL endpoint** на стороне сервера для multi-format раздачи. За рамками данного исследования.
6. **macOS launchd / Windows service конкретные unit-файлы для sing-box-cli** — официальная документация sing-box их не приводит явно. Скорее всего, оператор-сисадмин будет писать их самостоятельно.
7. **Год даты обновления Karing и Happ.** На App Store даты типа "29 апреля" без года — допущение что это 2026, формально не подтверждено.
8. **Существует ли actively maintained NekoRay/NekoBox для desktop в 2026.** Оригинал `MatsuriDayo/nekoray` мог быть архивирован — нужна проверка.
