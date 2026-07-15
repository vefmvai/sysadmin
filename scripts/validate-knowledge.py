#!/usr/bin/env python3
"""
Валидатор доменной базы знаний .claude/knowledge/ (ADR-0003 «knowledge», ADR-0006 «слои»).

Адаптация валидатора из проекта bb (docs/validate-knowledge.py) под СЛОИСТУЮ модель
sysadmin: knowledge живёт как `<домен>/{_live,_reference,_meta,_diagrams}/*.md` с
машиночитаемым frontmatter, а не как Obsidian-граф с [[wiki-ссылками]].

Запуск из корня репо:  python3 scripts/validate-knowledge.py

Проверяет:
  1. FRONTMATTER (hard): YAML валиден + обязательные ключи ядра + `layer` совпадает с
     каталогом (`_live`→live, `_reference`→reference, `_meta`→meta) + `ttl_days` равен
     канону слоя (14/60/365, ADR-0006). Ловит файлы без frontmatter (их не видит
     check-knowledge-freshness.sh — они «невидимы» для контроля свежести).
  2. БИТЫЕ ПУТЕВЫЕ ССЫЛКИ (hard): markdown- и backtick-ссылки на .md С ПУТЁМ (содержат `/`)
     — внутрь knowledge (`_reference/…`, `_meta/…`) или в репо (`.claude/…`, `decisions/…`).
     Голые имена файлов без пути НЕ проверяются: они неоднозначны (`networks.md` —
     inventory, `sysadmin.md` — заглушка агента), проверка дала бы ложные срабатывания.
     Ссылки на живой слой `_live/*.md` (кроме `*.example.md`) НЕ проверяются: этот слой
     gitignored (у каждого пользователя свой, наполняется `/refresh-vpn-knowledge`) — в git
     его нет по дизайну, отсутствие файла ≠ битая ссылка.
  3. СИРОТЫ (мягко, не влияет на код выхода): knowledge-файл, чьё имя не упомянуто ни в
     README (каталог-индекс домена), ни в одном другом knowledge-файле.

СВЕЖЕСТЬ по датам (просрочен ли TTL) — НЕ здесь. Это отдельный
`.claude/skills/_lib/check-knowledge-freshness.sh` (его лениво зовёт персона §4.2).

Код выхода: 0 — чисто; 1 — есть hard-проблемы (frontmatter/битые ссылки); 2 — нет
папки knowledge. Скрипт read-only: ничего не меняет, только сообщает.
"""
import os
import re
import sys
import glob

try:
    import yaml
    HAS_YAML = True
except ImportError:
    HAS_YAML = False

KNOWLEDGE_DIR = ".claude/knowledge"

# Канон TTL по слою (ADR-0006). layer (из frontmatter / имени каталога) → ttl_days.
LAYER_TTL = {"live": 14, "reference": 60, "meta": 365}
# Каталог → ожидаемый layer.
DIR_LAYER = {"_live": "live", "_reference": "reference", "_meta": "meta"}
# Обязательные ключи frontmatter для knowledge-заметки.
REQUIRED_KEYS = ("knowledge_domain", "layer", "last_researched", "ttl_days", "sources_checked")

# Префиксы путей, которые резолвим от КОРНЯ репо (а не от домена knowledge).
REPO_ROOT_PREFIXES = (".claude/", "decisions/", "runbooks/", "scripts/", "docs/", "inventory/")
# Каталоги-слои внутри домена.
DOMAIN_DIRS = ("_live/", "_reference/", "_meta/", "_diagrams/")

# Ссылки: markdown `](target)` и backtick `` `target` `` где target оканчивается на .md (+опц. #anchor).
MD_LINK_RE = re.compile(r"\]\(([^)\s]+\.md(?:#[^)\s]*)?)\)")
TICK_REF_RE = re.compile(r"`([^`\s]+\.md)`")


