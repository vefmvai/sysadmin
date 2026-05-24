# Какой менеджер паролей выбрать

Сравнение менеджеров с CLI (keychain / pass / keepassxc / bitwarden / 1password). Решение зависит от ОС, требований к шарингу и предпочтений (CLI vs GUI).

Если оператор пользуется **другим** менеджером (Kaspersky, Dashlane, NordPass, браузерный — `manager=other` в конфиге): ключевой вопрос — есть ли у него CLI (`secrets.cli_available`). Нет CLI → агент не достаёт секреты сам, только ведёт указатели в `access.md`; при частых операциях имеет смысл завести Bitwarden для инфраструктуры (см. `/sysadmin-init` Раунд 2). Не выдумывать наличие CLI — проверять ресёрчем.

## Сравнительная таблица

| Критерий               | Keychain (macOS) | pass (Linux/CLI)   | KeePassXC          | Bitwarden          |
| ---------------------- | ---------------- | ------------------ | ------------------ | ------------------ |
| **ОС**                 | macOS only       | Linux primary, macOS via brew | Cross-platform | Cross-platform     |
| **GUI**                | Встроен в Settings | Нет (есть QtPass) | Да                 | Да                 |
| **CLI**                | `security`       | `pass`             | `keepassxc-cli`    | `bw`               |
| **Шифрование**         | Apple Keychain Services | gpg            | AES-256 + ChaCha20 | AES-256-GCM        |
| **Хранилище**          | Облачно через iCloud Keychain или локально | Локальный git-репо | Локальный .kdbx файл | Облако bitwarden.com или self-hosted |
| **Шаринг**             | Нет (per-user)   | Через git push     | Через файл .kdbx (Dropbox/syncthing) | Встроенный sharing |
| **Offline**            | Да               | Да                 | Да                 | Cache + offline mode |
| **Команда**            | Нет              | Сложно (gpg-keys на каждого) | Через .kdbx-файл общий | Лучший выбор (Organization)  |
| **Цена**               | Бесплатно        | Бесплатно          | Бесплатно          | Free / Premium $10 в год / Self-hosted бесплатно |
| **Зависимости**        | macOS only       | gpg                | Qt libs            | Network для sync   |
| **Backup**             | Через Time Machine + iCloud | git-репо  | Копия .kdbx файла  | Облачный                            |

## Decision matrix

### macOS (один оператор)
**Рекомендация: Keychain.**

Почему:
- Встроен — нет лишних установок.
- Шифруется ключом FileVault (если включён).
- iCloud Keychain (опционально) — sync между устройствами Apple.
- CLI `security` стабилен с macOS 10.x.

Когда выбрать другое:
- Нужен sync с Linux/Windows → KeePassXC.
- Уже работаешь с командой через Bitwarden → используй его.

### Linux headless (cloud-сервер)
**Рекомендация: pass.**

Почему:
- Минимальная система (gpg + git + bash).
- Каждый секрет — отдельный .gpg-файл, легко комитить в приватный git.
- Нет требования GUI.

Когда выбрать другое:
- Нужен share между серверами → Bitwarden CLI с self-hosted vaultwarden.

### Linux desktop
**Рекомендация: KeePassXC.**

Почему:
- Один .kdbx-файл — портативный (можно открыть с любого устройства).
- GUI с auto-type.
- CLI для скриптов.

Когда выбрать другое:
- Уже привык к pass из CLI → pass.

### Windows
**Рекомендация: KeePassXC.**

Почему:
- Native Windows клиент, не WSL-зависимый.
- Cross-platform .kdbx (можно открыть на macOS/Linux).

Когда выбрать другое:
- Уже используется Bitwarden → продолжать.

### Команда (несколько операторов / разработчиков)
**Рекомендация: Bitwarden Organization (cloud) или vaultwarden (self-hosted).**

Почему:
- Shared collections с гранулярными правами.
- Audit log.
- 2FA встроен.

Когда выбрать другое:
- Air-gapped среда → KeePassXC с .kdbx на shared mount (но это компромисс по безопасности).

## Чего НЕ выбирать

- **`.env` файлы в git** — ноль защиты от утечки. Один публичный push — токены в тысячах форков навсегда.
- **Plaintext в Notion/Google Docs** — нет audit, нет шифрования at-rest, нет ротации.
- **`echo "PASSWORD=..." >> ~/.bashrc`** — переменные окружения в plaintext в файле без шифрования.
- **«Свой кастомный» Python-скрипт с hardcoded ключом** — антипаттерн "rolling your own crypto", не делай.

## Антипаттерн: Bitwarden как default для macOS

Если в каком-то документе/плане ты видишь рекомендацию «Bitwarden для macOS» — это ошибка. Bitwarden — отличный вариант для команды или cross-platform; для индивидуального macOS-оператора Keychain объективно проще (встроен, бесплатно, без сетевых зависимостей).

## Миграция между менеджерами

Если уже используется один менеджер и нужно перейти на другой:

1. **Keychain → KeePassXC:**
   - `security dump-keychain` (с подтверждением для каждой записи).
   - Импорт через KeePassXC GUI: File → Import.

2. **pass → KeePassXC:**
   - `pass2kp` или скрипт `for f in $(find ~/.password-store -name '*.gpg'); do ...; done`.

3. **Bitwarden → любой:**
   - `bw export --format json > vault.json` → импорт целевым менеджером.

Миграция между менеджерами — отдельная задача, скилл `setup-secrets-vault` её не покрывает.