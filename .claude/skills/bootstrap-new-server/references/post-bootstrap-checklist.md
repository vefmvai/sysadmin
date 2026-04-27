# Post-bootstrap checklist

После завершения `bootstrap-new-server` проверь все пункты ниже. Если хотя бы один FAIL — bootstrap не закончен.

## SSH

- [ ] `ssh -p $SSH_PORT $ADMIN_USER@<ip>` пускает.
- [ ] `ssh root@<ip>` отвечает `Permission denied (publickey)`.
- [ ] `ssh -p $SSH_PORT $ADMIN_USER@<ip> -o PasswordAuthentication=yes` НЕ запрашивает пароль (отвечает publickey only).

## UFW

- [ ] `sudo ufw status verbose` → Status: active.
- [ ] Default: deny incoming, allow outgoing.
- [ ] Открыты только: `$SSH_PORT/tcp` (LIMIT), `80/tcp`, `443/tcp`.

## fail2ban

- [ ] `sudo fail2ban-client status` → активные jail включают `sshd`.
- [ ] `sudo fail2ban-client status sshd` → Currently failed: 0, banned: 0 (на свежем сервере).
- [ ] В `/etc/fail2ban/jail.local` jail `sshd` слушает правильный порт.

## Docker

- [ ] `docker --version` → версия 24.x или новее.
- [ ] `docker compose version` → v2.x.
- [ ] `docker run --rm hello-world` → `Hello from Docker!`.
- [ ] `groups $ADMIN_USER` содержит `docker` (после relogin).
- [ ] `sudo systemctl is-enabled docker` → enabled.

## Структура /opt

- [ ] `/opt/monitoring/` — пустая папка, owner $ADMIN_USER.
- [ ] `/opt/admin-panel/` — пустая папка.
- [ ] `/opt/shared-db/` — пустая папка.
- [ ] `/opt/apps/` — пустая папка.
- [ ] `/opt/infra/` — git-репозиторий.

## Git-репозиторий

- [ ] `cd /opt/infra && git log --oneline` → есть как минимум один коммит.
- [ ] `.gitignore` содержит `.env`, `*.key`, `*.pem`.
- [ ] `.git/hooks/pre-commit` существует и executable.
- [ ] `decisions/0000-template.md`, `incidents/_template.md`, `runbooks/00-template.md` существуют.
- [ ] `inventory/README.md` существует.

## Pre-commit hook (gitleaks)

- [ ] `gitleaks --version` (опционально — если установлен).
- [ ] Тестовый коммит с фейковым секретом блокируется (если gitleaks установлен) или проходит с warning.

## Дальше

Когда все пункты OK:
1. Запусти `setup-secrets-vault` — настроить менеджер паролей.
2. (Опционально) `install-monitoring-stack` — базовый мониторинг.
3. (Опционально) `setup-backups` — restic + remote storage.

Если что-то FAIL — не двигайся дальше. Каждый последующий скилл предполагает, что bootstrap закончен полностью.