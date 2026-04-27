# Security Audit — YYYY-MM-DD

**Сервер:** user@host
**Scope:** all / host / docker / git / tls
**Сводка:** X PASS / Y WARN / Z FAIL

---

## Host

| Проверка | Статус | Детали |
|----------|--------|--------|
| UFW активен и default deny | PASS / WARN / FAIL | Status: active, Default: deny incoming |
| UFW allow только 22/80/443 | PASS / WARN | Allow IN: 22 (OpenSSH), 80, 443 |
| SSH PasswordAuthentication | PASS / FAIL | no |
| SSH PermitRootLogin | PASS / WARN | prohibit-password |
| fail2ban active + sshd jail | PASS / WARN / FAIL | active, 5 banned IPs |
| unattended-upgrades без auto-reboot | PASS / WARN | Automatic-Reboot "false" |
| Открытые внешние порты | PASS / WARN | только 22/80/443 |

## Docker

| Проверка | Статус | Детали |
|----------|--------|--------|
| daemon.json без insecure-registries | PASS / WARN | OK |
| .env permissions | PASS / WARN | Все mode 600 / N файлов с mode != 600 |
| Внутренние UI на 127.0.0.1 | PASS / WARN | Kuma 3001, Beszel 8090, Dozzle 8080, Dockge 5001 |
| Образы pinned (по ADR 0010 проекта-носителя или эквиваленту) | PASS / INFO | Публичные с тегами / digest, локальные :latest исключение |

## Git

| Проверка | Статус | Детали |
|----------|--------|--------|
| gitleaks scan (working tree + history --all) | PASS / FAIL | 0 findings |
| .gitignore содержит security patterns | PASS / WARN | .env, *.key, *.pem, secrets/ |

## TLS

| Домен | Статус | Дата истечения |
|-------|--------|----------------|
| example.com | PASS | 2026-08-15 (113 дней) |
| beta.example.com | WARN | 2026-05-10 (15 дней) |

## Рекомендации

1. **[WARN/FAIL]** Описание + конкретные команды исправления + Yellow/Red Zone маркер.
2. ...

## Историческая динамика (если есть предыдущий аудит)

Сравнение с `inventory/audits/<previous-date>.md`:

- **Улучшилось:** перечислить что зазеленело.
- **Не изменилось:** ключевые PASS, оставшиеся WARN.
- **Ухудшилось:** новые WARN/FAIL и почему появились (новый сервис, конфигурация
  поменялась оператором).

## Метаданные

- Время прогона: ~N сек.
- Запускал: `bash scripts/security-audit.sh --server ... --scope ...`
- Следующий плановый аудит: `YYYY-MM-DD` (через 90 дней — квартально).