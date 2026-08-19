#!/usr/bin/env python3
"""
Тест схемы карты инфраструктуры `infra-config.schema.json`.

Схема — это КОНТРАКТ: по ней `/sysadmin-init` создаёт и проверяет `infra-config.json`
в папке инфры оператора. Пока тестов не было, любая правка схемы проверялась глазами,
а «JSON разбирается» принималось за «схема работает». Это разные вещи: файл может
успешно разбираться и при этом пропускать конфиг, который обязан был отклонить.

Запуск из корня репо:  python3 scripts/test-infra-config-schema.py

Требует `jsonschema`. Многие системные python его ставить не дают (PEP 668,
«externally-managed-environment»), поэтому модуль живёт в отдельном окружении, а тест
сам туда перезапускается: сперва каталог из переменной `SYSADMIN_VENV`, затем `.venv`
в корне репозитория. Не нашлось ни того ни другого — честный отказ, а не молчаливый
зелёный: сломанный тест печатает «чисто» так же, как исправный.

Завести окружение:  python3 -m venv .venv && ./.venv/bin/python3 -m pip install jsonschema

Каждый случай проверяется В ОБЕ СТОРОНЫ — что схема пропускает валидное И что она
отклоняет невалидное. Проверка только на здоровом входе доказывает лишь то, что код
запустился.

Отдельно помечены случаи ИСТОРИЧЕСКОГО ДЕФЕКТА (маркер `[дефект]`) — те, что на прежней
версии схемы вели себя неправильно. Они доказывают, что тест видит разницу между
починенной и непочиненной схемой, а не просто соглашается с текущим файлом.
"""

import copy
import json
import os
import sys
from pathlib import Path


def _reexec_in_venv():
    """Перезапуск в отдельном окружении, если в текущем python нет jsonschema.

    Флаг в окружении защищает от петли: в перезапущенном процессе повторной попытки
    уже не будет, и он честно дойдёт до отказа.
    """
    if os.environ.get("SYSADMIN_SCHEMA_REEXEC") == "1":
        return
    root = Path(__file__).resolve().parent.parent
    candidates = []
    if os.environ.get("SYSADMIN_VENV"):
        candidates.append(Path(os.environ["SYSADMIN_VENV"]))
    candidates.append(root / ".venv")
    for venv in candidates:
        for rel in ("bin/python3", "Scripts/python.exe"):   # POSIX и Windows
            exe = venv / rel
            if exe.exists():
                env = dict(os.environ, SYSADMIN_SCHEMA_REEXEC="1")
                os.execve(str(exe), [str(exe), str(Path(__file__).resolve()), *sys.argv[1:]], env)


try:
    import jsonschema
except ImportError:
    _reexec_in_venv()          # не вернётся, если окружение нашлось
    print("ОТКАЗ: не установлен модуль jsonschema.")
    print("       Заведи окружение в корне репозитория:")
    print("         python3 -m venv .venv && ./.venv/bin/python3 -m pip install jsonschema")
    print("       Или укажи готовое: SYSADMIN_VENV=/путь/к/venv")
    print("       Без него проверить схему нечем — молча зелёным не притворяюсь.")
    sys.exit(2)

if hasattr(sys.stdout, "reconfigure"):
    # На машине оператора консоль в cp1252: print с кириллицей падает без этого.
    sys.stdout.reconfigure(encoding="utf-8")

ROOT = Path(__file__).resolve().parent.parent
SCHEMA_PATH = ROOT / "infra-config.schema.json"

# Минимальный валидный конфиг — основа для мутаций.
BASE = {
    "version": "1.0",
    "monitoring": {"enabled": False},
    "backups": {"enabled": False},
    "notifications": {"telegram": {"enabled": False}},
    "servers": [{"alias": "SRV", "ssh_alias": "SRV", "role": "production"}],
}


def mutate(**patch):
    """Копия базового конфига с заменёнными разделами верхнего уровня."""
    cfg = copy.deepcopy(BASE)
    cfg.update(copy.deepcopy(patch))
    return cfg


