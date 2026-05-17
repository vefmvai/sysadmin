---
knowledge_domain: vpn
layer: live
geography: cn
last_researched: 2026-05-17
ttl_days: 14
sources_checked:
  - https://gfw.report/publications/usenixsecurity23/en/
  - https://greatfirewallguide.com/lab
  - https://greatfirewallguide.com/lab/protocol-matrix
  - https://greatfirewallguide.com/lab/vless-reality-vision
  - https://relyvpn.com/blog/china-vpn-crackdown-2026.html
  - https://blog-en.ch3nyang.top/post/gfw/
  - https://dev.to/mint_tea_592935ca2745ae07/bypassing-the-great-firewall-in-2026-active-filtering-protocol-obfuscation-37oj
---

# Фронт Китай: GFW на 2026-05-17

## §1 Зачем нам этот фронт

GFW (Great Firewall) опережает ТСПУ на 2-3 года. То, что блокируется в Китае
сегодня — придёт в РФ через 6-12 мес. Это **карта будущего** для оператора.

GFW использует:
- DPI на L4-L7
- Active probing с **рандомной задержкой** между триггером и пробой (USENIX 2023)
  — затрудняет анализ что именно triggers probe
- Statistical fingerprinting (entropy первого пакета, length, byte distribution)
- ML-модели на pattern recognition
- IP-blacklisting серверов после детекции
- **Real-time blocking system** (USENIX paper) — без буферизации, мгновенное решение

---

## §2 TL;DR

- 🟢 **Работает:** VLESS+Reality+Vision (98% bypass по бенчмаркам), AmneziaWG 2.0, ShadowTLS v3
- 🟡 **Работает с оговорками:** Hysteria2 (68% bypass — отстаёт от Reality), Trojan-Go (с masquerade)
- 🔴 **Не работает:** plain WireGuard, plain OpenVPN, plain Shadowsocks, plain VLESS, VMess
- ⚠️ **XHTTP в КНР:** есть тестовые блокировки, но систематического anti-XHTTP пока нет
  (по состоянию April 2026)

---

## §3 🟢 Что работает в КНР (2026-Q2)

### VLESS-Reality-Vision — лидер
Бенчмарк greatfirewallguide.com (HIGH): **98% bypass rate в Шанхае, Пекине, Шэньчжэне**
(тестировано April 2026). Latency 160ms, uptime 95%.

Reality «крадёт» identity легитимного сайта. Когда GFW делает active probing —
сервер отдаёт реальный Server Hello от настоящего целевого сайта (Apple.com, etc),
**probing не различает прокси от настоящего CDN-edge**.

### AmneziaWG 2.0
В списке working для Китая (Amnezia HIGH). CPS (Concealment Packet System),
tagged I1-I5, range-based H1-H4 параметры — против ML-моделей GFW.

### ShadowTLS v3
Маскировка SS под TLS-сессию к легитимному сайту. Работает в КНР.

---

## §4 🔴 Что НЕ работает в КНР

**Лиз kill-list 2026 (RelyVPN):**
- ❌ Plain WireGuard, OpenVPN, IKEv2 — detectable signatures
- ❌ Plain Shadowsocks — entropy fingerprint первого пакета
- ❌ V2Ray VMess — recognizable handshake patterns
- ❌ Plain Trojan — timing/packet-size distributions отличаются от настоящего HTTPS
- ❌ Любой плохо настроенный сервер — active probing → blacklist IP

---

## §5 🟡 Hysteria2 в КНР — 68% bypass

Greatfirewallguide.com (HIGH): Hysteria2 ranking **второй после Reality** по
устойчивости, **первый по чистой скорости**. 68% bypass — значит **в 1 из 3 случаев
блокируется**.

Причина: GFW активно блокирует UDP-флуд от неавторизованных серверов; masquerade
mode (proxy/file/string) спасает не всегда.

---

## §6 Что НЕ работает в КНР из того, что работает у нас (РФ)

| Технология | Статус КНР | Статус РФ | → когда придёт в РФ |
|---|---|---|---|
| Plain Reality без правильного donor | 🔴 | 🟢 (но 16-KB curtain) | Уже частично через CDN-throttling |
| Hysteria2 c masquerade=string | 🟡 68% bypass | 🟢 работает | Q3-Q4 2026 |
| VLESS+WS+TLS через popular CDN | 🔴 | 🟡 | Уже под curtain |
| Trojan с domain без CDN | 🔴 | 🟡 | Уже под угрозой |

**Прогноз:** ТСПУ к концу 2026 догонит GFW по DPI-уровню. Hysteria2 в РФ начнёт
отказывать. Нужен запасной транспорт.

---

## §7 Какие обходы есть в КНР, которых нет у нас

### 7.1 Reality-Vision с динамической ротацией donor-сайтов
Китайское комьюнити выработало паттерн: клиент **rotate-ит между несколькими
serverName** для одного и того же физического сервера, чтобы fingerprint
«один и тот же sni всегда» не появлялся.

### 7.2 NaiveProxy с Naiveproxy fork
В Китае популярен NaiveProxy с патчами против GFW — в РФ почти не используется.

### 7.3 International roaming eSIM
greatfirewallguide.com (HIGH) рекомендует **iSIM/eSIM с международным
роумингом** — трафик идёт через зарубежного оператора связи, GFW не видит.

В РФ это пока работает аналогично, но **с октября 2025 — 24-часовой блок данных
для новых eSIM** (см. timeline.md). Прогноз: РФ догонит.

---

## §8 Прогноз: что придёт в РФ из КНР в 6-12 мес

1. **DPI на entropy первого пакета** — выявление SS без обфускации
2. **Active probing с рандомной задержкой** — труднее анализировать
3. **Real-time blocking без буферизации** — мгновенный IP-blacklist
4. **ML-классификация трафика на VPN/non-VPN** — против Hysteria2 masquerade
5. **Целенаправленная блокировка XHTTP** — китайское комьюнити уже видит первые
   сигналы

---

## §9 Источники

- [USENIX Security 2023 — GFW Detection of Fully Encrypted Traffic](https://gfw.report/publications/usenixsecurity23/en/) — HIGH academic
- [greatfirewallguide.com/lab](https://greatfirewallguide.com/lab) — HIGH (бенчмарки с привязкой к датам)
- [ch3nyang.top blog](https://blog-en.ch3nyang.top/post/gfw/) — MEDIUM (детальный историко-технический разбор)
- [RelyVPN China crackdown 2026](https://relyvpn.com/blog/china-vpn-crackdown-2026.html) — MEDIUM
