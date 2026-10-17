# Внешний календарь — команда

Google, Яндекс и Календарь macOS подключаются в Настройках без команды ([calendars.md](calendars.md)). Если календарь не подходит ни под один из них (рабочий сервер со своим API, свой скрипт), его можно подключить командой: Mostik сам запускает выбранный файл и читает из него события.

Подключение: «Настройки → Встречи → Ещё → Команда календаря → Выбрать…». События команды сливаются с остальными источниками: одна и та же встреча (название без учёта регистра и минута начала) остаётся в версии Календаря macOS, Google или Яндекса.

## Как Mostik запускает команду

- Раз в 5 минут, пока нужны встречи, и по кнопке «Обновить». В промежутках работает кеш, интерфейс процесса не ждёт.
- Без оболочки: запускается сам файл, а не строка для `sh`. Аргументы — окно выборки ±7 дней в ISO 8601, UTC:

  ```
  <файл> --from 2026-10-09T09:00:00Z --to 2026-10-23T09:00:00Z
  ```

- Окружение урезано: `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, `HOME`, `USER`, `LOGNAME`, `LANG`, `TMPDIR` и `MOSTIK_CALENDAR_FORMAT=1`. Ключи, прокси и прочее окружение Mostik команде не достаются: свои секреты команда берёт сама, например из связки ключей (`security find-generic-password -w …`).
- Текущая папка — временная папка macOS; stdin пустой, stderr не читается.
- Таймаут — 20 секунд, потом SIGTERM, через секунду SIGKILL. Вывод больше 2 МБ или больше 2000 событий не принимается.
- Ошибка (код выхода не 0, таймаут, не тот формат) не стирает прежние события; в Настройках видна строка «Ошибка: …».

## Какой файл подойдёт

Mostik запускает только:

- исполняемый файл (`chmod +x`) по полному пути; ссылка раскрывается до настоящего файла;
- принадлежащий вам или root;
- который не могут изменить другие пользователи: ни сам файл, ни его папка (если у папки нет sticky-бита).

Путь, выбранный в Настройках, Mostik запоминает отпечатком в связке ключей (`app.mostik.mac.hooks`, запись `calendar-command`), как команду хука встречи. Если путь вписан в `settings.json` в обход Mostik (руками, установщиком, другой программой), команда не запускается, пока вы не подтвердите её в окне «Подключить внешний календарь?». «Не запускать» убирает путь из настроек.

## Формат вывода

stdout — JSON: объект с ключом `events` или просто массив событий.

```json
{
  "events": [
    {
      "id": "42",
      "title": "Планёрка",
      "start": "2026-10-16T10:00:00+03:00",
      "end": "2026-10-16T10:30:00+03:00",
      "attendees": ["Анна Иванова", "Вы"],
      "others": ["Анна Иванова"],
      "emails": ["anna@example.com"],
      "link": "https://zoom.us/j/123",
      "notes": "Повестка"
    }
  ]
}
```

| Поле | Обязательно | Что это |
|---|---|---|
| `start`, `end` | да | ISO 8601 с часовым поясом, дробные секунды допустимы. `end` не раньше `start` |
| `title` | нет | Название, до 200 знаков |
| `id` | нет | Устойчивый идентификатор; без него — название и время начала |
| `attendees` | нет | Все участники, включая вас. Встречей считается событие от двух участников: остальные Mostik не показывает, как и в Календаре macOS |
| `others` | нет | Участники без вас: по ним подписывается собеседник, если он один. Нет поля — берутся `attendees` |
| `emails` | нет | Почта участников без вас — для черновика предупреждения о записи |
| `link` | нет | Ссылка на звонок |
| `notes` | нет | Описание, до 2000 знаков |
| `all_day` | нет | `true` — событие на весь день, Mostik его пропускает |

Событие без дат или с неверными датами пропускается, остальные читаются. Невалидный JSON — ошибка целиком.

## Пример

Самая короткая команда — файл с событиями, который обновляет что-то другое:

```sh
#!/bin/sh
# ~/bin/calendar-events — отдаёт подготовленный файл; аргументы --from/--to можно не использовать.
exec cat "$HOME/.cache/my-calendar/events.json"
```

Команда, которая сама ходит в API и берёт ключ из связки ключей:

```python
#!/usr/bin/env python3
import json, subprocess, sys, urllib.request

args = dict(zip(sys.argv[1::2], sys.argv[2::2]))
token = subprocess.run(["security", "find-generic-password", "-s", "my-calendar", "-w"],
                       capture_output=True, text=True, check=True).stdout.strip()
req = urllib.request.Request(f"https://calendar.example.com/api/events?from={args['--from']}&to={args['--to']}",
                             headers={"Authorization": f"Bearer {token}"})
with urllib.request.urlopen(req, timeout=15) as r:
    items = json.load(r)
print(json.dumps({"events": [
    {"id": e["id"], "title": e["name"], "start": e["start"], "end": e["end"],
     "attendees": [p["name"] for p in e.get("people", [])]}
    for e in items
]}))
```

Проверить команду без Mostik: запустите её с аргументами из примера выше и прогоните вывод через `python3 -m json.tool`.

## Куда уходят события

Как и события других источников: в словарь распознавания, названия и участники встреч, напоминания, справка перед встречей и, если вы подключили агентов, ответы им (см. [PRIVACY.md](../PRIVACY.md)). Сам Mostik события никуда не отправляет.

---

**English.** Settings → Meetings → More → Calendar command runs an executable of your choice every 5 minutes with `--from`/`--to` (ISO 8601, UTC) and reads events from stdout as JSON (`{"events": [...]}` or a bare array; fields as in the table above). No shell, a stripped environment (system `PATH`, `HOME`, `USER`, `LOGNAME`, `LANG`, `TMPDIR`, `MOSTIK_CALENDAR_FORMAT=1`), 20 s timeout, 2 MB / 2000 events cap. The file must be yours or root's, executable and not writable by others. A path set outside Mostik is not run until you confirm it. Events are merged with the other sources; duplicates keep the macOS, Google or Yandex version.
