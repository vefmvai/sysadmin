---
name: setup-secrets-vault
description: |
  Менеджер паролей для проекта: Keychain (macOS, default), pass (Linux/CLI), KeePassXC
  (cross-platform), Bitwarden (online). Рекомендация по ОС, установка, шаблон индекса
  в inventory/access.md. Принцип: секреты НИКОГДА в git, только указатели.
  Триггеры: «настрой менеджер паролей», «куда хранить секреты», «не хочу секреты в репе»,
  «.env по правилам», «secrets vault», «password manager».
  НЕ для ротации существующих секретов (rotate-secrets); НЕ для миграции корпоративных
  менеджеров (1Password, LastPass).
allowed-tools: Bash, Read, Edit, Write
---

<role>
Я помогаю оператору выбрать и настроить менеджер паролей с первого дня проекта. Мой результат — рабочий vault с правильно настроенными правами доступа и шаблон индекса секретов в репозитории, который объясняет «куда что положили», но не содержит самих значений. Принцип, который я закладываю: секреты НИКОГДА не лежат в git, в репо лежат только указатели на менеджер.
</role>

<context>
Предполагается:
- ОС оператора известна (macOS / Linux / Windows) — определяется автоматически.
- Проект имеет папку для документации (`inventory/` по умолчанию).
- Оператор готов потратить 10-15 минут на выбор и базовую настройку.

НЕ предполагается:
- У оператора уже есть менеджер (если есть — используем существующий и просто создаём индекс).
- Корпоративный SSO-менеджер (1Password Business, LastPass Enterprise) — это отдельная история.
- Vault для команды (этот скилл — про индивидуальный vault; для команды используется Bitwarden self-hosted / vaultwarden, отдельная задача).
</context>

<goals>
После выполнения должно стать TRUE:
- На машине оператора установлен и работает один из менеджеров (Keychain/pass/KeePassXC/Bitwarden).
- Smoke-test пройден: создание / чтение / удаление тестового секрета работает.
- В проекте создан `inventory/access.md` из шаблона — индекс секретов без самих значений.
- В персоне/CLAUDE.md есть пометка о выбранном менеджере (для будущих скиллов).
- Оператор понимает принцип «секреты — указателями, значения — в менеджере».
</goals>

# Параметры

| Параметр        | Default      | Описание                                                          |
| --------------- | ------------ | ----------------------------------------------------------------- |
| `OS`            | autodetect   | `macos` / `linux-headless` / `linux-desktop` / `windows`           |
| `VAULT_TYPE`    | (interactive; если есть `sysadmin-config.json` — берётся из `secrets.manager`) | `keychain` / `pass` / `keepassxc` / `bitwarden` |
| `INVENTORY_DIR` | `inventory`  | Куда положить `access.md`                                         |
| `PROJECT_ROOT`  | `$PWD`       | Корень проекта (где лежит `.git/`)                                |
| `--force`       | (off)        | Игнорировать значение `secrets.manager` из конфига и перейти в Decision Tree |

# Процедура

## Шаг 1: Detect OS и существующий менеджер

```bash
case "$(uname -s)" in
    Darwin*)            OS="macos" ;;
    Linux*)
        if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
            OS="linux-desktop"
        else
            OS="linux-headless"
        fi
        ;;
    MINGW*|MSYS*|CYGWIN*) OS="windows" ;;
    *) OS="unknown" ;;
esac
```

**Проверить, не установлен ли уже менеджер:**
- `command -v security` (macOS Keychain — есть всегда на macOS).
- `command -v pass` (pass).
- `command -v keepassxc` (KeePassXC).
- `command -v bw` (Bitwarden CLI).

Если что-то уже стоит — спросить оператора: «использовать существующий или поставить новый?»

## Шаг 2.0: Проверка sysadmin-config.json (OPTIONAL)

Скилл — OPTIONAL-режим. Может вызываться **до** `/sysadmin-init` (на свежем сервере, в составе bootstrap-сценария), поэтому отсутствие конфига — нормально.

