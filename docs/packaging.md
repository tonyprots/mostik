# Сборка .app: встроенный Python, движок, модели

Mostik.app самодостаточен: внутри лежат свой Python, движок и код распознавания из transcriber.
Код transcriber — копия в репозитории, `engine/vendor_transcriber/` (источник, коммит и лицензия —
её `SOURCE.md`): ни сборка, ни движок соседний проект не читают.
Модели в бандл не входят — они скачиваются по кнопке или берутся из кэша Hugging Face.
На машине пользователя не нужны ни проект transcriber, ни его venv, ни Homebrew.

## Размер и состав

Замер сборки `MOSTIK_DIST=/tmp/mostik-clean scripts/bundle.sh` (пример):

| Часть | Путь в бандле | Размер |
|---|---|---|
| Весь .app на диске | `Mostik.app` | 599 МБ, 13 209 файлов |
| Он же в zip (`ditto -c -k`) | — | 194 МБ |
| Python 3.14.7 целиком | `Contents/Resources/python` | 574 МБ |
| из них пакеты | `python/lib/python3.14/site-packages` | 513 МБ |
| Движок | `Contents/Resources/engine` | 2,7 МБ |
| `audio_transcription` и `transcribe.py` | `Contents/Resources/engine/vendor_transcriber` | 0,5 МБ без байткода |
| Бинарник приложения (без отладочной карты) | `Contents/MacOS/Mostik` | 13 МБ |
| Sparkle | `Contents/Frameworks` | 2,9 МБ |

Около 110 МБ из этого — заранее собранный байткод (`.pyc`). Без него бандл весит 486 МБ,
но тогда Python при первом запуске пишет `__pycache__` внутрь .app и ломает печать подписи.

Основной вес в пакетах: `mlx` — около 200 МБ, `onnxruntime` — 75 МБ, `transformers` — 54 МБ,
`numpy` — 24 МБ. Из стандартной библиотеки вырезаны Tk, IDLE, pip, ensurepip, тесты, заголовки
и `share`.

## Встроенный Python

