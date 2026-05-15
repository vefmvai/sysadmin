# Python библиотеки и переменные прокси

Не все Python-библиотеки автоматически уважают `http_proxy`/`https_proxy` из
`/etc/environment`. Эта таблица — рабочая шпаргалка для случаев, когда
программа на сервере «не работает через прокси».

## Сводная таблица

| Библиотека | Версия | `HTTPS_PROXY` env | `socks5h://` | Workaround |
|---|---|---|---|---|
| `requests` | 2.x | ✅ автоматически | ✅ через PySocks | `requests.get(url, proxies={'https': 'socks5h://...'})` если env не работает |
| `urllib3` | 2.x | ✅ автоматически | ✅ через PySocks | `urllib3.contrib.socks.SOCKSProxyManager` |
| `httpx` | 0.27+ | ✅ если `trust_env=True` (default) | ✅ | `httpx.Client(trust_env=False, proxy="socks5h://...")` |
| `aiohttp` | 3.9+ | ❌ по умолчанию | ✅ через `aiohttp-socks` | `aiohttp.ClientSession(trust_env=True)` или явный `connector=ProxyConnector.from_url("socks5h://...")` |
| `openai` Python SDK | 1.x | ⚠️ через httpx (default trust_env=True) | ✅ | `openai.OpenAI(http_client=httpx.Client(proxy="socks5h://..."))` |
| `anthropic` Python SDK | 0.49+ | ⚠️ **БАГ** issue #923: не подхватывает env | ✅ через явный httpx | `anthropic.Anthropic(http_client=httpx.Client(proxy="socks5h://..."))` |
| Claude Code (CLI) | latest | ✅ через `HTTPS_PROXY` env | ✅ | env var в `.zshrc`/`.bashrc` или в env при запуске. **НЕ через `~/.claude/settings.json` — issue #11660** |
| `pip` | 23.x+ | ✅ автоматически | ✅ | `pip install --proxy socks5h://...` |
| `git` | 2.x+ | ✅ через `https_proxy` | ⚠️ socks5h только через git config `http.proxy` |  `git config --global http.proxy socks5h://...` |
| `curl` | 7.x+ | ✅ автоматически | ✅ | `--proxy socks5h://...` |
| `wget` | 1.x+ | ✅ через `https_proxy` | ❌ только HTTP-прокси | использовать `curl` |
| `apt` / `apt-get` | latest | ⚠️ только HTTP-прокси через apt.conf | ❌ | `Acquire::http::Proxy "http://..."` в `/etc/apt/apt.conf.d/95proxy` |
| `npm` | 9.x+ | ✅ через `http-proxy` config | ❌ HTTP only | `npm config set proxy http://...` |
| `Node.js` (http/https core) | 20.x+ | ❌ нативно не уважает | ✅ через npm-пакеты | `process.env.HTTPS_PROXY` + agent (`https-proxy-agent`, `socks-proxy-agent`) |
| `Go` (net/http stdlib) | 1.x+ | ✅ через `HTTP_PROXY` | ❌ только HTTP/HTTPS-прокси | для SOCKS5 — `golang.org/x/net/proxy` |

## Конкретные проблемы и решения

### anthropic Python SDK #923 — «proxy env vars не применяются»

**Симптом:**
```python
import anthropic
client = anthropic.Anthropic()  # игнорирует HTTPS_PROXY
client.messages.create(...)  # connection error к api.anthropic.com
```

**Решение:**
```python
import os, httpx, anthropic

proxy_url = os.getenv("HTTPS_PROXY", "")
http_client = httpx.Client(proxy=proxy_url) if proxy_url else None
client = anthropic.Anthropic(http_client=http_client)
```

### openai Python SDK — деградация после v1.x

**Симптом:** `openai.proxies = "..."` (старый способ) больше не работает в v1.x.

**Решение:** через `httpx.Client`:
```python
import httpx, openai
http_client = httpx.Client(proxy="socks5h://127.0.0.1:1080")
client = openai.OpenAI(http_client=http_client)
```

### Claude Code CLI — `HTTPS_PROXY` из `settings.json` не работает (issue #11660)

**Симптом:** добавил `"HTTPS_PROXY"` в `~/.claude/settings.json` — не подхватывает.

**Решение:** ставить через шелл:
```bash
# В ~/.zshrc или ~/.bashrc
export HTTPS_PROXY=socks5h://127.0.0.1:1080
export HTTP_PROXY=socks5h://127.0.0.1:1080
export NO_PROXY=localhost,127.0.0.1
```

Или однократно: `HTTPS_PROXY=socks5h://127.0.0.1:1080 claude code ...`

### aiohttp — `trust_env=False` по умолчанию

**Симптом:** программа на aiohttp не идёт через прокси даже с переменными в env.

**Решение:**
```python
import aiohttp
async with aiohttp.ClientSession(trust_env=True) as session:
    # теперь HTTPS_PROXY/HTTP_PROXY/NO_PROXY уважаются
    ...
```

Или явный:
```python
from aiohttp_socks import ProxyConnector
connector = ProxyConnector.from_url("socks5h://127.0.0.1:1080")
async with aiohttp.ClientSession(connector=connector) as session:
    ...
```

### apt не работает через SOCKS5 прокси

**Решение:** SOCKS5 прокси для apt не поддерживается напрямую. Варианты:
1. Поднять локальный HTTP-прокси (privoxy) поверх SOCKS5 и направить apt на него:
   ```
   # /etc/privoxy/config
   forward-socks5 / 127.0.0.1:1080 .
   ```
   ```
   # /etc/apt/apt.conf.d/95proxy
   Acquire::http::Proxy "http://127.0.0.1:8118";
   Acquire::https::Proxy "http://127.0.0.1:8118";
   ```
2. Использовать `proxychains` (легче, без сервиса):
   ```bash
   apt install proxychains4
   # /etc/proxychains4.conf:
   #   socks5 127.0.0.1 1080
   proxychains4 apt update
   ```

## Систематический подход для отладки

Когда программа «не работает через прокси»:

1. **Проверить, видит ли программа env vars:**
   ```bash
   ssh $TARGET 'env | grep -i proxy'
   ```

2. **Проверить, что прокси отвечает:**
   ```bash
   curl --max-time 10 --proxy socks5h://127.0.0.1:1080 https://api.anthropic.com
   ```
   Если 200 — прокси ок, проблема в библиотеке программы.

3. **Заглянуть в исходники программы** — поищи `os.environ.get('HTTPS_PROXY')`,
   `requests.Session(proxies=...)`, `httpx.Client(...)`. Это даст ясность,
   как программа настраивается.

4. **В крайнем случае — обернуть программу в `proxychains4`:**
   ```bash
   proxychains4 python my-app.py
   ```

## Связанные документы

- `socks5-vs-socks5h.md` (в этом же скилле) — почему буква `h` критична.
- `../../knowledge/networking/vpn-protocols.md` §5 — серверный прокси
  концептуально.

---

*Документ обновляется при добавлении новых проблем и решений.*
