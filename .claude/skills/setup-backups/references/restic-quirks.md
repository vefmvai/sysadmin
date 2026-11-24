# restic — известные грабли и edge cases

Справочник граничных случаев, выявленных в реальной эксплуатации. Используй как чек-лист
при отладке непонятных ошибок.

Грабли **обвязки** (скрипты дампа, оркестратор, cron-окружение, алерты, уборка
multipart-огрызков) — в соседнем `pipeline-pitfalls.md`. Здесь только сам restic
и хранилища.

## Хранилища

Форма `RESTIC_REPOSITORY` по типу хранилища — это первое, что нужно при `restic init`:

| Хранилище | `RESTIC_REPOSITORY` | Что ещё нужно |
|---|---|---|
| AWS S3 | `s3:s3.amazonaws.com/<bucket>/backups/infra` | `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` в env |
| Backblaze B2 | `b2:<bucket>:backups/infra` | `B2_ACCOUNT_ID` + `B2_ACCOUNT_KEY` в env |
| WebDAV (Я.Диск / NextCloud / ownCloud) | `rclone:<remote>:backups/infra` | `rclone config` с типом webdav и endpoint провайдера |
| S3-совместимое (MinIO / Wasabi / Yandex Object Storage) | `s3:<endpoint>/<bucket>/backups/infra` | те же `AWS_*` env, endpoint подменён |
| Свой сервер по SFTP | `sftp:<host>:<путь>` | ssh-ключ на источнике + запись ключа в `authorized_keys` приёмника + `known_hosts` источника |

### Свой сервер по SFTP

Приёмник — не облако, а вторая машина: у неё нет ни ключей доступа, ни rclone, а вместо
них — обычный SSH. Отсюда пять граблей, каждая тихая.

- **Путь внутри chroot считается от корня chroot.** Запертая учётка бэкапа обычно живёт
  под `ChrootDirectory /var/sftp/repo`; тогда репозиторий `/var/sftp/repo/data` в URL
  пишется как `sftp:<host>:/data`, а не полным путём приёмника. Полный путь даёт
  `unable to open repository` при живом и исправном канале.
- **Каталог chroot обязан принадлежать root и не быть доступным на запись группе/всем** —
  требование sshd, не restic. Значит, сам репозиторий кладётся в ПОДКАТАЛОГ, владелец
  которого — учётка бэкапа. Иначе `restic init` упрётся в отказ на запись.
- **`ssh <host>` шелла не даст, и это норма.** У запертой учётки `ForceCommand internal-sftp`;
  проверять доступ надо `sftp -b /dev/null <host>`, а не `ssh <host> true` — иначе примешь
  исправный канал за сломанный.
- **`known_hosts` заполняется заранее, под тем пользователем, от которого пойдёт бэкап.**
  restic под cron/systemd запускается обычно от root и в неинтерактивном режиме: вопрос
  «доверять ли ключу хоста?» задать некому, задание молча падает. Первое подключение —
  руками, либо `ssh-keyscan` в `/root/.ssh/known_hosts`.
- **Параметры соединения держи в `~/.ssh/config` ТОГО пользователя, от которого пойдёт
  задание** (обычно root): алиас, `IdentityFile`, `Port`, `BatchMode yes`. В конфиг инфры
  идёт только алиас — это единственный источник правды, поэтому в схеме и нет поля под
  ключ: «поле, которое читается, но никуда не применяется» опаснее его отсутствия.
  restic не пробрасывает ssh-флаги; всё, что не прописано в ssh-конфиге, пришлось бы
  передавать через `-o sftp.args` в КАЖДОМ вызове, и это первое, что забывается.

> **SFTP-приёмник — это не offsite.** Копия на второй машине в том же здании переживает
> смерть диска и кривой деплой, но не пожар, не затопление и не шифровальщика, добравшегося
> до обеих машин. Если это единственная копия — скажи оператору прямо и предложи третий
> уровень в облако.

### WebDAV-хранилища через rclone (Яндекс.Диск, NextCloud, ownCloud)

- **Тротлинг при параллельных upload'ах.** Особенно характерно для Яндекс.Диска
  (но встречается и у других провайдеров). В `~/.config/rclone/rclone.conf`
  обязательно `transfers = 1` для соответствующего remote. Иначе `restic backup`
  падает на полпути с `429 Too Many Requests` без человекочитаемой ошибки.
- **WebDAV не поддерживает range-запросы.** `restic prune` через WebDAV занимает 30+ минут
  на репозиториях >50 ГБ — он перезаписывает индексные файлы целиком. Запускай prune только
  по воскресеньям, а не ежедневно.
- **Чувствительность к timeout'у.** Если `restic backup` падает с `connection reset by peer`,
  добавь `--option rclone.connect-timeout=10m` (по умолчанию 60s).
