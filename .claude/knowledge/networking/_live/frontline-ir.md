---
knowledge_domain: vpn
layer: live
geography: ir
last_researched: 2026-05-17
ttl_days: 14
sources_checked:
  - https://arxiv.org/html/2603.28753v1
  - https://github.com/bgoldmann/iranvpn
  - https://relyvpn.com/blog/vpn-for-iran.html
  - https://nextunnel.com/blog/vpn-for-iran-2026-complete-guide
  - https://forum.qubes-os.org/t/installation-of-amnezia-vpn-and-amnezia-wg-effective-tools-against-internet-blocks-via-dpi-for-china-russia-belarus-turkmenistan-iran-vpn-with-vless-xray-reality-best-obfuscation-for-wireguard-easy-self-hosted-vpn-bypass/39005
  - https://www.techradar.com/vpn/vpn-services/amnezia-vpn-drops-new-amneziawg-2-0-protocol-as-censorship-tactics-grow-smarter
  - https://amnezia.org/
  - https://dev.to/bivlked/your-wireguard-got-blocked-deploy-amneziawg-20-in-5-minutes-2k7h
---

# Фронт Иран: блокировки на 2026-05-17

## §1 Зачем нам этот фронт

Иран — **арсенал-донор**. Иранское комьюнити 7+ лет в режиме экстремальной
цензуры: DNS-poisoning, DPI, **protocol whitelisting** (только HTTP/HTTPS/DNS),
>6 млн заблокированных доменов. Их рабочие решения — то, что РФ ещё не видела.

В РФ-2026 многое из иранского арсенала уже актуально или станет в ближайшие
6-12 мес.

---

## §2 TL;DR

- 🟢 **Работает:** AmneziaWG (создан **для Ирана и РФ**), VLESS+Reality+Vision, XHTTP за Cloudflare, Hysteria2 с masquerade
- 🟡 **Работает с оговорками:** v2ray-плагины + SS2022 (нужна правильная обфускация)
- 🔴 **Не работает:** plain WireGuard, OpenVPN, IKEv2 — всё DPI'тся
- ⚠️ **Январь 2026 — total internet shutdown** в Иране (arxiv preprint) — даже VPN не помогали в первые дни; восстановление через ~3 дня

---

## §3 Иранская модель цензуры (уникальное)

### 3.1 Protocol whitelisting

Иран — одна из немногих стран с **protocol whitelist** на уровне государства:
пропускается только **HTTP, HTTPS, DNS** (RelyVPN MEDIUM, bgoldmann/iranvpn HIGH).
Всё остальное (raw UDP, нестандартные порты, кастомные протоколы) — режется.

Это значит:
- ❌ Plain WireGuard, OpenVPN — категорически нет
- ❌ Hysteria2 на нестандартном порту — нет
- ❌ TUIC — нет
- ✅ Любой протокол, маскирующийся под HTTPS (Reality, XHTTP) — да
- ✅ Hysteria2 на 443 порту с masquerade — да

### 3.2 DNS poisoning

Иран активно отравляет DNS — резолверы провайдеров возвращают неправильные IP
для заблокированных доменов. Контр-мера: DoH/DoT обязательно.

### 3.3 6 миллионов заблокированных доменов

Полный whitelist-like, очень жёсткий. ТСПУ в РФ движется в эту сторону, но
пока на порядки меньше.

---

## §4 Январский 2026 shutdown (arxiv academic)

