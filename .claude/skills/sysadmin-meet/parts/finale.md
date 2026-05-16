**Финальное напутствие при выборе «запустить /sysadmin-init».**

Перед выводом этого текста — обнови onboarding-флаг в `sysadmin-config.json` оператора,
если конфиг уже существует (повторное прохождение знакомства, или пользователь
сначала запустил /sysadmin-init без знакомства, теперь возвращается). Ставишь
`meta.onboarding_completed: true`. Это останавливает напоминания агента.

Конфиг живёт в `infra/` оператора. Алгоритм поиска — тот же, что в Cold Start Protocol
персоны (см. `references/cold-start.md`): cwd, `../infra/`, `~/infra/`, типичные пути.

```bash
# Поиск конфига (тот же алгоритм что в Cold Start)
CONFIG_PATH=""
for candidate in \
    "./sysadmin-config.json" \
    "../infra/sysadmin-config.json" \
    "$HOME/infra/sysadmin-config.json" \
    "$HOME/work/infra/sysadmin-config.json" \
    "$HOME/projects/infra/sysadmin-config.json"; do
    if [ -f "$candidate" ]; then
        CONFIG_PATH="$candidate"
        break
    fi
done

if [ -n "$CONFIG_PATH" ]; then
    if jq -e '.meta' "$CONFIG_PATH" >/dev/null 2>&1; then
        # Поле meta уже есть — обновляю
        tmp=$(mktemp) && jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '.meta.onboarding_completed = true | .meta.onboarding_completed_at = $ts' \
            "$CONFIG_PATH" > "$tmp" && mv "$tmp" "$CONFIG_PATH"
    else
        # Старый конфиг без meta — создаю блок целиком
        tmp=$(mktemp) && jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '. + {meta: {onboarding_completed: true, onboarding_completed_at: $ts}}' \
            "$CONFIG_PATH" > "$tmp" && mv "$tmp" "$CONFIG_PATH"
    fi
    echo "Знакомство засчитано — агент больше не будет напоминать про /sysadmin-meet."
fi
```

Если конфига **нет** (типичный сценарий: новый пользователь, прошёл знакомство первым,
сейчас идёт на /sysadmin-init) — флаг поставит сам скилл /sysadmin-init после
создания конфига. Здесь ничего делать не нужно — просто выводи напутствие.

---

**Текст напутствия (показать оператору как есть):**

> Отлично. Сейчас знакомство завершается, и ты переходишь к технической настройке.
>
> Просто напиши в следующем сообщении:
>
> ```
> /sysadmin-init
> ```
>
> Скилл задаст тебе 6 вопросов про твой проект, всё объяснит по пути, и в конце
> создаст файл `sysadmin-config.json`. Это займёт около 5 минут.
>
> После этого ты сможешь работать с агентом полноценно. Напиши `@sysadmin привет,
> познакомься с моим сервером` — и он сам разберётся с чего начать.
>
> Удачи. И помни — этот скилл `/sysadmin-meet` всегда здесь, можешь перезапустить
> в любой момент, если что-то забудешь.