- **Endpoint провайдера:** для Яндекс.Диска — `https://webdav.yandex.ru`
  (не `disk.yandex.ru`!); для NextCloud — `https://<cloud>/remote.php/webdav/`;
  у других провайдеров уточнять в их документации.

### S3-совместимое (AWS S3, Yandex Object Storage, MinIO)

- **`restic init` с минимальными правами.** Bucket-полиси должны разрешать
  `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:ListBucket`. Без `DeleteObject`
  работает `backup`/`restore`, но `forget`/`prune` молча игнорируют удаление.
- **MinIO без TLS:** добавь `--no-cache` если репозиторий локальный — иначе кэш растёт без
  ограничений в `~/.cache/restic/`.
- **Yandex Object Storage:** endpoint `https://storage.yandexcloud.net`, регион `ru-central1`.
  В `RESTIC_REPOSITORY=s3:storage.yandexcloud.net/<bucket>/path`.

### Backblaze B2

- **B2 application key, не account key!** `B2_ACCOUNT_ID` = applicationKeyId,
  `B2_ACCOUNT_KEY` = applicationKey. Глобальный account key даёт доступ ко всем bucket'ам —
  нарушение принципа least privilege.
- **Region prefix:** для B2 endpoint автоматически вычисляется из bucket-name; вручную
  endpoint указывать не надо.

## Параметры backup

- **`--exclude` patterns:** глобальные паттерны не работают как gitignore. Используй
  `--exclude-file` со списком файлов или `--exclude '*.tmp'` для конкретного расширения.
- **`--ignore-inode`:** обязательно на больших БД (>5 ГБ) — иначе restic считает inode
  частью identity файла и каждый снимок передаёт всё заново при перемещении файла.
- **`--one-file-system`:** не пересекать границы FS (полезно если `/opt/backups` —
  отдельный mount, а внутри есть другой mount).

## Параметры forget / prune

- **`forget` без `--prune` НЕ освобождает место.** Просто помечает snapshot'ы удалёнными в
  индексе. Реальное удаление происходит только в `prune` (или `forget --prune`).
- **`--keep-tag` для долгосрочного хранения.** Помечай критичные snapshot'ы тегом
  (например, `restic backup --tag yearly-2026`), чтобы forget их никогда не удалил.
- **Параллельный forget небезопасен.** Запускай только в одном экземпляре одновременно —
  иначе lock-файл в репозитории конфликтует.

## Безопасность passphrase

- **Потеря passphrase = потеря бэкапов навсегда.** Восстановление невозможно (AES-256
  без ключа не расшифровать). Храни passphrase в менеджере паролей + бумажной копии в
  сейфе на крайний случай.
- **Не передавай passphrase через `RESTIC_PASSWORD` в command line!** Видно в `ps`. Используй
  `--password-file /root/.restic-password` (chmod 600).
- **Не клади passphrase-файл в git.** Добавь в `.gitignore` явно.

## Производительность

- **Первый прогон долгий.** На 50 ГБ через WebDAV — 4-8 часов. Запускай первый раз не из
  cron, а руками.
- **Кэш в `~/.cache/restic/`.** Растёт по размеру индекса репозитория. Обычно 100-500 МБ.
  Не очищай — иначе следующий прогон опять долгий.
- **`restic check`.** Раз в месяц для верификации целостности репозитория. Не делай
  ежедневно — занимает столько же времени, сколько backup.

## Частые ошибки

| Ошибка | Причина | Решение |
|--------|---------|---------|
| `unable to open repository` | Wrong RESTIC_REPOSITORY URL | Проверь rclone config / S3 endpoint; для sftp — путь считается от корня chroot |
| `Permission denied (publickey)` в задании cron/systemd | ключ или `known_hosts` есть у оператора, но не у пользователя задания | Проверь от имени того же пользователя: `sudo -u <кто> sftp -b /dev/null <host>` |
| `wrong password or no key found` | Wrong RESTIC_PASSWORD | Используй password-file |
| `repository does not exist` | Не сделан `restic init` | `restic init` один раз на репозиторий |
| `Lock failed` | Параллельный backup | Дождись завершения или `restic unlock` |
| `429 Too Many Requests` | rclone тротлинг | `transfers = 1` в rclone.conf |
| `connection reset by peer` | timeout WebDAV/S3 | `--option *.connect-timeout=10m` |

## Mind-map

```
restic-репозиторий
├── /data           — encrypted blobs (само содержимое)
├── /index          — индекс blobs
├── /keys           — ключ AES-256 (зашифрованный passphrase)
├── /locks          — lock-файлы (удаляй через restic unlock при сбое)
├── /snapshots      — метаданные snapshot'ов (timestamp, paths)
└── config          — конфиг репозитория
```