[arxiv.org/2603.28753](https://arxiv.org/html/2603.28753v1) — HIGH academic source.

**Что произошло:** В январе 2026 Иран провёл near-total internet shutdown
(несколько дней). В первые дни **большинство circumvention-инструментов
перестало работать**. К 27 января (день 5-6) функциональность вернулась
для большего числа VPN.

**Влияние для прогноза РФ:** Постановление № 1667 (с 1 марта 2026) даёт
аналогичные технические возможности РКН/ФСБ. **Полный shutdown по образцу
Ирана-января-2026 — реальный сценарий для РФ** в случае массовых протестов
или эскалации.

---

## §5 🟢 Что работает в Иране (2026-Q1)

### AmneziaWG (был создан для Ирана!)

Amnezia VPN явно позиционирует AmneziaWG как **протокол для Ирана и РФ**.
Forum.qubes-os.org HIGH:

> «AmneziaWG: effective tools against internet blocks via DPI for **China,
> Russia, Belarus, Turkmenistan, Iran**»

В январе 2026 после shutdown — AmneziaWG среди первых восстановивших связь.

### VLESS+Reality+Vision

Та же стратегия что в РФ и КНР. Reality «крадёт» identity Apple/Microsoft/GitHub.

### XHTTP за Cloudflare — иранская школа

Иранцы выработали production-готовый паттерн **XHTTP за CF** (хотя в РФ
после 16-KB curtain это уже не работает). См. Habr 990542 (иранский подход).

### Hysteria2 с masquerade под HTTPS-сервер

Mode `proxy` upstream на легитимный сайт; работает в Иране даже с protocol
whitelisting, потому что выглядит как HTTPS-трафик на 443.

### NaiveProxy

В Иране популярнее чем в РФ. Использует Chromium-сетевой стек — fingerprint
неотличим от настоящего Chrome.

---

## §6 Какие обходы есть в Иране, которых нет у нас

### 6.1 XHTTP за Cloudflare production-stack

Иранцы давно отработали (статья Habr 990542 — основана на иранском опыте).
В РФ-2026 это **не работает из-за 16-KB curtain**, но опыт **архитектуры**
полезен для случая когда curtain снимут или для других стран.

### 6.2 Reality с динамической ротацией donor

Аналогично Китаю — клиент rotate-ит между несколькими serverName.

### 6.3 Outline VPN (от Jigsaw/Google) с SS2022

В Иране Outline (на SS2022 + anti-active-probing) — один из основных
gov-friendly инструментов. В РФ менее популярен.

### 6.4 Tor pluggable transports (snowflake, meek, obfs4)

В Иране Tor с pluggable transports — рабочий вариант. В РФ Tor целиком
заблокирован включая bridges (TSPU).

---

## §7 Прогноз: что из Ирана придёт в РФ

| Технология | Уже в РФ? | Когда придёт |
|---|---|---|
| Protocol whitelisting на уровне государства | 🟡 частично (мобильные операторы) | 2026-Q4 (прогноз) |
| 24-часовая блокировка eSIM при первом входе | ✅ с октября 2025 | Уже |
| Полный internet shutdown по приказу ФСБ/Минцифры | 🟡 точечный (Москва март 2026) | Региональные — есть; полный — 2027? |
| Total whitelist 500 → 6 млн | 🟡 ~500 | 2027-2028 при текущей траектории |
| AmneziaWG как mainstream | ✅ уже | — |
| Обязательный DoH/DoT для обхода DNS-poison | 🟡 опционально | 2026-Q3 |

---

## §8 Источники

- [arxiv.org/2603.28753 — Iran January 2026 Shutdown](https://arxiv.org/html/2603.28753v1) — **HIGH academic**
- [github.com/bgoldmann/iranvpn](https://github.com/bgoldmann/iranvpn) — HIGH (полный research report по Ирану-VPN)
- [Amnezia VPN](https://amnezia.org/) — HIGH (разработчики AmneziaWG)
- [Qubes-OS forum AmneziaWG guide](https://forum.qubes-os.org/t/installation-of-amnezia-vpn-and-amnezia-wg-effective-tools-against-internet-blocks-via-dpi-for-china-russia-belarus-turkmenistan-iran...) — MEDIUM
- [NexTunnel Iran 2026 complete guide](https://nextunnel.com/blog/vpn-for-iran-2026-complete-guide) — LOW (vendor)
- [RelyVPN Iran](https://relyvpn.com/blog/vpn-for-iran.html) — LOW (vendor)
