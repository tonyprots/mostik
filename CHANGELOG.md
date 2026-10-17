# Журнал изменений / Changelog

Формат — [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/), версии — [SemVer](https://semver.org/lang/ru/).
English summary follows each release.

## Не выпущено

## 0.1.1 — 2026-10-17

### Словарь
- Термины из кода стали режимом для разработчиков и по умолчанию выключены — и в новой установке, и после обновления. Раньше Mostik брал словарь из репозитория, открытого в терминале или редакторе: тысячи имён из кода перетягивали русские слова и фразы в короткие английские термины. Теперь словарь собирается из ваших папок с документами и заметками, календаря и личного словаря. Включить: Настройки → Приватность и данные → Дополнительно → «Термины из кода»; там же автопоиск проекта и запасная папка. Если выбрать папку проекта в «Словаре», режим включится сам.
- В папках с документами Mostik больше не читает код: пропускает исходники (`.js`, `.py`, `.swift` и другие), вложенные репозитории и блоки кода внутри заметок.
- Mostik больше не запрашивает доступ к «Документам», «Рабочему столу» и «Загрузкам». Запрос шёл от поиска корня репозитория в папке, где запущен агент: при каждой диктовке, в окнах tmux и в голосовых объявлениях агента. Теперь этот поиск работает только в режиме для разработчиков, и подсказка к переключателю предупреждает о запросе macOS.

### Диктовка
- После диктовки остаётся одна всплывашка «N слов под вопросом». Вторая карточка, «Слово распознано не так?», появляется, только если сомнений нет.
- Исправление слова в Mostik попадает и в сам текст, если после вставки его никто не трогал. Mostik ждёт, пока вы вернётесь в то приложение, отменяет свою вставку и вставляет исправленный вариант. Если текст в поле успели изменить, Mostik его не трогает и пишет «Исправлено только в Mostik».
- Клик по подсвеченному слову в диктовке прокручивает к нему в списке «Слова под вопросом».

### Онбординг
- Вместо пары «Продолжить» / «Позже» осталась одна кнопка «Дальше». Убрана кнопка «Проверить всё подробно».
- Клавишу диктовки можно выбрать на последнем шаге. Там же стоит «Запускать Mostik при входе в систему», по умолчанию включено.
- Шаги про встречи и модель называются «Запись встреч» и «Сводки и чистый текст» и объясняют, что дают.

### Модель
- Вместо Claude Code подойдёт Codex: если Claude Code не установлен, сводки и чистка текста идут через `codex exec`. В интерфейсе этот вариант называется «Claude/Codex».

English: terms from code are now a developer option, off by default for new installs and updates. The glossary comes from your document folders, calendar and personal glossary; the repository open in your terminal or editor is no longer scanned unless you turn on Settings → Privacy & Data → Advanced → “Terms from code”. Document folders skip source files and code blocks. One popup after a dictation instead of two. Fixing a word also fixes the inserted text when it is untouched. Clicking a highlighted word jumps to its row. Onboarding has a single “Next” button and lets you pick the dictation key. Codex works as a fallback for Claude Code.

## 0.1.0, дополнения к опубликованной сборке — 2026-10-17

### Запуск при входе
- Mostik запускается при входе в macOS: галочка на последнем шаге первого запуска (включена) и переключатель в Настройках → Основное → Запуск. У тех, кто уже прошёл первый запуск, автозапуск тоже включён. Если macOS не дала включить или ждёт разрешения в «Объектах входа», это видно в Диагностике, с кнопкой в Системные настройки.

English: Mostik now opens at login by default — a checkbox on the last onboarding step and a switch in Settings → General. Existing users get it on too. Registration problems show up in Diagnostics.

### Имена говорящих
- Кроме Zoom, Mostik ищет говорящего в Google Meet и Телемосте. Meet читается в Chrome, Яндекс Браузере, Arc, Edge, Brave, Opera и Vivaldi, Телемост — в браузере и в приложении для Mac. Окно выбирается по приложению, которое держит микрофон; у браузера читается только окно со звонком. Разбор Meet сделан по дереву с реального звонка, разбор Телемоста — предварительный, до проверки на звонке. Safari и Firefox пока не поддержаны.

English: Speaker names now also come from Google Meet and Yandex Telemost (browser and Mac app) via Accessibility; only the call window is read. Telemost parsing is provisional until checked on a live call.

### Обновления
- Выпуски подписаны своим постоянным сертификатом «Mostik Release», а не ad-hoc: разрешения macOS (микрофон, Универсальный доступ, «Запись экрана», звук системы) переживают обновление. Apple Developer ID не нужен.
- Проверка обновлений включена всегда, раз в день: вопрос при первом запуске и переключатель в Настройках убраны. Ставится обновление по кнопке в окне Sparkle; перезапуск ждёт, пока идёт запись.
- Обновление, подписанное другим сертификатом, Mostik не ставит молча, а объясняет, какие разрешения пришлось бы выдать заново.
- Лента — `https://tonyprots.github.io/mostik/appcast.xml`, файлы — GitHub Releases; у каждой версии указана минимальная macOS.
- `settings.json` и манифест встречи получили версию схемы: новые версии читают файлы старых, миграции только вперёд. При обновлении набора моделей докачиваются только изменившиеся файлы.

English: releases are signed with a stable self-signed “Mostik Release” certificate, so macOS permissions survive updates; update checks are always on (daily), installs need a click; an update signed differently is refused with an explanation; settings and meeting manifests are schema-versioned.

### Карточка встречи
- «Записать» в предложении записать звонок и в напоминании о встрече стала кнопкой со стрелкой: по стрелке — «Записать локально», запись сразу помечена «Только на этом Mac» — расшифровка и кадры экрана не уходят в Claude, агентам, MCP и скриптам. Флаг стоит в манифесте с первой секунды, а не ставится вручную после начала. Карточка больше не обещает «всё останется на этом Mac» для обычной записи.

English: “Record” on the call suggestion and meeting reminder gets a dropdown with “Record locally”, which starts a recording already marked “This Mac only” (no Claude, agents, MCP or scripts).

### Кадры встречи
- Кадры окна звонка снимаются и у встреч «Только на этом Mac», по тому же согласию на встречу. Они остаются в папке встречи и в локальном поисковом индексе; в Claude, агентам и скриптам их текст не уходит — тем же правилом, что и расшифровка. Пометка встречи больше не уносит уже снятые кадры в Корзину.

English: call-window frames are now captured for “This Mac only” meetings too; like the transcript, they stay on the Mac and only the local model sees them.

### Меню строки меню
- Пункт «Записать голос» рядом с «Записать встречу»: запись без удержания клавиши, как двойное нажатие; второе нажатие останавливает. Во время записи — «Остановить запись» и таймер, справа — подсказка клавиши (⌥⌥). Текст вставляется туда, где стоял курсор до меню; если то приложение закрыли — текст в буфере, плашка говорит об этом прямо.
- «Проверить обновления…» нет в сборках без ленты обновлений (сборки разработчика и ad-hoc).

English: “Record voice” menu item (hands-free, pastes where the cursor was); “Check for Updates…” is hidden until a real update feed is set.

### Вкладка «Диктовка»
- Блок «Слова под вопросом» больше не дописывается в текст для агентов, настройка «Слова под вопросом — агенту» и флаг сценария убраны. Слова под вопросом решаются в истории: «Запомнить» сразу правит текст записи и пополняет словарь, новое «Отклонить» снимает отметку и больше не предлагает этот вариант.
- «Запомнить написание…» снимает отметку сомнения у записи — раньше она оставалась.
- «Подробности» записи переехали в меню «…»; у названия приложения нет приписки «ИИ-агент».

English: unsure words are no longer appended for agents (setting removed); accept fixes the entry text, new Dismiss stops suggesting the pair; saving a spelling clears the doubt mark; Details moved into the “…” menu.

### Встречи
- Календарь выбирается явно: «Настройки → Встречи → Календарь» показывает Google Календарь, Яндекс Календарь и Календарь macOS, по умолчанию не подключён ни один. У каждого — окно «Календари…»: Mostik читает только отмеченные ([docs/calendars.md](docs/calendars.md)).
- Google — вход в браузере (OAuth с PKCE, только чтение); Яндекс — по CalDAV с паролем приложения. Ключ Google и пароль Яндекса хранятся в связке ключей, в настройках — только логин и список календарей. События запрашиваются раз в 5 минут, повторы Яндекса разворачиваются на Mac.
- Календарь macOS больше не читается целиком: доступ к нему запрашивается только по «Календарь macOS → Выбрать…», читаются отмеченные календари. После обновления календари macOS нужно выбрать заново — сами они не подключаются.
- Для календаря без Google и CalDAV — «Ещё → Команда календаря»: файл, который печатает события в JSON ([docs/external-calendar.md](docs/external-calendar.md)). Запуск без оболочки и без ключей Mostik, раз в 5 минут, таймаут 20 с. Путь, вписанный в настройки не в Mostik, не запускается до подтверждения.

English: calendars are now an explicit choice — Google (browser sign-in, read-only), Yandex (CalDAV with an app password) and the macOS Calendar, none connected by default, each with a calendar picker. Secrets live in the keychain. macOS calendars are no longer read wholesale; after updating, pick them again. A calendar command (More → Calendar command) covers servers without Google or CalDAV.

### Выпуск
- `scripts/check-denylist.sh`: строки из закрытого списка не попадают ни в коммит (хук pre-commit), ни в историю и файлы (CI), ни в собранное приложение (`bundle.sh`, `release.sh`). Список хранится вне репозитория.

English: a private denylist check guards commits, history, CI and the built app; the list itself lives outside the repository.

## 0.1.0 — 2026-10-11

Первая версия.

### Диктовка
- Зажатый правый ⌥ или ⌥Space — текст вставляется туда, где стоит курсор. Распознавание на устройстве: GigaAM v3 для русского, Parakeet TDT v3 для английского, проверяющая Whisper Turbo MLX в отдельном процессе.
- Блок сомнений для агентных приложений (Claude Code, Codex, Cursor, терминалы с агентом, в том числе агенты под node): какие слова могли быть расслышаны неверно и что предлагается взамен.
- Доставка текста: проверка вставки, откат ⌃⌘Z, повтор ⌃⌘V, сырая расшифровка ⌃⌘R, Esc на любом этапе; в поля паролей не вставляет.
- Мышь, гарнитура, приглушение звука на время записи, тёплый микрофон (переживает смену Bluetooth → встроенный), экран «Проверка».

### Словари
- Личный словарь и словарь проекта из репозитория, календаря и папок с заметками; замены целыми словами.
- Обучение на правках после вставки, «Запомнить написание», импорт из Handy, Wispr Flow, CSV и буфера; автоопределение языка из выбранных.

### Причёсывание и голосовые команды
- Причёсывание локальной моделью (Gemma 4 E2B через MLX) или через `claude -p` после согласия: стили, правила речи, контекст поля, сценарии по приложению и сайту, перевод, задача агенту, защита от инъекции.
- Голосовая правка выделенного, команды-намерения ⌃⌘K: событие, напоминание или письмо черновиком.

### Встречи
- Запись своего микрофона и звука собеседников отдельными дорожками, пометки, пауза, живая расшифровка, режим «только текст», продолжение записи, ⌃⌘M.
- Расшифровка с говорящими, голосовая память по согласию, ремонт меток с прослушиванием.
- Сводки по шаблонам, протокол, задачи, рецепты и следующие шаги; вопросы по ходу встречи и подсказки; кадры окна звонка по согласию.
- Архив встреч файлами и через MCP: брифы, люди, темы, недельные сводки.

### Для агентов
- CLI `mostik`, MCP-сервер, скилл `/mostik` и хук SessionStart для Claude Code и Codex — установка по кнопке с просмотром изменений; вставка в панель tmux, озвучка хода агента.

### Прод-укрепление
- Пути к движку и Python без привязки к машине разработчика: движок ищется внутри `.app`, затем по переменным окружения.
- Автообновление на Sparkle 2 с подписанной лентой на GitHub Pages; приложение подписано собственным сертификатом «Mostik Release», поэтому разрешения macOS переживают обновления. Установка одной командой с проверкой подписи, `.dmg`, запуск при входе в систему (по умолчанию включён).
- Перезапуск упавшего движка, журналы в `~/Library/Logs/Mostik` с ротацией, локальные отчёты о сбое.
- Интерфейс на русском и английском без пропусков, подписи VoiceOver, сочетания окна (⌘, ⌘1…⌘3, ⌘W), контраст палитры не ниже 4,5:1 в обеих темах; стражи локализации, доступности и контраста в тестах.
- CI на GitHub Actions, лицензия MIT, `SECURITY.md`, `PRIVACY.md`.

### English summary

First release. On-device dictation for macOS that pastes at the cursor and marks words it may have misheard so you can accept or dismiss them; personal and project glossaries that learn from your edits; optional text polishing (local MLX model or `claude -p` with consent), voice edit and voice intents; meeting recording with separate tracks, speakers, summaries, minutes, tasks and a meeting archive; CLI, MCP server and skill for Claude Code and Codex. Production hardening: no machine-specific paths, Sparkle updates signed with the project's own certificate (permissions survive updates), one-command install with a signature check, launch at login, crash-safe engine restarts, local logs, full Russian and English UI, VoiceOver labels, WCAG contrast, CI, MIT license.