```bash
CONFIG="${INFRA_DIR:-$(pwd)}/sysadmin-config.json"
VAULT_FROM_CONFIG=""

if [ -f "$CONFIG" ] && [ "${FORCE:-0}" != "1" ]; then
    VAULT_FROM_CONFIG=$(jq -r '.secrets.manager // empty' "$CONFIG")
fi

if [ -n "$VAULT_FROM_CONFIG" ]; then
    VAULT_TYPE="$VAULT_FROM_CONFIG"
    echo "В sysadmin-config.json указан secrets.manager=$VAULT_TYPE — пропускаю Decision Tree."
    echo "Если хочешь поменять — запусти скилл с --force или /sysadmin-init --reconfigure."
    # Переходим сразу к Шагу 3 (установка)
fi
```

**Логика:**
- Если `sysadmin-config.json` есть и `secrets.manager` задан → использовать значение, пропустить Decision Tree (Шаг 2).
- Если конфига нет ИЛИ `secrets.manager` не задан → выполнять Decision Tree как раньше (этот скилл может вызываться **до** `/sysadmin-init`, поэтому отсутствие конфига — норма, а не ошибка).
- Если оператор хочет переопределить значение из конфига — флаг `--force` или `/sysadmin-init --reconfigure`.

## Шаг 2: Decision Tree — какой менеджер выбрать

> **Применяется только если Шаг 2.0 не нашёл значение в конфиге** (либо конфига нет, либо `--force`).

Подробная таблица — в `references/which-vault-to-pick.md`. Краткая логика:

```
IF OS == macOS:
    → Рекомендация: Keychain (встроен, шифруется ключом FileVault, нет сетевых зависимостей).
    → Альтернатива: KeePassXC (если cross-platform sync нужен).
    → Альтернатива: Bitwarden (если оператор уже его использует).
    → НЕ рекомендация: pass (требует gpg, избыточно для macOS-only).

IF OS == linux-headless (cloud-сервер, без GUI):
    → Рекомендация: pass (минимализм, gpg-encrypted, git-friendly).
    → Альтернатива: Bitwarden CLI (если уже используется).
    → НЕ рекомендация: Keychain (нет на Linux), KeePassXC (требует X11).

IF OS == linux-desktop:
    → Рекомендация: KeePassXC (cross-platform, GUI, autotype).
    → Альтернатива: pass (для CLI-предпочитающих).

IF OS == windows:
    → Рекомендация: KeePassXC (cross-platform).
    → Альтернатива: Bitwarden.
    → НЕ доступно: Keychain, pass без WSL.
```

**Спросить оператора финальное решение** — даже если рекомендация очевидна. Иногда у оператора есть legacy-привычка или предпочтение, которое нужно учесть.

## Шаг 3: Установка выбранного

Запустить соответствующий скрипт:

| Выбор          | Скрипт                                | Что делает                                                  |
| -------------- | ------------------------------------- | ----------------------------------------------------------- |
| `keychain`     | `scripts/install-keychain.sh`         | Проверка `security` CLI, примеры команд (фактически — only verify) |
| `pass`         | `scripts/install-pass.sh`             | `apt-get install pass gnupg2`, генерация GPG-ключа, `pass init` |
| `keepassxc`    | `scripts/install-keepassxc.sh`        | `apt-get install keepassxc` (Linux) или `brew install keepassxc` (macOS) |
| `bitwarden`    | (ссылка на инструкцию)                | Регистрация на bitwarden.com + `bw login` — НЕ автоматизируем |

**Bitwarden — особый случай:** требует регистрации в облаке (или self-hosted vaultwarden), мы не автоматизируем регистрацию. Скилл даёт ссылку на официальную документацию и подтверждает работоспособность через `bw status`.

## Шаг 4: Создание `inventory/access.md` из шаблона

```bash
mkdir -p "$PROJECT_ROOT/$INVENTORY_DIR"
cp templates/access-md-template.md "$PROJECT_ROOT/$INVENTORY_DIR/access.md"
```

Внутри шаблона заменить плейсхолдер `<vault-name>` на конкретный (Keychain / pass / KeePassXC / Bitwarden).

## Шаг 5: Smoke-test

Создать тестовый секрет, прочитать, удалить — подтверждение, что vault работает.

**Keychain:**
```bash
security add-generic-password -a "test" -s "infra-smoke-test" -w "test-value-12345"
security find-generic-password -a "test" -s "infra-smoke-test" -w
# должен вывести: test-value-12345
security delete-generic-password -a "test" -s "infra-smoke-test"
```

**pass:**
```bash
echo "test-value-12345" | pass insert -e infra-smoke-test
pass infra-smoke-test
# должен вывести: test-value-12345
pass rm -f infra-smoke-test
```

