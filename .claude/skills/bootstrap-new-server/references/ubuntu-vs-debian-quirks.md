# Ubuntu vs Debian — особенности при bootstrap

Скилл `bootstrap-new-server` работает на Ubuntu 22.04+/24.04+ и Debian 12+. Между ними есть мелочи, которые ловят руками — здесь они собраны.

## APT-репозиторий Docker

- **Ubuntu:** `https://download.docker.com/linux/ubuntu`
- **Debian:** `https://download.docker.com/linux/debian`

Скрипт `04-docker-install.sh` определяет дистрибутив через `/etc/os-release` (поле `ID`) и подставляет правильный путь.

## Кодовое имя релиза

Команда `lsb_release -cs` доступна не везде из коробки — на минимальных Debian-образах нужно `apt install lsb-release`. Скрипт использует `$VERSION_CODENAME` из `/etc/os-release` — оно есть всегда.

## Группа sudo

- **Ubuntu:** группа называется `sudo`.
- **Debian:** тоже `sudo` (с момента, как `wheel` был де-факто заменён в 2010-х). Если работаешь со старым Debian < 11 — может быть `wheel`, но мы такие не поддерживаем.

## UFW vs Docker — ключевая ловушка

> Полная картина (3 решения по возрастанию радикальности + дефолт `127.0.0.1:port` биндинг, паттерн вынесения сервисов в user-defined сети, паттерн `internal: true` для БД) — в эталоне `.claude/knowledge/networking/_reference/server-networks-defaults.md` §7. Здесь — краткая справка, чтобы граблекейс бросался в глаза при чтении bootstrap-документации.

Docker по умолчанию вставляет правила в `iptables` цепочку `DOCKER-USER` ВЫШЕ цепочек ufw. Контейнеры с `ports:` в compose обходят UFW.

**Симптом:** UFW deny на 5432, но контейнер с `ports: ["5432:5432"]` доступен снаружи.

**Решения (от менее к более радикальному):**

1. **Bind на 127.0.0.1** — самый простой. В compose: `ports: ["127.0.0.1:5432:5432"]`. UFW не нужен для этого порта.

2. **Кастомные правила в DOCKER-USER:**
   ```
   /etc/ufw/after.rules:
     *filter
     :DOCKER-USER - [0:0]
     -A DOCKER-USER -i eth0 -j DROP
     -A DOCKER-USER -i eth0 -s 1.2.3.4 -j ACCEPT
     COMMIT
   ```

3. **`iptables=false` в `/etc/docker/daemon.json`** — Docker перестанет управлять iptables. Но тогда контейнеры теряют связность между сетями. Не рекомендуется без понимания.

На свежем сервере без контейнеров — UFW работает корректно. Проблема всплывает позже, при первом контейнере с публикуемым портом. Скилл `install-monitoring-stack` и `setup-secrets-vault` об этом ниже не заботятся — это контракт оператора.

## fail2ban + sshd на нестандартном порту

Если SSH-порт сменён (`SSH_PORT != 22`), нужно поправить jail:
```ini
[sshd]
port = 2222   # ← здесь
```

Скрипт `03-fail2ban.sh` это делает автоматически по переменной `$SSH_PORT`.

## Cloud-init блокировка APT

На Ubuntu Server cloud-init иногда держит `apt` lock первые 1-2 минуты после первого логина. Симптом:
```
E: Could not get lock /var/lib/apt/lists/lock
```

**Решение:** подождать `cloud-init status --wait` (или просто 1-2 минуты).

На Debian cloud-init обычно отрабатывает быстрее.

## `apt-get update` на свежем Debian

Минимальный Debian 12 не имеет HTTPS-транспорта для APT из коробки. Если в `sources.list` есть HTTPS-зеркало, нужно сначала:
```
apt-get install -y apt-transport-https ca-certificates
```

На современных Ubuntu это не нужно.

## Локали

На минимальном образе локали могут быть только `C.UTF-8`. Если нужна `ru_RU.UTF-8`:
```
locale-gen ru_RU.UTF-8
update-locale LANG=ru_RU.UTF-8
```

Не входит в bootstrap — делается опционально по запросу оператора.

## Hostname

`hostname` после установки иногда `localhost` или `ip-10-x-x-x` (зависит от провайдера). Если нужно сменить:
```
hostnamectl set-hostname my-server
```

И добавить в `/etc/hosts`:
```
127.0.1.1   my-server
```

Скилл этого НЕ делает — оставляет на оператора.