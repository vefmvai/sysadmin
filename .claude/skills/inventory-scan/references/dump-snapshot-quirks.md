# dump-snapshot.sh — известные квирки и обходы

Памятка для скилла `inventory-scan`. Здесь собраны типичные баги, симптомы
и обходы, наблюдавшиеся при инвентаризации обжитых серверов. Когда snapshot
ведёт себя странно — сначала проверяем здесь.

---

## tls-certs.txt — пустой или с syntax error

**Симптом v1:** файл `tls-certs.txt` содержит `unexpected end of file` или
`unmatched '`. Даты сертификатов не выдаёт.

**Причина:** в первой версии скрипта внутри двойных кавычек был
неэкранированный апостроф в `Let's Encrypt`. Bash парсил его как начало
строки, и вся подоболочка валилась.

**Лечение в v2 (bundled):** обёрнуто в `set +e; ... ; true`. Если openssl
не найдёт сертификат — пишем пустоту, не валим скрипт. Для acme.sh добавлен
отдельный `ls ~/.acme.sh/*/fullchain.cer`.

**Открытое (пример honest-unknown):** некий домен `<example.com>` имеет
работающий TLS-сертификат, но он не в стандартных папках (`/etc/letsencrypt/`,
`~/.acme.sh/`) — источник неизвестен. Записывается в inventory как
`tls_source = ? уточнить` + todo с расследованием.

---

## SSH-alias из ~/.ssh/config не работает в bash sandbox

**Симптом:** `ssh prod-server 'echo ok'` падает с
`Could not resolve hostname prod-server`, хотя из обычного терминала
работает.

**Причина:** агентский bash sandbox не загружает пользовательскую
конфигурацию SSH (нет `~/.ssh/config` в search path или `BatchMode=yes`
не пускает). Алиасы из ProxyJump-конфигов тоже не работают.

**Обход:** в `dump-snapshot.sh` всегда передавать прямой `user@host`,
а не алиас. Если нужен явный ключ — `-i ~/.ssh/id_<key>`.

---

## find -mtime +N округляет вниз

**Симптом:** `find -mtime +1` пропускает файлы, которые «вчера», но
ещё не прошло 48 часов с их создания.

**Причина:** `-mtime +N` означает «возраст СТРОГО больше N полных дней».
Файл, созданный 30 часов назад, имеет возраст 1 полный день — не больше.

**Обход для retention snapshot'ов:** сортировать по имени, не по `-mtime`:

```bash
find "$SNAPSHOTS_DIR" -mindepth 1 -maxdepth 1 -type d \
  | sort -r | tail -n +$((RETENTION+1)) | xargs -r rm -rf
```

Snapshot'ы датированы (YYYY-MM-DD), сортировка по имени = сортировка по
дате. Никаких сюрпризов с округлением.

---

## host-env-redacted.txt — пароли в URL не маскируются

**Симптом:** в `.env` есть `DATABASE_URL=postgres://user:secret@host/db`.
Скрипт маскирует через `sed "s/=.*/=<HIDDEN>/"` — значит, `DATABASE_URL`
будет полностью скрыт, **но** при сравнении с реальным `.env` в `inventory`
оператор может увидеть полный URL в каком-то документе, забыв про маскирование.

**Лечение:** до коммита inventory-документов агент **обязан** запустить
gitleaks. Файл `containers-inspect.json` всегда даёт ~40 false positives
(env-переменные внутри контейнеров) — это ожидаемо, пропускаем.

---

## containers-inspect.json — env-переменные plain text

**Симптом:** `docker inspect` выдаёт env-переменные контейнера без
маскирования. Пароли БД, JWT-секреты, API-ключи видны.

**Лечение:**
1. Файл лежит в `inventory/hosts/<host>/snapshots/<DATE>/` — папка
   snapshots в `.gitignore` (правило этапа 1).
2. В публичные документы (например, `services.md`) этот файл не копируется
   полностью — только нужные поля через `jq`, без env-секции.
3. Если нужно сохранить inspect для аудита — отдельно redact через `jq`:
   ```bash
   jq 'del(.[].Config.Env)' containers-inspect.json > containers-inspect-redacted.json
   ```

---

## TLS-сертификаты вне стандартных путей

**Симптом:** `tls-certs.txt` пустой, но HTTPS на сервере работает.

**Причина:** сертификат может быть выписан через другой ACME-клиент
(certbot, lego, dehydrated) и лежать в нестандартном пути. Или это
коммерческий сертификат, выпущенный вручную.

**Обход:** дополнительно проверить руками:
- `nginx -T | grep -E '(ssl_certificate|listen 443)'` — какой путь
  использует nginx
- `find / -name 'fullchain.pem' 2>/dev/null` — на свой страх и риск
- если не нашлось — `tls_source = ? уточнить` в domains.md

---

## ss vs netstat — может не быть ни того, ни другого

**Симптом:** в `host-resources.txt` секция «открытые порты» пустая или
содержит «команда не найдена».

**Причина:** минималистичные образы (alpine, distroless) могут не иметь
ни `ss` (часть iproute2), ни `netstat` (часть net-tools).

**Обход:** скрипт уже пробует обе. Если обе отсутствуют — пишет
«ss/netstat не найден», операторская задача добавить хотя бы iproute2:
`apt install iproute2` или эквивалент.

---

## docker system df -v — не показывает размер external volume

**Симптом:** `volumes.txt` показывает `<external-volume-name>` как 0 B, хотя
в нём гигабайты данных.

**Причина:** external volume Docker не может смерить через `system df`,
потому что не он его создавал. `system df` работает только с volume,
который Docker сам создал в рамках compose-проекта.

**Обход:** для external volume размер брать через
`du -sh /var/lib/docker/volumes/<name>/_data` (требует root на сервере).
В inventory `size = ? уточнить (external)` — это валидный honest unknown.

---

## Системные/snap-юниты загромождают systemd-enabled.txt

**Симптом:** список включённых юнитов 200+ строк, в основном `systemd-*`,
`sys-*`, `snap.*`.

**Лечение:** скрипт фильтрует через
`grep -vE '^(UNIT|[0-9]+ unit|systemd-|sys-|snap\.)'` и берёт первые 50
строк. Если оператор хочет увидеть всё — запустить вручную без фильтра.