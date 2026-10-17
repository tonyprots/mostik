# Копия кода transcriber в Mostik

Движок Mostik использует пакет `audio_transcription` и CLI `transcribe.py` из проекта transcriber
того же автора. Это копия в репозитории, а не ссылка на соседнее рабочее дерево: выпуск собирается
только из закоммиченного кода Mostik.

- Источник: репозиторий transcriber, папка `skills/transcriber/scripts/`.
- Коммит: fed357c5b2860cb9d736dbf59bc94d8491a8decb («Правила сводки и протокола по расшифровке»).
  Взято из коммита (`git show <коммит>:<путь>`), а не из рабочего дерева.
- Лицензия: MIT, © 2026 Anton Protsenko — `LICENSE` рядом, без изменений.
- Правки в копии: в комментариях убраны даты, замеры на личных записях и примеры из личного
  словаря; код изменён только там, где перечислено в «Правки Mostik» ниже, остальное байт в байт как в коммите.

## Что взято

`transcribe.py` и 28 из 29 модулей `audio_transcription/`. Состав — замыкание импортов: всё, что
импортируют `engine/mostik_engine` и `transcribe.py`, плюс модули, которые `isolated.py` запускает
дочерними процессами (`worker`, `diarization_worker`), и их импорты, включая ленивые внутри функций.
Не взят `mirror.py`: его импортирует только `fetch_media.py`, а он движку не нужен. Не взяты и
остальные скрипты (`doctor.py`, `prefetch_models.py`, `setup_fluidaudio_models.py` и другие).

Полноту копии проверяет `engine/tests/test_vendor_transcriber.py`: каждый импорт
`audio_transcription.*` из движка и из самой копии должен находиться в ней.

## Правки Mostik

- `audio_transcription/audio.py`: PCM-WAV читается без
  `ffmpeg` — `native_wav`, `_probe_wav`, `_prepare_wav`, `resample_to_16k`; `probe_media` и
  `prepare_audio` идут в `ffmpeg` только для других форматов, текст `require_media_tools` объясняет,
  что делать. Тесты — `engine/tests/test_native_wav.py`. При обновлении копии из transcriber правку
  перенести заново (или сначала внести её в сам transcriber).

## Как обновить

1. В transcriber закоммитить нужное.
2. Для каждого файла копии: `git -C ../transcriber show <коммит>:skills/transcriber/scripts/<файл>
   > engine/vendor_transcriber/<файл>`; новые модули — по замыканию импортов (тест подскажет).
3. Поправить коммит здесь, повторить чистку комментариев, прогнать тесты движка, закоммитить отдельным коммитом.

## fluidaudiocli

Бинарник разделения по голосам взят из того же transcriber, но не в эту папку (её копия — только код):
локальная копия `skills/transcriber/bin/macos-arm64/fluidaudiocli` (в git transcriber бинарника нет,
он в `.gitignore`), сумма совпала с `fluidaudiocli.sha256` и `third-party/fluidaudio/NOTICE.md`
коммита fed357c5b2860cb9d736dbf59bc94d8491a8decb. Лежит в `vendor/fluidaudio/` Mostik, сумма — в
`scripts/vendor.lock` (`fluidaudio`, там же источник). В `.app` — `Contents/Resources/engine/bin/macos-arm64/`:
`catalog.fluidaudio_binary_path` копии ищет его в `<engine>/bin/macos-arm64`, потому что папка
`scripts/` transcriber здесь — `vendor_transcriber/`.

Где копия лежит в `.app`: `Contents/Resources/engine/vendor_transcriber/`. Встречи запускают
`transcribe.py` оттуда же, встроенным Python приложения.