**KeePassXC (CLI):**
```bash
# Требует существующего .kdbx-файла:
keepassxc-cli add -p ~/secrets.kdbx infra-smoke-test
# Интерактивно: ввести значение, master-пароль для разблокировки.
keepassxc-cli show ~/secrets.kdbx infra-smoke-test --show-protected
keepassxc-cli rm ~/secrets.kdbx infra-smoke-test
```

**Bitwarden:**
```bash
echo '{"name":"infra-smoke-test","login":{"password":"test-value-12345"}}' \
  | bw encode | bw create item
bw get password infra-smoke-test
bw delete item $(bw get item infra-smoke-test | jq -r .id)
```

## Шаг 6: Объяснить оператору принцип

После успешного smoke-test — короткий брифинг (без жаргона):

> Секреты в `.env` файле в репо — антипаттерн. Один git push в публичный репо — и токен в тысячах форков, чистить уже бесполезно.
>
> Правило: в `.env` файле, который коммитится (`.env.example`) — только указатели:
> ```
> DB_PASSWORD=<keychain://infra/db/postgres>
> TELEGRAM_BOT_TOKEN=<pass:infra/telegram/bot>
> ```
> Реальные значения хранятся в менеджере. На сервере есть `.env` с реальными значениями — он в `.gitignore`.
>
> При деплое — отдельный скрипт читает значения из менеджера и подставляет в runtime-окружение.

# Failed Attempts (граблекейс)

- **«Игнорировал `sysadmin-config.json` и спрашивал заново»** — оператор настраивал второй менеджер поверх первого. Урок: если `secrets.manager` задан в конфиге, Decision Tree пропускается. Переопределить можно `--force` или `/sysadmin-init --reconfigure`. Сохраняется совместимость со свежим сервером (конфига нет → Decision Tree как раньше).
- **«Bitwarden CLI без серверной части»** — `bw login` требует bitwarden.com или self-hosted vaultwarden. Если оператор хочет полностью offline — это другой инструмент (pass / KeePassXC).
- **«pass без gpg-key»** — `pass init` требует gpg-key. Скрипт `install-pass.sh` детектит отсутствие ключа и помогает создать. Если ключ уже есть — спрашивает, какой использовать.
- **«Keychain на Apple Silicon работает иначе»** — миф. CLI `security` идентичен на Intel и Apple Silicon. Разница только в одном — на M-чипах FileVault включён по умолчанию (что хорошо).
- **«KeePassXC без файла .kdbx — где он?»** — KeePassXC создаёт пустой database при первом запуске GUI (или через `keepassxc-cli db-create`). По умолчанию мы ставим в `~/secrets.kdbx`, но оператор может выбрать любой путь.
- **«gpg-ключ для pass — RSA или ed25519?»** — для pass нужен RSA или ECC; ed25519 для подписей, не для шифрования. Скрипт `install-pass.sh` создаёт RSA 4096 по умолчанию (с rsa4096 совместимы все версии gpg в репозиториях apt).

# Граничные случаи

- **Корпоративный менеджер (1Password, LastPass, Dashlane)** → этим скиллом не настраивается. Оператор использует свой; мы только создаём индекс `access.md` со ссылками формата `1password://infra/...` или `lastpass://...`.
- **Несколько операторов / команда** → Keychain не шарится между пользователями. Для команды уместнее Bitwarden (или self-hosted vaultwarden) с shared organization. Этот скилл — про индивидуальный vault; для team-vault'а есть отдельная задача (вне scope).
- **macOS без FileVault** → Keychain работает, но шифруется только паролем пользователя. Не критично, но рекомендуется включить FileVault (System Settings → Privacy & Security → FileVault) — добавит «защиту на уровне диска».
- **Linux без gpg-агента** → `pass` будет спрашивать passphrase для каждой операции. Решение: `gpg-agent` (обычно установлен с gpg) + `default-cache-ttl` в `~/.gnupg/gpg-agent.conf`. Скрипт `install-pass.sh` это настраивает.
- **Bitwarden offline** → `bw` кэширует vault локально, но требует первичный sync. Если оператор подразумевает air-gapped работу — Bitwarden не вариант.
- **«У меня уже хаос в .env-файлах в репо»** → этим скиллом мы не чистим историю git (это `cleanup-existing-server` или ручная работа с `git filter-repo`). Сначала смигрируй текущие секреты в новый менеджер, потом очисти историю — это два разных шага.