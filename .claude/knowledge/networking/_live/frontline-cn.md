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

> ⚠️ **Важно: данные ниже — для «среднего китайского пользователя».** Это модельный
> сценарий «китайский гражданин с китайской SIM, через китайский ISP, к VPN-серверу
> в HK/SG/TW». Для **российского туриста с русским VPN-сервером, арендованным под
> РФ-рынок** (Hetzner / OVH / DigitalOcean / Aeza ASN, не Hong Kong / Singapore
> China-tier) — картина мягче. Подробнее — §4.5 «Российский турист в КНР — почему
> правила другие». Зафиксировано в `_meta/conflicts.md` КОНФЛИКТ-004.

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

## §4.5 Российский турист в КНР — почему правила другие

Эта секция декомпозирует TL;DR на два разных сценария угрозы, которые до сих пор
смешивались в «работает в КНР / не работает в КНР».

### 4.5.1 Два разных сценария

| Сценарий | Кто | С чего ходит | Куда ходит | Кому интересен GFW |
|---|---|---|---|---|
| **«средний китайский пользователь»** | гражданин КНР | китайская SIM / китайский домашний ISP | VPN-сервер в HK / Singapore / Taiwan (классический «China-tier» VPN) | да, приоритет (диссидент-инфраструктура) |
| **«российский турист»** | гражданин РФ в краткосрочной поездке | гостиничный WiFi / иностранная SIM | VPN-сервер у российского сервиса, арендованный на Hetzner / OVH / DigitalOcean / Aeza | низкий приоритет (иностранный пользователь, иностранный VPN-сервис) |

Для первого сценария справедлива классическая таблица §3-§4 этого документа.
Для второго — реальный кейс показывает что правила мягче.

### 4.5.2 Конкретное наблюдение (Шанхай, 2026-05-17)

Field-report оператора (Василий, физически в Шанхае, гостиничный WiFi в международном
апарт-отеле; источник вес LOW согласно `_meta/sources-registry.md` §4, но 2 параллельных
data-points на разных протоколах — что повышает доверие к самому факту наблюдения,
не к его интерпретации):

- **Сеть подтверждена как обычный GFW** — YouTube и Google напрямую с этого WiFi
  **блокируются** (значит это не «отельная зона с послаблениями для иностранцев»).
- **Blanc VPN** (российский сервис, VLESS, скорее всего +Reality) — **РАБОТАЕТ**.
- **Bebra VPN** (российский сервис, Shadowsocks под капотом) — **РАБОТАЕТ**.
- На иностранной SIM в роуминге всё работает (ожидаемо — трафик идёт через
  зарубежного оператора, GFW не видит).

VLESS-кейс (Blanc) согласуется с §3 этого документа (Reality 98% bypass). А вот
Bebra на SS-базе **противоречит** §4 «🔴 plain Shadowsocks». Это и есть КОНФЛИКТ-004.

### 4.5.3 Четыре гипотезы почему так

1. **Серверы арендованы под РФ-рынок.** Hetzner / OVH / DigitalOcean / Aeza — эти ASN
   не в приоритетном target list GFW для агрессивного active probing. GFW исторически
   фокусируется на инфраструктуре «протестных» каналов (HK, SG, TW, известные VPN-провайдеры
   для китайских диссидентов), а не на инфраструктуре «для иностранцев».
2. **Bebra может использовать не plain SS,** а SS2022 (SIP022) или SS+plugin
   (v2ray-plugin, simple-obfs, cloak). В базе SS2022 помечен 🟡 «работает в ограниченных
   сценариях» (см. `_live/frontline-ru.md`). Плагины ломают entropy-fingerprint первого
   пакета, на котором держится DPI-сигнатура. Это не противоречит §4 — там запрещён именно
   plain SS.
3. **Шанхай как финансовый центр** имеет послабления на сетевом уровне (некоторые ASN
   не проверяются активно, active probing там реже чем в Пекине или Урумчи). Это
   согласуется с известной географической неоднородностью GFW.
4. **Главное методологическое следствие.** §3-§4 этого документа написаны «в среднем по
   больнице» для **среднего китайского пользователя**. Для **российского туриста с
   русским VPN-сервером** другой ASN, другой регион, другой геополитический приоритет GFW —
   и потому другие правила. Это два разных threat-model.

### 4.5.4 Что прояснит

- traceroute / dig к серверам Blanc и Bebra для определения ASN — закроет гипотезу 1.
- Прямая проверка протокола Bebra (отчёт техподдержки / реверс приложения / Wireshark
  на handshake) — plain SS, SS2022 или SS+plugin — закроет гипотезу 2.
- Повторение замера из других городов КНР и с других сетей — закроет гипотезу 3.

См. полную запись в `_meta/conflicts.md` КОНФЛИКТ-004.

### 4.5.5 Прогноз: временное окно

Это **временное окно**. Если РФ-VPN-сервисы массово начнут использоваться китайскими
пользователями (через сторонние каналы, репутацию «работает в КНР») — GFW начнёт
целить эти ASN специально. Сейчас они находятся в категории «инфраструктура для
иностранцев», а не «инфраструктура диссидентов» — поэтому не приоритет. Срок жизни
окна оценить сложно, но в горизонте 12-24 мес ситуация может развернуться.

**Практический вывод для оператора:** если едешь в КНР с уже работающим российским
VPN — попробуй его сначала, не покупай отдельный «China-grade» сервис до проверки.
Если своего VPN нет — оптимальная стратегия по-прежнему VLESS+Reality на сервере в
HK/SG/JP (см. §3, 98% bypass — это страховка независимая от ASN-приоритизации).

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
