---
knowledge_domain: vpn
layer: reference
last_researched: 2026-05-22
ttl_days: 60
sources_checked:
  - https://xtls.github.io/config/outbound/sockopt.html#dialerproxy
  - https://github.com/anthropics/claude-code/issues/3387
  - https://www.privoxy.org/user-manual/config.html
  - практический опыт настройки (2026-05-22)
---

# xray chain на macOS: NurVPN bypass + Blanc USA

Настройка двухзвенной цепочки xray на Mac для обхода белых списков (ТСПУ)
с выходом через US-IP для работы с нейросетями (Claude Code / VSCode).

Читают: персона при ответах про обход WL на десктопе; скиллы
`/configure-vpn-routing`, `/generate-client-config` (desktop-часть).

---

## Архитектура решения

```
VSCode/Claude Code
    ↓ HTTP_PROXY=http://127.0.0.1:8118
privoxy (SOCKS→HTTP bridge)
    ↓ forward-socks5 → 127.0.0.1:10808
xray (SOCKS inbound :10808)
    ↓ dialerProxy: "nur-bypass"
NurVPN gRPC+Reality (обход WL, маскировка под ads.x5.ru)
    ↓
Blanc USA VLESS+TLS (exit IP)
    ↓
api.anthropic.com / интернет
```

Ключевой принцип: **proxy-only, без TUN/route/DNS**. Работает параллельно
с sing-box (который обслуживает браузер и остальной трафик).

---

## Почему именно xray, а не sing-box

sing-box НЕ поддерживает chain VLESS→VLESS через `detour`. Issue закрыт как
"not planned" (SagerNet/sing-box#1562). Работает только detour с Shadowsocks,
Trojan или SOCKS.

xray поддерживает произвольные chain через `sockopt.dialerProxy` — outbound
указывает имя другого outbound как транзитный. Работает для любых протоколов.

---

## Компоненты

### 1. xray chain config (`~/.config/xray/chain-config.json`)

Два inbound:
- `socks-in` на :10808 (UDP enabled, sniffing)
- `http-in` на :10809 (запасной)

Два outbound в chain:
- `blanc-usa` — VLESS+TLS:8443, SNI cdn2-07.vk-cdnvideo.com, `dialerProxy: "nur-bypass"`
- `nur-bypass` — VLESS+Reality+gRPC:443, serverName ads.x5.ru

Routing: RU-домены и RU-IP → direct, остальное → blanc-usa (default first outbound).

Важно: только серия NurVPN 5.x (gRPC) поддерживает chain. Серии 2.x-4.x (Vision)
НЕ работают как transit в dialerProxy.

### 2. privoxy (`/opt/homebrew/etc/privoxy/config`)

```
forward-socks5 / 127.0.0.1:10808 .
```

Зачем: Claude Code (undici) НЕ поддерживает SOCKS5 proxy. Только http:// или
https:// в переменных окружения. GitHub issue #3387 закрыт "not planned".
privoxy слушает :8118 и конвертирует HTTP CONNECT → SOCKS5.

### 3. launchctl setenv

```bash
launchctl setenv HTTPS_PROXY http://127.0.0.1:8118
launchctl setenv HTTP_PROXY  http://127.0.0.1:8118
```

macOS GUI-приложения (VSCode) не наследуют shell environment. Единственный
способ передать proxy — `launchctl setenv` + перезапуск приложения.

### 4. Перезапуск VSCode

VSCode кеширует env при запуске. После `launchctl setenv` нужен полный
перезапуск (quit → sleep 2 → open), иначе proxy не подхватится.

---

## Скрипты управления

### vpn-on.sh (`~/.config/xray/vpn-on.sh`)

1. Проверка — не запущен ли уже (PID-файл)
2. `nohup xray run -config chain-config.json` → PID-файл
3. Проверка что xray жив через 2 секунды
4. `brew services start privoxy`
5. `launchctl setenv HTTPS_PROXY / HTTP_PROXY`
6. Перезапуск VSCode
7. Уведомление "WL включён"

### vpn-off.sh (`~/.config/xray/vpn-off.sh`)

1. Kill xray по PID-файлу
2. `brew services stop privoxy`
3. `launchctl unsetenv HTTPS_PROXY / HTTP_PROXY`
4. Перезапуск VSCode
5. Уведомление "WL выключен"

### emergency-reset.sh (`~/.config/xray/emergency-reset.sh`)

Ядерный сброс на случай полной потери сети:
- killall xray, tun2proxy, privoxy
- Удаление маршрутов 198.18.0.1, 10.0.0.1
- DNS → empty (системный)
- Отключение всех system proxy (networksetup)
- unsetenv HTTPS_PROXY, HTTP_PROXY

---

## Что НЕ работает (антипаттерны)

### tun2proxy — НЕ использовать

- Конфликтует с sing-box (оба правят routes и DNS)
- Ставит DNS на 198.18.0.2 или 10.0.0.1 и не чистит при остановке
- Требует sudo, что несовместимо с SwiftBar/Shortcuts
- После остановки часто требуется перезагрузка Mac

### networksetup (system proxy) — НЕ использовать при работающем sing-box

- sing-box сам идёт через system proxy → loop → полная потеря сети
- Даже `networksetup -setsocksfirewallproxy` ломает sing-box routing
- Отключение system proxy иногда не восстанавливает сеть без перезагрузки

### Прямое прописывание proxy в VSCode settings.json

- `http.proxy` в settings.json НЕ влияет на Claude Code API calls
- Claude Code использует undici напрямую, только env vars HTTP(S)_PROXY работают
- `http.proxySupport: "on"` тоже бесполезен для этого случая

---

## UX-интеграция

Пользователь вызывает через macOS Shortcuts (быстрые команды):
- "WL ON" → `~/.config/xray/vpn-on.sh`
- "WL OFF" → `~/.config/xray/vpn-off.sh`

Запасные .command-файлы на рабочем столе (двойной клик):
- `WL ON.command`, `WL OFF.command`, `СБРОС СЕТИ.command`

---

## Совместимость с sing-box

xray chain работает ПАРАЛЛЕЛЬНО с sing-box:
- sing-box обслуживает весь трафик через TUN (браузер, приложения)
- xray обслуживает только то, что идёт через proxy (VSCode/Claude Code)
- Конфликтов нет, потому что xray НЕ трогает routes, DNS или system proxy

При выключенном sing-box: xray работает только для VSCode. Браузер идёт
напрямую (без VPN). Это нормально — основной use case: sing-box для всего +
xray поверх для Claude Code через chain bypass.

---

## Серверы в конфиге (май 2026)

Transit (NurVPN bypass, серия 5.x gRPC):
- api.st.nurcloud.org:443, Reality, SNI: ads.x5.ru, serviceName: adsx5

Exit (Blanc USA):
- 213.171.31.2:8443 (NYC), SNI: cdn2-07.vk-cdnvideo.com
- 82.202.140.29:8443 (LA), SNI: cdn5-19.vk-cdnvideo.com
- 84.32.184.93:8443 (Houston), SNI: cdn1-42.vk-cdnvideo.com
- 62.233.43.150:8443 (San Jose), SNI: cdn4-65.vk-cdnvideo.com
- 82.202.159.156:8443 (Miami), SNI: cdn8-90.vk-cdnvideo.com

UUID Blanc: 8c8f0fd6-4636-465d-af60-8dc3b6bc68df (общий для всех)