Источник — [python-build-standalone](https://github.com/astral-sh/python-build-standalone),
архив `cpython-3.14.7+20260929-aarch64-apple-darwin-install_only.tar.gz`. Имя и полная SHA256
закреплены в отслеживаемом `scripts/vendor.lock`; там же Sparkle. Папка `vendor/` в `.gitignore`:
архивы и распакованные деревья в репозиторий не попадают, а суммы — попадают. Подробно —
«Цепочка поставки» ниже.

Как подготовить `vendor/python` на машине сборщика:

```sh
python3 scripts/vendor_python.py extract --archive <архив.tar.gz> [--sums <SHA256SUMS>]
python3 scripts/vendor_python.py site
```

- `extract` сверяет имя и сумму архива со `scripts/vendor.lock` (файл сумм релиза — по желанию,
  дополнительно), проверяет пути внутри архива и распаковывает только в пустую `vendor/python`.
  Сумму записывает в `vendor/python/MOSTIK-VENDOR.json` — это след распаковки для `verify`.
- `site` копирует пакеты из списка `scripts/vendor-packages.txt` в `site-packages` по их `RECORD`.
  Сначала сверяет всё: версию и SHA256 файла `RECORD` — со `scripts/requirements.lock`, каждый
  файл — со своей строкой `RECORD`. Хоть одно расхождение — ничего не копирует.
  Источник — venv с версиями из `scripts/requirements.lock`, по умолчанию `engine/.venv-vendor`
  (пакеты `llm` — из `engine/.venv-llm`, а без него из того же venv); другие папки — `--tr` и `--llm`.
  Нет venv — скрипт останавливается и печатает, как его собрать:
  `python3.14 -m venv engine/.venv-vendor`, затем `engine/.venv-vendor/bin/pip install -r scripts/requirements.lock`.
  Сам `site` в сеть не ходит.
  Список — 29 пакетов, собранных трассировкой фактических импортов движка. `safetensors` в нём
  обязателен: `transformers` при импорте сверяет метаданные зависимостей.

Тот же `vendor/python` служит Python для разработки: `EngineLocator` и `bin/mostik` находят его
сами, если в бандле Python нет.

## Что делает `scripts/bundle.sh`

1. Копирует движок (без `.venv*` и `__pycache__`) вместе с `engine/vendor_transcriber` и Python из `vendor/python`.
2. Удаляет лишнее из стандартной библиотеки.
3. Собирает байткод (`scripts/compile-bytecode.sh`): `compileall --invalidation-mode unchecked-hash`.
   Такие `.pyc` не сверяются с датой исходника и остаются годными после копирования. Ключи
   `-s <Resources> -p Mostik.app/Contents/Resources` заменяют путь сборки в `co_filename`: без них
   домашняя папка сборщика оставалась в каждом `.pyc` (тысячи файлов в `.dmg`).
   Движок внутри .app дополнительно выключает запись байткода (`engine/mostik_engine/__init__.py`).
4. Подписывает ad-hoc каждый вложенный `.so`, `.dylib` и `python3.14`. Developer ID и hardened
   runtime — зона `scripts/release.sh`.
5. Проверяет, что встроенный Python импортирует движок в изолированном окружении
   (`env -i … python3 -I`).
6. Пишет SBOM `Contents/Resources/MOSTIK-VENDOR.json`: версии и суммы Python, пакетов и Sparkle
   из lock-файлов, коммит Mostik с отметкой `dirty` и коммит transcriber, с которого снята копия
   (`engine/vendor_transcriber/SOURCE.md`). Путей машины в нём нет.
7. Снимает отладочную карту с бинарника (`strip -S`). Затем `scripts/check-leaks.sh` ищет домашнюю
   папку сборщика байтовым `grep -rqa` по всему `Contents`: бинарник, `Info.plist`, ресурсы, `.pyc`,
   фреймворки. Находка или ошибка чтения — ошибка сборки. Прежняя проверка (`grep -l … | head -5`)
   под `pipefail` молчала: `grep` получал SIGPIPE, и ветка ошибки не выполнялась.

Переменные сборки:

| Переменная | Что делает |
|---|---|
| `MOSTIK_DIST` | папка, куда кладётся .app (по умолчанию `dist/`) |
| `MOSTIK_NO_PYTHON=1` | собрать без встроенного Python (быстрая dev-сборка) |
| `MOSTIK_VENDOR_PYTHON` | другой путь к подготовленному Python вместо `vendor/python` |

## Цепочка поставки

Что закреплено в git и чем сверяется :

| Что | Где сумма | Кто сверяет |
|---|---|---|
| архив python-build-standalone | `scripts/vendor.lock`, полная SHA256 | `extract`; `verify` в `release.sh` |
| распакованный `vendor/python` | архив из `vendor/python-download/` | `verify`: каждый файл архива на месте и байт в байт, лишних файлов вне пакетов нет |
| 29 пакетов | `scripts/requirements.lock`: версия и SHA256 файла `RECORD` | `site` и `verify`: каждый файл — со строкой `RECORD`, подложенный `.pth` — ошибка |
| архив Sparkle | `scripts/vendor.lock`, полная SHA256 | `verify`; `vendor/sparkle/<версия>` сверяется с архивом файл за файлом |
| `fluidaudiocli` (разделение встреч по голосам), его LICENSE и NOTICE.md | `scripts/vendor.lock`, полная SHA256 до подписи | `verify` и `fluidaudio` — `vendor/fluidaudio`; `bundle.sh` — перед копированием; `sign-app.sh` — файл в бандле перед переподписью |
| код Mostik, включая копию transcriber | коммит | `release.sh`: грязное дерево — остановка; коммит Mostik и исходный коммит transcriber — в SBOM |

`release.sh` начинает с `python3 -I scripts/vendor_python.py verify` (около минуты) и проверки
`git-state` репозитория. В `--adhoc` грязное дерево разрешает только `MOSTIK_ALLOW_DIRTY=1`,
и SBOM помечает его `"dirty": true`; в режиме Developer ID — только остановка.

**fluidaudiocli.** Готовый бинарник взят из соседнего transcriber без скачивания: его локальная
копия `skills/transcriber/bin/macos-arm64/fluidaudiocli` (в git transcriber бинарника нет, он там
в `.gitignore`), сумма совпала с закоммиченными `fluidaudiocli.sha256` и `NOTICE.md` коммита
`fed357c`. Собран CI transcriber-skill из FluidAudio `5c19d5e`, лицензия Apache-2.0. Источник и
коммит — `scripts/vendor.lock` (`fluidaudio.taken_from`), в SBOM — `fluidaudio`. Лежит в
`vendor/fluidaudio/` (в `.gitignore`) вместе с `.sha256`, `.url`, `LICENSE` и `NOTICE.md`. Скрипты его
не качают. Без файла `vendor_python.py fluidaudio` останавливается и называет адрес выпуска
(`fluidaudio.source`), откуда его взять, — сумма всё равно сверяется со `scripts/vendor.lock`;
`bundle.sh` собирает приложение без разделения встреч по голосам.
В бандле — `Contents/Resources/engine/bin/macos-arm64/fluidaudiocli` с `fluidaudiocli.sha256`:
там его ищет копия transcriber (`catalog.fluidaudio_binary_path`) и сверяет сумму
(`bundled_binary_problem`). Лицензия — `Contents/Resources/engine/third-party/fluidaudio/`.

Подпись. Бинарник подписан ad-hoc. Для Developer ID его всё равно нужно переподписать: нотаризация
требует своей подписи, hardened runtime и метки времени у каждого исполняемого файла. Переподпись
меняет байты, и сумма из `vendor.lock` в бандле перестала бы сходиться. Поэтому `sign-app.sh`
в обоих режимах: (1) сверяет файл в бандле с суммой до подписи из `vendor.lock` и при расхождении
останавливается, ничего не подписав; (2) подписывает его без entitlements движка; (3) пишет в
`fluidaudiocli.sha256` сумму уже подписанного файла. Её закрепляет печать ресурсов `.app`: правка
бинарника или `.sha256` ломает `codesign --verify --deep --strict`. `bundle.sh` (сборка в `dist/`)
бинарник не переподписывает: там в бандле исходные байты и исходная сумма.

**Чего нет и почему.**

- В `requirements.lock` нет `--hash` колёс для `pip --require-hashes`. Хэш колеса — это сумма
  скачанного `.whl`, а пакеты ставились в venv раньше, и без сети колёс не получить: в кэше pip
  нет колёс cp314 для `numpy`, `onnxruntime`, `mlx` и `regex`. Вместо этого закреплена сумма
  `RECORD`, а через неё каждый файл. Это ловит подмену файлов после установки, но не говорит,
  что колесо было подлинным с PyPI. Следующий шаг с сетью: `pip download --no-deps` нужных
  версий, `pip hash`, затем `--require-hashes` в CI.
- Подлинность архивов (что это сборка astral-sh и sparkle-project, а не подмена до первой
  загрузки) офлайн не проверяется. Ручной шаг при обновлении `scripts/vendor.lock`, нужна сеть:
  `gh attestation verify <архив> -R astral-sh/python-build-standalone` — если релиз публикует
  аттестации; для Sparkle — сверить сумму со страницей релиза на GitHub из двух разных сетей.
  `gh attestation verify --bundle … --custom-trusted-root …` работает без сети, только если оба
  файла уже скачаны; у нас их нет.
- `Sparkle.framework` из релиза подписан ad-hoc, своей подписи разработчика у него нет: целостность
  держится на сумме архива.

Обновить пакет: поставить новую версию в venv, `python3 scripts/vendor_python.py lock`, посмотреть
дифф `scripts/requirements.lock` и закоммитить его отдельно, затем пересобрать `vendor/python`
(`extract` в пустую папку и `site`).

## Где приложение ищет движок и Python

Порядок один для Swift (`MostikCore/EnginePaths.swift`) и `bin/mostik`:

1. Встроенное в .app: `Contents/Resources/engine` и `Contents/Resources/python/bin/python3`.
2. `MOSTIK_ENGINE_DIR` и `MOSTIK_PYTHON` — для разработки.
3. Репозиторий: `engine/` и `vendor/python/bin/python3`. Только в dev-сборке: в релизе
   `EngineLocator.devRepoRoot()` возвращает `nil`.

Python, выбранный вручную в Настройках, главнее всего. Старое умолчание из прежних версий
(venv transcriber) при чтении настроек сбрасывается на автопоиск. Тест `EnginePathsTests` проверяет
этот порядок. Он же следит, чтобы в `Sources/` не было абсолютных путей и `#filePath` вне тестов.

## Модели

Движок сам ничего не качает. Загрузка идёт только по кнопке: «Нужны модели» над вкладками
при первом запуске или Настройки → Модели.

Манифест — `engine/mostik_engine/models_manifest.json`: ключ, репозиторий и закреплённая ревизия
на Hugging Face, назначение, обязательность, файлы с размером, SHA256 и `blob_id`. Собирается
скриптом `scripts/models_manifest.py` из проверенного локального кэша, в сеть не ходит.

| Ключ | Назначение | Обязательна | Размер |
|---|---|---|---|
| `silero-vad` | поиск речи | да | 2 МБ |
| `gigaam-v3` | русская диктовка | да | 0,9 ГБ |
| `whisper-turbo` | английская диктовка | да | 1,6 ГБ |
| `parakeet-v3` | проверка английской диктовки | нет | 2,6 ГБ |
| `gemma-4-e2b` | локальное причёсывание | нет | 3,6 ГБ |

Загрузка (`engine/mostik_engine/model_store.py`):

- файл качается в `.part` рядом с кэшем и докачивается через `Range`;
- сумма SHA256 сверяется до переноса на место;
- до начала проверяется свободное место (размер плюс 512 МБ запаса);
- раскладка — как у `huggingface_hub`: `blobs/`, `snapshots/<rev>/`, `refs/main`. Пишется и список
  коммита `trees/<rev>.json`, без него загрузчик в офлайне идёт в сеть;
- ошибки с понятным текстом: `models_network`, `models_http`, `models_checksum`,
  `models_disk_full`, `models_cancelled`.

Модель, уже лежащая в кэше (`HF_HUB_CACHE` или `~/.cache/huggingface/hub`), считается
установленной и не качается. `MOSTIK_MODELS_BASE_URL` подменяет `https://huggingface.co`, а
`MOSTIK_MODELS_MANIFEST` подменяет сам манифест. Обе переменные нужны для тестов на локальном
HTTP-сервере (`engine/tests/test_model_store.py`).

## Проверка «чистой машины»

Сборка `MOSTIK_DIST=/tmp/mostik-clean scripts/bundle.sh` запускалась с выключенным доступом к
проекту transcriber и к репозиторию: `sandbox-exec` запрещал их чтение. Окружение было пустым:
`env -i HOME=/tmp/cleanhome`. Движок запускался из `Contents/Resources`, кэш моделей был
подключён через `HF_HUB_CACHE`.

| Шаг | Результат |
|---|---|
| `hello` | 0,5 с, Python 3.14.7, все модели видны в кэше |
| прогрев RU (VAD + GigaAM) | 4 с |
| прогрев EN (VAD + Whisper turbo, проверка Parakeet) | 16 с |
| LLM Gemma 4 E2B через `mlx_lm` из бандла | загрузка 39 с, ответ получен |
| `codesign --verify --deep --strict` после запуска движка | проходит, новых `__pycache__` нет |
| пустой кэш, без сети | `hello` отвечает, прогрев — понятная ошибка «модель не установлена», загрузка — `models_network` |
| пустой кэш, модели с локального `http.server` | VAD и GigaAM скачались, сумма сошлась, прогрев RU прошёл |

Пример: `scripts/release.sh --adhoc` → `Mostik-0.1.0-local-only.dmg`, 177 МБ.
Приложение скопировано из `.dmg` в `/tmp`; `sandbox-exec` запрещал чтение папки с исходниками, включая
transcriber и сам репозиторий; `env -i HOME=<пустая папка>`. Движок запускался так же, как его
запускает приложение: `python3 -I -u -c <загрузчик> <engine> mostik_engine`.

| Шаг | Результат |
|---|---|
| `hello` | ответ за 6 с с запуском процесса, Python 3.14.7, модели видны в кэше |
| встреча `meeting` на WAV из `say -v Milena` (6 с, без диаризации) | `transcribe.py` из `engine/vendor_transcriber` встроенным Python, 63 с, текст расшифрован дословно |
| `codesign --verify --deep --strict` после запуска | проходит, новых `.pyc` нет |
| `grep -r "$HOME/"` по `Contents` копии | пусто |
| `SURequireSignedFeed`, SBOM `MOSTIK-VENDOR.json` | `true`; коммиты Mostik и transcriber, суммы Python, 29 пакетов, Sparkle |

## Ограничения

- Для подготовки `vendor/python` нужен venv с пакетами из `scripts/requirements.lock`: оттуда
  копируются пакеты (`vendor_python.py site`). Соседний проект transcriber не нужен: его код — в
  `engine/vendor_transcriber`, `fluidaudiocli` кладётся в `vendor/fluidaudio` по адресу из `scripts/vendor.lock`.
  На машине пользователя они не нужны.
- Только Apple Silicon (`aarch64`): `mlx` под Intel нет.
- Не встроен `ffmpeg`, и для своих записей он не нужен: WAV встречи transcriber читает встроенным
  Python (`audio.native_wav`). `ffmpeg` нужен только файлу другого формата, без него — сообщение
  «сохраните как WAV или установите ffmpeg». `fluidaudiocli` встроен (см. «Цепочка поставки»).
- Движок из `.app` берёт `PATH` только системный плюс `Contents/Resources/bin`, `HF_HOME` —
  `~/.cache/huggingface`, а `TRANSCRIBER_*`, `HF_*`, `MOSTIK_CURATED_GLOSSARY` и `XDG_CACHE_HOME` из
  окружения не читает (`privacy.scrub_dev_overrides`, приложение — `EngineEnvironment.apply`).
  Поэтому `fluidaudiocli` в выпуске ищется только внутри бандла
  (`Resources/engine/bin/macos-arm64/fluidaudiocli` с суммой рядом), и он там есть; модели
  FluidAudio — в `~/Library/Application Support/FluidAudio`, без них встреча идёт одним
  собеседником. `ffmpeg` и `ffprobe` (только для не-WAV) —
  только из `/opt/homebrew/bin` или `/usr/local/bin`, и перед прогоном движок проверяет владельца и
  права файла и папки (`meeting.check_media_tools`). В debug-сборке и из репозитория переменные
  действуют, как прежде.
- Подпись вложенного кода — ad-hoc. Для нотаризации `release.sh` переподписывает бандл
  Developer ID с hardened runtime; для Python может понадобиться entitlement
  `com.apple.security.cs.disable-library-validation`. Ещё не проверено: нет сертификата.