# (описание, конфиг, ожидается_валидным)
CASES = [
    # --- база ---
    ("минимальный конфиг, всё выключено", BASE, True),
    ("нет обязательного раздела servers", {k: v for k, v in BASE.items() if k != "servers"}, False),

    # --- наблюдение: готовый стек ---
    (
        "наблюдение включено, стек и панель указаны",
        mutate(monitoring={"enabled": True, "kind": "stack",
                           "stack": ["uptime-kuma"], "panel_domain": "sysadmin.example.com"}),
        True,
    ),
    (
        "наблюдение включено как стек, но панель не указана",
        mutate(monitoring={"enabled": True, "kind": "stack", "stack": ["uptime-kuma"]}),
        False,
    ),
    (
        "наблюдение включено, kind не задан (по умолчанию стек) — без стека и панели",
        mutate(monitoring={"enabled": True}),
        False,
    ),
    (
        "продукт вне списка допустимых",
        mutate(monitoring={"enabled": True, "kind": "stack",
                           "stack": ["zabbix"], "panel_domain": "m.example.com"}),
        False,
    ),

    # --- наблюдение: самописное (ради этого схема и правилась) ---
    (
        "[дефект] наблюдение самописное: ни стека, ни панели — и это норма",
        mutate(monitoring={"enabled": True, "kind": "custom"}),
        True,
    ),
    (
        "самописное наблюдение с указанной панелью — панель не запрещена, просто не обязательна",
        mutate(monitoring={"enabled": True, "kind": "custom", "panel_domain": "watch.example.com"}),
        True,
    ),
    (
        "kind вне списка допустимых",
        mutate(monitoring={"enabled": True, "kind": "самописное"}),
        False,
    ),
    (
        "лишнее поле в разделе наблюдения",
        mutate(monitoring={"enabled": True, "kind": "custom", "выдуманное_поле": 1}),
        False,
    ),

    # --- уведомления ---
    (
        "Telegram включён, есть имя бота и тип чата",
        mutate(notifications={"telegram": {"enabled": True,
                                           "bot_username": "my_alerts_bot",
                                           "chat_type": "personal"}}),
        True,
    ),
    (
        "Telegram включён, но тип чата не указан",
        mutate(notifications={"telegram": {"enabled": True, "bot_username": "my_alerts_bot"}}),
        False,
    ),
    (
        "имя бота с символом @ — шаблон запрещает",
        mutate(notifications={"telegram": {"enabled": True,
                                           "bot_username": "@my_alerts_bot",
                                           "chat_type": "personal"}}),
        False,
    ),

    # --- бэкапы ---
    (
        "бэкапы включены, но не сказано куда и с какой глубиной",
        mutate(backups={"enabled": True}),
        False,
    ),
    (
        "бэкапы на WebDAV без имени удалённого хранилища",
        mutate(backups={"enabled": True, "destination": "yandex-disk-webdav",
                        "retention": {"daily": 7, "weekly": 4, "monthly": 6}}),
        False,
    ),

    # --- серверы ---
    (
        "роль сервера вне списка допустимых",
        mutate(servers=[{"alias": "SRV", "ssh_alias": "SRV", "role": "боевой"}]),
        False,
    ),
    (
        "два сервера — норма",
        mutate(servers=[{"alias": "A", "ssh_alias": "A", "role": "production"},
                        {"alias": "B", "ssh_alias": "B", "role": "production"}]),
        True,
    ),

    # --- VPN ---
    (
        "VPN включён без адреса панели",
        mutate(vpn={"enabled": True}),
        False,
    ),
    (
        "серверный прокси включён, а upstream не настроен",
        mutate(vpn={"enabled": True, "panel_url": "https://vpn.example.com:2053",
                    "panel_web_base_path": "see-manager:panel",
                    "server_proxy_enabled": True, "upstream_kind": "none"}),
        False,
    ),
    (
        "серверный прокси включён поверх своего заграничного VPS",
        mutate(vpn={"enabled": True, "panel_url": "https://vpn.example.com:2053",
                    "panel_web_base_path": "see-manager:panel",
                    "server_proxy_enabled": True, "upstream_kind": "self-foreign"}),
        True,
    ),
]


def main():
    if not SCHEMA_PATH.exists():
        print(f"ОТКАЗ: не нашёл схему {SCHEMA_PATH}")
        return 2

    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))

    # Сама схема обязана быть законной схемой, а не просто разбираемым JSON.
    validator_cls = jsonschema.validators.validator_for(schema)
    try:
        validator_cls.check_schema(schema)
    except jsonschema.exceptions.SchemaError as exc:
        print("ОТКАЗ: схема не является корректной JSON Schema")
        print(f"       {exc}")
        return 2
    validator = validator_cls(schema)

    print("── test-infra-config-schema ────────────────────────")
    print(f"схема: {SCHEMA_PATH.name} ({validator_cls.__name__})\n")

    failed = 0
    for title, cfg, should_pass in CASES:
        errors = sorted(validator.iter_errors(cfg), key=lambda e: e.path)
        actually_passed = not errors
        ok = actually_passed == should_pass

        if ok:
            mark = "✅"
            tail = "пропущен" if should_pass else "отклонён"
        else:
            mark = "❌"
            failed += 1
            tail = ("ПРОПУЩЕН, а должен быть отклонён" if actually_passed
                    else "ОТКЛОНЁН, а должен быть пропущен")

        print(f"  {mark} {title}")
        print(f"      ожидалось: {'пропустить' if should_pass else 'отклонить'} — {tail}")
        if not ok and errors:
            print(f"      причина отказа: {errors[0].message[:120]}")

    print("\n────────────────────────────────────────────────────")
    if failed:
        print(f"FAIL — случаев не сошлось: {failed} из {len(CASES)}")
        return 1
    print(f"PASS — все {len(CASES)} случаев ведут себя как задумано")
    return 0


if __name__ == "__main__":
    sys.exit(main())
