# Networking knowledge — карта домена

Доменная база знаний агента-сисадмина по VPN, обходу блокировок, 3X-UI, клиентам.
Разделена на три слоя с разными TTL — потому что реальность VPN-фронта живёт в разных
скоростях: фронт блокировок меняется неделями, устройство протоколов — кварталами,
источники и термины — годами.

Формальное обоснование структуры — ADR-0006 «Слоистая архитектура VPN-knowledge».
Базовая архитектура knowledge — ADR-0003.

---

## 1. Три слоя

| Слой | Что хранит | TTL | Когда обновлять |
|---|---|---|---|
| `_live/` | Фронт борьбы по странам, хронология ударов | 14 дней | Каждые ~2 недели или при крупном событии |
| `_reference/` | Протоколы, панель, клиенты, транспорты, fronting-стратегии | 60 дней | Раз в 2 месяца или при breaking release |
| `_meta/` | Реестр источников, глоссарий, конфликты | 365 дней | Почти никогда, только по запросу |

---

## 2. Каталог

### `_live/` — фронт борьбы (TTL 14 дней)

| Файл | Что внутри |
|---|---|
| `frontline-ru.md` | Что работает / не работает / под угрозой в РФ-2026 на дату исследования |
| `frontline-cn.md` | Китай — опережает РФ на 6-12 мес, карта будущего |
| `frontline-ir.md` | Иран — сильные DPI-обходы, арсенал-донор |
| `frontline-by.md` | Беларусь — копирует РКН с лагом 0-3 мес, индикатор |
| `timeline.md` | Append-only хронология ударов и контр-мер 2024-2026 |

### `_reference/` — устройство мира (TTL 60 дней)

| Файл | Что внутри |
|---|---|
| `vpn-protocols.md` | Восемь VPN-протоколов: OpenVPN, WireGuard, AmneziaWG, SS, VMess, Trojan, VLESS+Reality, Hysteria/TUIC |
| `transports.md` | Транспорты: XHTTP, HTTPUpgrade, WS, gRPC, mKCP, и матрица «протокол × транспорт × ядро» |
| `fronting-strategies.md` | Cloudflare-fronting, альтернативные CDN, WARP, Reality fallback, uTLS |
| `3x-ui-panel.md` | Архитектура эталонной панели MHSanaei/3x-ui, файловая раскладка, CLI, TLS, грабли |
| `3x-ui-api.md` | REST API панели 3X-UI: cheatsheet curl-команд для скиллов |
| `client-apps.md` | Карта клиентов sing-box/xray на 6 платформах, iOS-специфика |
| `vpn-consultation-flow.md` | Сценарий VPN-консультации (hub): interview, выбор протокола, TUN, FAQ, чек-лист |
| `routing-server-3xui.md` | **Маршрутизация на сервере (дефолт)** — split РФ/foreign/block в 3X-UI, Xray-синтаксис |
| `routing-on-device-singbox.md` | Маршрутизация на устройстве через sing-box (энтузиасты): раскол ядра 1.11↔1.12, клиенты |
| `routing-on-device-xray.md` | Маршрутизация на устройстве через Xray в терминале (энтузиасты-десктоп) |
| `xray-mac-chain.md` | Xray chain (VLESS→VLESS) на Mac для Claude Code: proxy-only bypass WL |

### `_meta/` — мета-слой (TTL 365 дней)

| Файл | Что внутри |
|---|---|
| `sources-registry.md` | Реестр источников с весами доверия (HIGH/MEDIUM/LOW) |
| `glossary.md` | Единый словарь: TSPU, DPI, SNI, ASN, fingerprint, fronting, и т.д. |
| `conflicts.md` | Расхождения источников по конкретным фактам — для разрешения, не для забвения |

---

## 3. Как обновлять

Селективная актуализация — через скилл:

```bash
/refresh-vpn-knowledge LAYER=live       # чаще всего (≤25 Tavily запросов)
/refresh-vpn-knowledge LAYER=reference  # реже (≤30 запросов)
/refresh-vpn-knowledge LAYER=meta       # почти никогда, по запросу
/refresh-vpn-knowledge LAYER=all        # все слои
```

Default — `LAYER=live`, потому что фронт борьбы устаревает быстрее всего.

Проверить свежесть — без сети:

```bash
bash .claude/skills/_lib/check-knowledge-freshness.sh vpn
```

Helper рекурсивен — пробежит по всем трём подпапкам.

---

## 4. Дисциплина источников

Не все источники одинаково надёжны. Реестр весов — в `_meta/sources-registry.md`.

Правило:

- **HIGH** (Cloudflare blog, GFW Report, OONI, XTLS-official) — можно цитировать
  как факт.
- **MEDIUM** (ntc.party, Habr с замерами, Hub.xeovo) — можно цитировать, но
  предпочтительно с подтверждением из HIGH.
- **LOW** (Telegram-каналы, Reddit, форумы) — только как подтверждение, не
  первичный источник.

Утверждение в `_live/` или `_reference/` требует **≥1 HIGH** ИЛИ **≥2 независимых MEDIUM**.
Иначе — пометка `? уточнить (не подтверждено: <дата>)`.

Конфликт двух HIGH или двух MEDIUM — фиксируется в `_meta/conflicts.md` с обеими
цитатами и датами, без выбора стороны.

---

## 5. Связи

- **ADR-0003** — базовая архитектура `.claude/knowledge/` (общая для всех доменов).
- **ADR-0005** — архитектура VPN-блока (4 скилла, потребители этой базы).
- **ADR-0006** — формальное обоснование расслоения именно VPN-домена.
- **Презумпция устаревания VPN-knowledge** — `.claude/agents/references/presumptions.md`.
- **Скилл `/refresh-vpn-knowledge`** — `.claude/skills/refresh-vpn-knowledge/SKILL.md`.

---

## 6. Что НЕ хранится здесь

- Реальные данные оператора (IP, домены, ключи) — это `infra/inventory/`.
- Процедуры скиллов (команды, шаблоны конфигов) — это `.claude/skills/<имя>/`.
- Конституция агента — это `.claude/agents/sysadmin.md` и `.claude/agents/references/`.
- Архитектурные решения — это `decisions/` (ADR).
