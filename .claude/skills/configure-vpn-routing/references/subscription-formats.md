# Форматы подписок — переехало

Подробный разбор форматов тела подписки (base64-список `vless://`, plain-text,
**Xray-JSON массив профилей**, sing-box JSON, **HWID-locked**) и логика извлечения
теперь живут в скилле, который этим и занимается:

→ **`.claude/skills/extract-subscription-servers/references/subscription-formats.md`**
→ **`.claude/skills/extract-subscription-servers/references/hwid-mechanism.md`**

`configure-vpn-routing` извлечением не занимается — он работает с уже готовым
JSON-массивом серверов, который `/extract-subscription-servers` сохранил в
`$INFRA/inventory/shared/vpn-subscriptions/<provider>.json` (см. Шаг 5A.1).

Этот файл оставлен как указатель, чтобы старые ссылки не вели в никуда.