def is_frontmatter_exempt(path: str) -> bool:
    base = os.path.basename(path)
    if base == "README.md" or base == ".gitkeep":
        return True
    if base.endswith(".example.md"):
        return True
    if os.sep + "_diagrams" + os.sep in path:   # диаграммы — не заметки-знания
        return True
    return False


def parse_frontmatter(text):
    """(data_dict_or_None, error_str_or_None). Без PyYAML — мягкий разбор ключей."""
    if not text.startswith("---"):
        return None, "нет frontmatter (файл не начинается с ---)"
    parts = text.split("---", 2)
    if len(parts) < 3:
        return None, "нет закрывающего --- у frontmatter"
    block = parts[1]
    if HAS_YAML:
        try:
            data = yaml.safe_load(block)
        except yaml.YAMLError as e:
            return None, "YAML-ошибка — " + str(e).splitlines()[0]
        if not isinstance(data, dict):
            return None, "frontmatter не разобрался в набор полей (ключ: значение)"
        return data, None
    # деградация без PyYAML: вытащим простые скаляры
    data = {}
    for m in re.finditer(r"^([a-z_]+):\s*(.*)$", block, re.M):
        data[m.group(1)] = m.group(2).strip()
    return data, None


def check_frontmatter(path, text):
    problems = []
    data, err = parse_frontmatter(text)
    if err:
        return [f"{path}: {err}"]
    for key in REQUIRED_KEYS:
        if key not in data or data.get(key) in (None, ""):
            problems.append(f"{path}: нет обязательного ключа `{key}` (или пустое значение)")
    # layer должен совпадать с каталогом
    parent = os.path.basename(os.path.dirname(path))
    expected_layer = DIR_LAYER.get(parent)
    layer = str(data.get("layer", "")).strip()
    if expected_layer and layer and layer != expected_layer:
        problems.append(f"{path}: layer=`{layer}`, а каталог `{parent}` ⇒ ожидался `{expected_layer}`")
    # ttl_days = канон слоя
    if layer in LAYER_TTL:
        try:
            ttl = int(str(data.get("ttl_days", "")).strip())
            if ttl != LAYER_TTL[layer]:
                problems.append(f"{path}: ttl_days={ttl}, канон слоя `{layer}` = {LAYER_TTL[layer]} (ADR-0006)")
        except (ValueError, TypeError):
            problems.append(f"{path}: ttl_days не число")
    return problems


def resolve_ref(ref, file_path, domain_dir, repo_root):
    """Вернуть абсолютный путь-кандидат для путевой ссылки, либо None если ссылку не проверяем."""
    ref = ref.split("#", 1)[0].strip()
    if not ref or ref.startswith(("http://", "https://", "mailto:")):
        return None
    if "/" not in ref:          # голое имя — неоднозначно, не проверяем (см. docstring)
        return None
    # Живой слой `_live/*.md` (кроме `*.example.md`) — gitignored (.gitignore: у каждого
    # пользователя свой, наполняется /refresh-vpn-knowledge). В git/свежем клоне его нет, поэтому
    # ссылки на него НЕ битые — просто не проверяем существование (файл — валиден по дизайну).
    norm = ref.replace("\\", "/")
    if "_live/" in norm and not norm.rsplit("/", 1)[-1].endswith(".example.md"):
        return None
    if ref.startswith(REPO_ROOT_PREFIXES):
        return os.path.join(repo_root, ref)
    if ref.startswith(DOMAIN_DIRS):
        return os.path.join(domain_dir, ref)
    if ref.startswith("../") or ref.startswith("./"):
        return os.path.normpath(os.path.join(os.path.dirname(file_path), ref))
    # прочие пути со слешем — пробуем от каталога файла
    return os.path.normpath(os.path.join(os.path.dirname(file_path), ref))


