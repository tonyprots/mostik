# mostik-engine

Python-движок Mostik: потоковая диктовка поверх моделей transcriber. Приложение
говорит с ним строками JSON через stdin/stdout (устройство — `docs/architecture.md`,
вход протокола — `server.py`, функции `cmd_<команда>`). Логи — только в stderr.

## Запуск

```sh
cd engine
.venv/bin/python -m mostik_engine   # venv разработки, см. «Сборка из исходников» в README
# или встроенный Python выпуска: ../vendor/python/bin/python3 -m mostik_engine (scripts/vendor_python.py)
```

Переменные окружения:

- `MOSTIK_HOME` — дом данных, по умолчанию `~/Library/Application Support/Mostik`
  (`glossary.yaml`, `projects/<sha1>.json`);
- `MOSTIK_TRANSCRIBER` — только для разработки: другой каталог с пакетом
  `audio_transcription` вместо копии `vendor_transcriber/`;
- `HF_HUB_CACHE` / `HF_HOME` — кэш моделей Hugging Face;
- `MOSTIK_MODELS_BASE_URL` — сервер моделей для загрузки по кнопке (по умолчанию huggingface.co);
- `MOSTIK_IMPORT_TRANSCRIBER=0` — не забирать словари transcriber при первом запуске.

Модели только из кэша Hugging Face, без сети: GigaAM v3 E2E (ru), Parakeet TDT v3
(en), Silero VAD, Whisper Turbo MLX (проверяющая, отдельный процесс). Недостающее
качается только командой `models_download` по кнопке в приложении (`model_store.py`,
манифест `models_manifest.json` с размерами и SHA256, докачка через Range).

## Модули

| Файл | Что делает |
|---|---|
| `server.py` | цикл протокола, рабочая очередь с приоритетом, полоса встреч, уборка простоя |
| `session.py` | сессия: буфер PCM, VAD по хвосту, окна, `final` |
| `models.py` | пул моделей, загрузка один раз, выгрузка через 10 мин простоя |
| `verifier_worker.py` | процесс Whisper Turbo MLX и клиент к нему, выгрузка через 3 мин |
| `doubts.py` | сомнения: фильтр терминов, ранжирование, top-N, правки по канону |
| `project_glossary.py` | словарь проекта из репозитория с кэшем по mtime |
| `personal_glossary.py` | личный словарь, `remember` / `forget` / список, импорт из transcriber |
| `power.py` | когда выключать проверяющую |
| `meeting.py` | расшифровка встречи через CLI transcriber |

Полный список модулей по группам — `docs/architecture.md`, раздел 3.

Команды словаря: `glossary_list` → `{entries: [{canonical, aliases, source}]}`,
`forget {canonical}`. В `partial` поле `text` — весь текст на сейчас, `window_text` —
текст нового окна. В `final` есть служебные `stats` и `timings.vad_ms`.

## Тесты и стенд

```sh
.venv/bin/python -m pytest tests -q          # всё, включая процесс движка (~5 мин)
.venv/bin/python -m pytest tests -q -m "not slow"  # без настоящих моделей, секунды
.venv/bin/python bench/run_bench.py --batch 0:5   # свои записи пачками, итог в bench/out/
.venv/bin/python bench/run_bench.py --report      # сводка в bench/out/report.md
```
