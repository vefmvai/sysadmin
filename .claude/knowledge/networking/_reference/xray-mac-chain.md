---
knowledge_domain: vpn
layer: reference
last_researched: 2026-08-11
ttl_days: 60
sources_checked:
  - https://xtls.github.io/config/outbound/sockopt.html#dialerproxy
  - https://github.com/anthropics/claude-code/issues/3387
  - https://www.privoxy.org/user-manual/config.html
  - https://code.claude.com/docs/en/network-config
  - https://github.com/SagerNet/sing-box/issues/1562
  - https://github.com/SagerNet/sing-box/issues/3205
  - https://xtls.github.io/en/config/transports/grpc.html
  - https://github.com/MHSanaei/3x-ui/issues/5143
  - практический опыт настройки (2026-05-22)
---

# xray chain на macOS: обход белого списка провайдера + свой выход в США

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
транзит gRPC+Reality (обход белых списков, маскировка под чужой популярный домен)
    ↓
Второй хоп: VLESS+TLS, выход в США (exit IP)
    ↓
api.anthropic.com / интернет
```

Ключевой принцип: **proxy-only, без TUN/route/DNS**. Работает параллельно
с sing-box (который обслуживает браузер и остальной трафик).

---

## Почему именно xray, а не sing-box

sing-box НЕ поддерживает chain VLESS→VLESS через `detour`. Issue закрыт как
"not planned" (SagerNet/sing-box#3205 «Detour doesnt work on outbound protocols»;
не путать с #1562 — тот про WireGuard и к цепочкам отношения не имеет). Работает
только detour с Shadowsocks, Trojan или SOCKS.

Оговорка про этот список: #3205 подтверждает его не полностью — в самом issue
речь о падении связки VLESS→Trojan, тогда как здесь Trojan назван рабочим
транспортом detour. Перечень рабочих транзитов в issue другой: detour между
outbound-протоколами работает только через SOCKS, HTTP и SSH — Shadowsocks в
этом перечне не назван. Значит, и Shadowsocks, и Trojan — проверять на своём
стенде, прежде чем на них закладываться.

xray поддерживает произвольные chain через `sockopt.dialerProxy` — outbound
указывает имя другого outbound как транзитный. Работает для любых протоколов.

---

## Компоненты

### 1. xray chain config (`~/.config/xray/chain-config.json`)

Два inbound:
- `socks-in` на :10808 (UDP enabled, sniffing)
- `http-in` на :10809 (запасной)

Два outbound в chain (имена условные, значения — из подписки оператора, не отсюда):
- выходной — VLESS+TLS:8443, SNI из подписки, `dialerProxy` указывает на транзитный
- транзитный — VLESS+Reality+gRPC:443, `serverName` из подписки

Routing: RU-домены и RU-IP → direct, остальное → второй хоп (default first outbound).

Важно: chain поддерживает не всякая серия узлов провайдера — нужна на gRPC-транспорте. Серии на XTLS-Vision
НЕ работают как transit в dialerProxy.

> **Транспорт помечен к удалению.** Xray-core при старте пишет в лог, что
> gRPC-транспорт устарел, не рекомендуется к использованию и может быть удалён, и
> советует переходить на XHTTP stream-up H2. Предупреждение наблюдалось на сборках
> ядра 26.4.25 (лог в issue MHSanaei/3x-ui#4989) и 26.6.1 (MHSanaei/3x-ui#5143).
> Та же рекомендация — в официальной документации транспорта (xtls.github.io,
> `config/transports/grpc`), блок DANGER «It is recommended to switch to XHTTP».
> Сегодня gRPC-транзит работает, но вся цепочка стоит на уходящем транспорте: при
> выборе новой серии узлов у провайдера смотреть в сторону XHTTP и отдельно
> проверять, годится ли она как transit в `dialerProxy` — своей проверки на
> XHTTP-транзите у нас нет.

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

macOS GUI-приложения (VSCode) не наследуют shell environment. Для самого VSCode
способ передать proxy один — `launchctl setenv` + перезапуск приложения.

Для Claude Code launchctl закрывает не все случаи: двум классам сессий — фоновым
и Desktop-managed — его мало. Те же переменные задаются в блоке `env` файла
`~/.claude/settings.json` — сам блок существует давно, новое здесь другое
(сверено по code.claude.com/docs/en/network-config, 11.08.2026):

- **Фоновые сессии** (`claude agents`, `--bg`) запускает супервизор вне терминала,
  и окружение шелла до него может вообще не дойти; документация называет
  настройки единственной конфигурацией, которая доходит до каждой фоновой сессии
  на каждой машине. Для оператора это главный аргумент: обычные сессии из VSCode
  и CLI переменную из launchctl подхватывают, фоновые — нет.
- **С v2.1.217 (21.07.2026)** в сессиях, где соединением управляет приложение
  Claude Desktop, Claude Code читает `HTTP_PROXY`, `HTTPS_PROXY` и `NO_PROXY`
  только из managed settings и `~/.claude/settings.json` — значение из launchctl
  туда не доедет. Класс сессий узкий, у оператора (VSCode + CLI) не срабатывает,
  но помнить стоит.

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
- Claude Code использует undici напрямую: proxy он берёт из env vars HTTP(S)_PROXY,
  а в Desktop-managed сессиях — только из настроек (см. раздел 3)
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

## Серверы в конфиге

**Здесь сознательно НЕТ ни адресов, ни SNI, ни UUID.** Это репозиторий мозга агента —
он публичный и универсальный (C.4). Конкретные серверы подписки, их SNI и клиентский
UUID живут в приватной зоне оператора: `inventory/shared/vpn-subscriptions/`
(в `.gitignore`) и в менеджере паролей.

Структура цепочки, которую надо знать для понимания документа:

| Звено | Что это | Где взять значения |
|---|---|---|
| Transit | вход подписки-обходчика, Reality с чужим SNI и `serviceName` | подписка провайдера |
| Exit | выходные узлы нужной страны, тот же клиентский UUID на всех | подписка провайдера |

> **Ожог 2026-08-04.** До этой правки здесь лежали пять выходных узлов с адресом,
> портом и SNI и **клиентский UUID подписки одной строкой**. То есть полный комплект
> для подключения к чужой оплаченной подписке — в открытом репозитории. Заметили при
> подготовке замка на приватные данные, а не проверкой секретов: `gitleaks` такое не
> ловит, он знает форматы токенов известных сервисов, а «UUID рядом с названием провайдера»
> для него обычная строка. Отсюда правило: **удаление из файла не отменяет ротацию** —
> история публичного репозитория остаётся доступной, UUID обязан быть перевыпущен.