def main():
    # Windows-консоль по умолчанию cp1252 и падает на эмодзи (📊/✅) в выводе.
    # Форсируем UTF-8, где поток это поддерживает (Python 3.7+).
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except (AttributeError, ValueError):
        pass

    if not os.path.isdir(KNOWLEDGE_DIR):
        print(f"ОШИБКА: папка {KNOWLEDGE_DIR}/ не найдена. Запускай из корня репо.")
        return 2
    repo_root = os.getcwd()
    files = sorted(glob.glob(f"{KNOWLEDGE_DIR}/**/*.md", recursive=True))
    if not files:
        print(f"📊 {KNOWLEDGE_DIR}/ пуста — нечего проверять.")
        return 0

    fm_problems, broken, orphans = [], [], []
    real_bases = {os.path.basename(f) for f in files}
    texts = {f: open(f, encoding="utf-8").read() for f in files}

    # --- 1. frontmatter ---
    for f in files:
        if is_frontmatter_exempt(f):
            continue
        fm_problems.extend(check_frontmatter(f, texts[f]))

    # --- 2. битые путевые ссылки ---
    for f in files:
        # домен = .claude/knowledge/<домен>/...  → каталог домена
        rel = os.path.relpath(f, KNOWLEDGE_DIR)
        domain = rel.split(os.sep, 1)[0]
        domain_dir = os.path.join(KNOWLEDGE_DIR, domain)
        for rx in (MD_LINK_RE, TICK_REF_RE):
            for m in rx.finditer(texts[f]):
                cand = resolve_ref(m.group(1), f, domain_dir, repo_root)
                if cand and not os.path.exists(cand):
                    broken.append((f, m.group(1)))

    # --- 3. сироты (мягко) ---
    for f in files:
        if is_frontmatter_exempt(f) and os.path.basename(f) != "README.md":
            continue  # примеры/диаграммы/gitkeep не считаем сиротами
        base = os.path.basename(f)
        if base == "README.md":
            continue
        mentioned = any(base in texts[g] for g in files if g != f)
        if not mentioned:
            orphans.append(os.path.relpath(f, KNOWLEDGE_DIR))

    # --- отчёт ---
    print(f"📊 knowledge: {len(files)} файлов в {KNOWLEDGE_DIR}/\n")
    ok = True

    if fm_problems:
        ok = False
        print(f"❌ FRONTMATTER ({len(fm_problems)}): сломанный YAML / нет ключей / layer↔каталог / ttl↔канон —")
        print("    эти файлы невидимы для контроля свежести. Почини шапку заметки:")
        for p in sorted(set(fm_problems)):
            print(f"    • {p}")
        print()
    else:
        mode = "строгий YAML" if HAS_YAML else "мягкая проверка без PyYAML"
        print(f"✅ Frontmatter валиден, ключи/layer/ttl на месте ({mode})\n")

    if broken:
        ok = False
        print(f"❌ БИТЫЕ ПУТЕВЫЕ ССЫЛКИ ({len(set(broken))}):")
        for f, t in sorted(set(broken)):
            print(f"    • {f}: {t}")
        print()
    else:
        print("✅ Битых путевых ссылок нет\n")

    if orphans:
        print(f"⚠️  СИРОТЫ ({len(orphans)}) — имя файла не упомянуто ни в README, ни в соседях")
        print("    (через каталог-индекс к нему не прийти). Впиши в README домена или в родственный файл:")
        for o in sorted(orphans):
            print(f"    • {o}")
        print()
    else:
        print("✅ Сирот нет (каждый файл упомянут в README или соседе)\n")

    if not HAS_YAML:
        print("ℹ️  PyYAML не установлен — frontmatter проверен мягко. Строго: pip install pyyaml")
    print("ℹ️  Свежесть (просрочен ли TTL по датам) проверяет отдельно "
          "`.claude/skills/_lib/check-knowledge-freshness.sh`.\n")

    if ok:
        print("🟢 База знаний целостна.")
        return 0
    print("🔴 Найдены проблемы — см. выше.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
