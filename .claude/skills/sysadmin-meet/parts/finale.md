**Финальное напутствие при выборе «запустить /sysadmin-init».**

Перед выводом этого текста — обнови onboarding-флаг в `sysadmin-config.json`,
если конфиг уже существует (повторное прохождение знакомства, или пользователь
сначала запустил /sysadmin-init без знакомства, теперь возвращается). Ставишь
`meta.onboarding_completed: true`. Это останавливает напоминания агента.

```bash
if [ -f sysadmin-config.json ]; then
    if jq -e '.meta' sysadmin-config.json >/dev/null 2>&1; then
        # Поле meta уже есть — обновляю
        tmp=$(mktemp) && jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '.meta.onboarding_completed = true | .meta.onboarding_completed_at = $ts' \
            sysadmin-config.json > "$tmp" && mv "$tmp" sysadmin-config.json
    else
        # Старый конфиг без meta — создаю блок целиком
        tmp=$(mktemp) && jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '. + {meta: {onboarding_completed: true, onboarding_completed_at: $ts}}' \
            sysadmin-config.json > "$tmp" && mv "$tmp" sysadmin-config.json
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
