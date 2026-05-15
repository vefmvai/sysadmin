# Форматы subscription URL разных провайдеров

Subscription URL — это HTTP(S)-endpoint, который возвращает список VPN-серверов
в одном из форматов. Скрипт `parse-subscription.sh` поддерживает только
**xray-формат** (base64 или plain text список vless://-ссылок). Sing-box JSON
и Clash YAML — НЕ поддерживаются (для них клиент должен использовать
другой User-Agent).

## Формат 1: base64-encoded plain text

Самый частый формат у российских платных провайдеров (Blanc VPN, Bebra VPN
и подобных). Endpoint возвращает:

```
Content-Type: text/plain
Body: dmxlc3M6Ly91dWlkLTFAaG9zdDE6NDQzPy4uLg0Kdmxlc3M6Ly91dWlkLTJAaG9zdDI6NDQzPy4uLg==
```

После base64-decode:
```
vless://uuid-1@host1:443?...
vless://uuid-2@host2:443?...
```

Скрипт `parse-subscription.sh` распознаёт автоматически (эвристика: вся
строка матчит `^[A-Za-z0-9+/=\s]+$` и не содержит `://`).

## Формат 2: Plain text (без base64)

Некоторые провайдеры отдают сразу без base64:

```
Content-Type: text/plain
Body:
vless://uuid-1@host1:443?...
vless://uuid-2@host2:443?...
```

Скрипт распознаёт автоматически по присутствию `://`.

## Формат 3: Sing-box JSON

Некоторые провайдеры (особенно международные) при определённом User-Agent
отдают sing-box JSON:

```json
{
  "outbounds": [
    { "type": "vless", "tag": "server-1", "server": "host1", ... },
    ...
  ],
  "route": { "rules": [...] }
}
```

**Этот формат скрипт НЕ обрабатывает.** Если попался — заменить User-Agent
запроса на `v2rayN/6.42`, `v2rayNG/1.x`, `nekoray/3.x` или похожий — провайдер
обычно отдаёт xray-формат для них.

Override через ENV:
```bash
USER_AGENT='v2rayN/6.42 (Windows; X64)' ./parse-subscription.sh
```

## Формат 4: Clash YAML

Реже у современных провайдеров. Формат:

```yaml
proxies:
  - name: server-1
    type: vless
    server: host1
    port: 443
    uuid: ...
    ...
```

**Не поддерживается этим скриптом.** Конвертация в xray-формат — отдельная
задача (есть утилиты типа `subconverter`, но это уже за рамками сисадмина —
если провайдер отдаёт только Clash, оператор сменит User-Agent или провайдера).

## Заголовки User-Agent — рекомендации

Большинство провайдеров отдают формат по User-Agent:

| User-Agent | Формат |
|---|---|
| `v2rayN`, `v2rayNG`, `nekoray`, `v2rayN/x.x` | xray (base64 vless://) |
| `sing-box`, `SFI`, `SFA` | sing-box JSON |
| `Clash`, `clash.meta`, `mihomo` | Clash YAML |
| `Hiddify` | mix — иногда хитро отдаёт hiddify://-URI |

Дефолт скрипта — `v2rayN/6.42 (Windows; X64)` — даёт xray-формат у большинства.

## HTTP-заголовки от провайдера

Провайдер может вернуть полезные мета-заголовки:

- `Profile-Title: "My VPN"` — название профиля (отображается в Hiddify).
- `Subscription-Userinfo: upload=...; download=...; total=...; expire=...`
  — квота трафика и срок (формат clash subscription).

Эти заголовки скрипт игнорирует — он работает только с телом ответа.
Если оператору важен заголовок `Subscription-Userinfo` (для отслеживания
квоты) — это отдельная задача мониторинга, не configure-routing.

## Известные провайдеры (по комьюнити-сведениям)

> ⚠️ Список не реклама и не рекомендация. Это карта местности для агента,
> чтобы понимать, что приходит от популярных платных VPN-провайдеров в РФ.
> Ответственность за выбор провайдера и legality — на операторе.

| Провайдер | Формат подписки | Особенности |
|---|---|---|
| Blanc VPN | base64 vless:// | Может присылать 5-10 серверов на разные страны |
| Bebra VPN | base64 vless:// | Аналогично |
| Happ-обёртка от других | Через приложение, не подписка | Не работает в скрипте |
| 3X-UI у других операторов | base64 vless:// (стандарт panel) | Если другой оператор делится — стандартный формат |

## Что НЕ работает (явные случаи)

- **NordVPN, ExpressVPN, Surfshark, ProtonVPN** — закрытые «только приложение»,
  не отдают vless://-конфиг.
- **Бесплатные «free VPN»** — security risk (см. `vpn-protocols.md` §6.2),
  скрипт отказывается с предупреждением.
- **iTOPVPN, PrivadoVPN** — собственный протокол, не подписки.

## Если провайдер вернул что-то странное

Дебaг-шаги:
1. `curl -sI <SUBSCRIPTION_URL>` — посмотреть заголовки и Content-Type.
2. `curl -s <URL> | head -c 500` — первые 500 байт.
3. Попробовать разные User-Agent.
4. Спросить у провайдера, какой формат для xray/v2ray.

Если ничего не работает — оператору проще получить **один прямой
vless://-link** из приложения провайдера (раздел «копировать конфиг» или
«экспорт») и подать его через `UPSTREAM_VPN_URL`, минуя subscription.

## Связанные документы

- `multi-hop-architectures.md` — два пути outbound (подписка vs свой VPS).
- `client-apps.md` (knowledge/networking/) — форматы для клиентов на устройствах.

---

*Документ обновляется при появлении новых популярных форматов подписок.*
