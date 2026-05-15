# Платформенные ограничения sing-box-конфигов

Что недоступно/работает иначе на каждой платформе. Используется скиллом
`/generate-client-config` для адаптации генерируемых конфигов.

## iOS — самая ограниченная

| Фича | Доступность |
|---|---|
| TUN inbound | ✅ только |
| mixed/socks/http inbound | ❌ (system VPN ограничения) |
| `strict_route` | ❌ |
| `gso` | ❌ |
| `include_interface`/`exclude_interface` | ❌ |
| `include_uid`/`exclude_uid` | ❌ |
| `process_name`/`process_path` | ❌ |
| `wifi_ssid`/`wifi_bssid` | ✅ только iOS |
| `package_name` | ❌ (это Android) |
| AnyTLS / TLS-fragment / evaluate | ❌ (фичи 1.12+) |

**Версия sing-box:** 1.11.4 (застрял на этой ветке с февраля 2025).

**Memory limit:** Apple NetworkExtension ~50 МБ. Большие rule-set могут крашить.

**Рекомендация:** генерировать конфиг под нижнюю планку, использовать только
поля из ветки 1.11.x.

## macOS — почти как iOS

| Фича | Доступность |
|---|---|
| TUN inbound | ✅ |
| mixed inbound | ✅ если запускать sing-box CLI |
| `strict_route` | ✅ через CLI, ❌ через App Store-версии |
| `process_name`/`process_path` | ❌ |
| `wifi_ssid`/`wifi_bssid` | ❌ (только iOS) |
| Auto-redirect (новые версии) | ⚠️ только sing-box mainline 1.13+ |

**Версия:** sing-box-vt — 1.11.4. Hiddify-cli/Karing — собственные форки.
sing-box CLI через brew — мейнлайн.

## Android — больше возможностей

| Фича | Доступность |
|---|---|
| TUN inbound | ✅ |
| `package_name` / `package_name_regex` | ✅ Android только |
| `process_name`/`process_path` | ❌ (нет доступа на Android) |
| `wifi_ssid` | ⚠️ требует разрешение |
| Stack: system / gvisor / mixed | все три |
| AnyTLS (1.12+) | ⚠️ через свежие версии NekoBox preview |

**Версия:** NekoBox stable — 1.12.12-neko-1. SFA F-Droid — 1.13.11.
Hiddify — собственный форк.

## Desktop (Linux/macOS/Windows через sing-box CLI или Hiddify)

| Фича | Доступность |
|---|---|
| TUN inbound | ✅ |
| Все TUN-опции (`strict_route`, `auto_redirect`, `auto_route`) | ✅ |
| `process_name` / `process_path` / `process_path_regex` | ✅ |
| Stack: system / gvisor / mixed | ✅ |
| AnyTLS, TLS-fragment, evaluate (1.12+/1.14+) | ✅ если sing-box ≥ нужной |
| WinTun (Windows) | ✅ автоматически |

**Версия:** sing-box mainline 1.13.12. Hiddify Desktop ~1.12.

## Linux-специфика

- `auto_redirect: true` **рекомендуется** (лучше tproxy, авто nftables, без
  ручной настройки).
- Требует CAP_NET_ADMIN — systemd unit ставит автоматически через package.
- Process-based routing работает только при запуске под root (нужен доступ
  к `/proc/<pid>`).

## Windows-специфика

- `strict_route: true` **рекомендуется** (защита от DNS-leak).
- Использует WinTun (не TAP-Windows).
- Запуск как Windows-service — через `nssm` или `sc create` (нет встроенного
  install-service в sing-box).

## macOS-специфика

- Через NetworkExtension API (с App Store-версий sing-box-vt / Hiddify).
- root не нужен.
- Через `sing-box-cli` запущенный как daemon — нужен root для TUN.
- `auto_redirect` доступен только на mainline 1.13+ (на форках Hiddify
  обычно нет).

## Стратегия адаптации в скилле

`/generate-client-config` выбирает шаблон на основе `PLATFORM`:

| PLATFORM | Inbound | Strict-fields | Поля 1.12+ |
|---|---|---|---|
| `ios` | TUN с inet4/inet6_address | без strict_route, process_*, package_* | ❌ |
| `android` | TUN с inet4/inet6_address | без process_*, можно package_* | ⚠️ только если nekoBox preview |
| `desktop` | TUN с address (1.10+) + auto_redirect | все доступны | ✅ |
| `universal` | mixed inbound на 127.0.0.1 | минимум полей — везде работает | ❌ |

При сомнении — `universal` (mixed-inbound) — сработает на iOS, macOS,
Windows, Linux. Минус: оператору надо настроить системный прокси
вручную, либо использовать Hiddify, который сам обернёт mixed в TUN
при включении VPN.

## Apple App Store nuance

На 2026-05-15:
- **Не удалены из RU App Store**: Hiddify Proxy & VPN, Karing.
- **Удалены ~27-28 марта 2026**: Streisand, v2Box, v2RayTun, Happ.
- **sing-box-vt** — статус по RU App Store **не подтверждён** (ID 6673731168).

При генерации конфига для iPhone — скилл напоминает оператору, какой клиент
рекомендован (Hiddify или Karing), особенно если устройство новое или
переустановка приложения.

## Связанные документы

- `singbox-config-recipes.md` (в этом же скилле) — готовые шаблоны.
- `../../knowledge/networking/client-apps.md` — карта клиентов.

---

*Документ обновляется при изменении ограничений iOS/Android API или при
изменении доступности клиентов в App Store / Google Play.*
