# Рецепты sing-box-конфигов

Готовые шаблоны для скилла `/generate-client-config`, под разные платформы
и сценарии маршрутизации. Все шаблоны под совместимость **sing-box 1.11.x**
(нижняя планка — sing-box-vt на iOS, см. `client-apps.md` §9).

## Рецепт 1: Универсальный (mixed-inbound, без TUN)

Подходит для импорта в Hiddify-app (он сам обернёт в TUN при включении VPN),
NekoBox, Karing, sing-box-vt.

```json
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": 2080
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "vless-out",
      "server": "<HOST>",
      "server_port": <PORT>,
      "uuid": "<UUID>",
      "flow": "<FLOW>",
      "network": "tcp",
      "tls": {
        "enabled": true,
        "server_name": "<SNI>",
        "utls": { "enabled": true, "fingerprint": "chrome" },
        "reality": {
          "enabled": true,
          "public_key": "<PUBLIC_KEY>",
          "short_id": "<SHORT_ID>"
        }
      }
    },
    { "type": "direct", "tag": "direct-out" }
  ],
  "route": {
    "rule_set": [
      {
        "type": "remote", "tag": "geoip-ru", "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs",
        "update_interval": "1d"
      },
      {
        "type": "remote", "tag": "geosite-category-ru", "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ru.srs",
        "update_interval": "1d"
      }
    ],
    "rules": [
      { "rule_set": ["geoip-ru", "geosite-category-ru"], "outbound": "direct-out" },
      { "ip_is_private": true, "outbound": "direct-out" }
    ],
    "final": "vless-out",
    "auto_detect_interface": true
  }
}
```

## Рецепт 2: iOS с TUN (через Hiddify/Karing)

Для iOS — `inet4_address` + `inet6_address` (формат 1.9, до объединения
в `address` в 1.10). Hiddify-app на iOS работает на форке sing-box, который
поддерживает оба формата, но для совместимости с старыми клиентами оставляем
разделённый формат.

**Ограничения iOS** (см. `client-apps.md` §2.3):
- Нет `strict_route`.
- Нет `process_name`/`process_path`.
- Нет `include_uid`/`exclude_uid`.
- Нет `gso`.

```json
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "inet4_address": "172.19.0.1/30",
      "inet6_address": "fdfe:dcba:9876::1/126",
      "auto_route": true,
      "stack": "system"
    }
  ],
  "outbounds": [ /* vless-out + direct-out как в Рецепте 1 */ ],
  "route": { /* как в Рецепте 1 */ }
}
```

## Рецепт 3: Android с TUN (через Hiddify/NekoBox/SFA)

Похоже на iOS, но поддерживает `package_name` для process-based routing.

```json
{
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "inet4_address": "172.19.0.1/30",
      "inet6_address": "fdfe:dcba:9876::1/126",
      "auto_route": true,
      "stack": "system"
    }
  ],
  /* outbounds как в Рецепте 1 */
  "route": {
    "rules": [
      /* РФ-трафик direct */
      { "rule_set": ["geoip-ru", "geosite-category-ru"], "outbound": "direct-out" },
      { "ip_is_private": true, "outbound": "direct-out" },
      /* Опционально: список приложений через VPN */
      {
        "package_name": ["org.telegram.messenger", "com.whatsapp"],
        "outbound": "vless-out"
      }
    ],
    "final": "vless-out"
  }
}
```

## Рецепт 4: Desktop с TUN и auto-redirect (Linux/macOS/Windows)

Linux: `auto_redirect: true` рекомендуется (лучше tproxy, авто nftables).
Windows: `strict_route: true` против DNS-leak.
macOS: `auto_redirect` работает только в недавних версиях, иначе через
NetworkExtension.

```json
{
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
      "auto_route": true,
      "auto_redirect": true,
      "strict_route": true,
      "stack": "mixed",
      "mtu": 1500
    }
  ],
  /* outbounds как в Рецепте 1 */
  "route": {
    /* rules как в Рецепте 3, плюс опционально process_name */
    "rules": [
      { "rule_set": ["geoip-ru", "geosite-category-ru"], "outbound": "direct-out" },
      { "ip_is_private": true, "outbound": "direct-out" },
      {
        "process_name": ["telegram-desktop", "firefox", "chrome"],
        "outbound": "vless-out"
      }
    ],
    "final": "vless-out",
    "auto_detect_interface": true
  }
}
```

## Рецепт 5: Multi-server selector (несколько серверов с переключением)

Для случая, когда оператор хочет вручную переключаться между серверами
(например, Германия / Финляндия / Нидерланды).

```json
{
  "outbounds": [
    { "type": "vless", "tag": "server-de", "server": "de.example.com", ... },
    { "type": "vless", "tag": "server-fi", "server": "fi.example.com", ... },
    { "type": "vless", "tag": "server-nl", "server": "nl.example.com", ... },
    {
      "type": "selector",
      "tag": "select",
      "outbounds": ["server-de", "server-fi", "server-nl"],
      "default": "server-de",
      "interrupt_exist_connections": false
    },
    { "type": "direct", "tag": "direct-out" }
  ],
  "route": { "final": "select" },
  "experimental": {
    "clash_api": { "external_controller": "127.0.0.1:9090" }
  }
}
```

**Управление selector** — через Clash API (`external_controller`). Hiddify/NekoBox
имеют встроенный UI для переключения selector. Без UI — через HTTP запрос
к Clash API.

## Рецепт 6: Multi-server urltest (авто-выбор быстрого)

Альтернатива selector — `urltest` автоматически выбирает сервер с наименьшим
ping. Каждые 3 минуты переоценивает.

```json
{
  "outbounds": [
    /* server-de, server-fi, server-nl */
    {
      "type": "urltest",
      "tag": "auto",
      "outbounds": ["server-de", "server-fi", "server-nl"],
      "url": "https://www.gstatic.com/generate_204",
      "interval": "3m",
      "tolerance": 50,
      "idle_timeout": "30m"
    },
    { "type": "direct", "tag": "direct-out" }
  ],
  "route": { "final": "auto" }
}
```

## Использование рецептов скиллом

Скилл `/generate-client-config` использует:
- **Рецепт 1 (universal)** — по умолчанию.
- **Рецепт 2/3/4** — при `PLATFORM=ios|android|desktop`.
- **Рецепт 5/6** — при `MULTI_SERVER=yes` (генерация общего конфига для
  нескольких inbound из одной панели).

Конкретные значения подставляются автоматически через `parse-vless-link.sh`
+ jq-шаблонизация.

## Связанные документы

- `platform-quirks.md` (в этом же скилле) — ограничения и особенности
  платформ при импорте sing-box JSON.
- `../../knowledge/networking/_reference/client-apps.md` — карта клиентов и форматов.
- `../../knowledge/networking/_reference/vpn-protocols.md` §4 — multi-hop теория.

---

*Документ обновляется при появлении новых паттернов маршрутизации.*
