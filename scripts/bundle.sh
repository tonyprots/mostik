#!/bin/bash
# Сборка dist/Mostik.app: release-бинарник, движок, Info.plist, иконка, ad-hoc-подпись.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# MOSTIK_DIST — другая папка вывода (проверки агентов, не трогая запущенную сборку).
# Путь без символических ссылок (pwd -P): движок узнаёт себя по resolve(), и с MOSTIK_DIST=/tmp/…
# проверка импорта ниже сравнивала /private/tmp/… с /tmp/… и падала.
DIST="${MOSTIK_DIST:-$ROOT/dist}"
mkdir -p "$DIST"
DIST="$(cd "$DIST" && pwd -P)"
APP="$DIST/Mostik.app"
echo "bundle.sh: сборка в $APP"

"$ROOT/scripts/swift.sh" build -c release --scratch-path .build-release --product Mostik
BIN="$("$ROOT/scripts/swift.sh" build -c release --scratch-path .build-release --show-bin-path)/Mostik"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Mostik"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# Google Календарь (docs/calendars.md): OAuth-клиент «Desktop app» — из окружения сборки, в репозитории его нет.
# Без MOSTIK_GOOGLE_CLIENT_ID строка Google в Настройках пишет «Недоступно в этой сборке».
if [ -n "${MOSTIK_GOOGLE_CLIENT_ID:-}" ]; then
  /usr/libexec/PlistBuddy -c "Add :MostikGoogleClientID string $MOSTIK_GOOGLE_CLIENT_ID" "$APP/Contents/Info.plist"
  if [ -n "${MOSTIK_GOOGLE_CLIENT_SECRET:-}" ]; then
    /usr/libexec/PlistBuddy -c "Add :MostikGoogleClientSecret string $MOSTIK_GOOGLE_CLIENT_SECRET" "$APP/Contents/Info.plist"
  fi
fi
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# CLI для агентов (G1) и файлы скилла и хука (G4): обёртка находит движок как ../engine.
mkdir -p "$APP/Contents/Resources/bin"
cp "$ROOT/bin/mostik" "$APP/Contents/Resources/bin/mostik"
chmod +x "$APP/Contents/Resources/bin/mostik"
rsync -a --delete --exclude '.DS_Store' "$ROOT/integrations/" "$APP/Contents/Resources/integrations/"

# Движок без тестов и стенда, только отслеживаемые git файлы (Р2, низкие): игнорируемое рабочего
# дерева не едет. С ним — копия кода transcriber, engine/vendor_transcriber (П10 С11): соседний
# проект при сборке не читается.
bash "$ROOT/scripts/copy-tracked.sh" "$ROOT/engine" "$APP/Contents/Resources/engine" tests bench

# Разделение встреч по голосам: готовый fluidaudiocli из vendor/fluidaudio (взят из transcriber, не
# скачивается; сумма — scripts/vendor.lock). Кладётся туда, где его ищет копия transcriber
# (catalog.fluidaudio_binary_path: <engine>/bin/macos-arm64), с .sha256 для bundled_binary_problem;
# LICENSE и NOTICE.md (Apache-2.0) — в <engine>/third-party/fluidaudio. Не в Contents/Resources/bin:
# оттуда, из PATH выпуска, бинарник нашёлся бы без сверки суммы. Нет vendor/fluidaudio — сборка без
# разделения (встречи одним собеседником); есть, но не сходится с vendor.lock — ошибка.
FA_SRC="$ROOT/vendor/fluidaudio"
FA_BUNDLED=0
if [ -f "$FA_SRC/fluidaudiocli" ]; then
  python3 -I "$ROOT/scripts/vendor_python.py" fluidaudio \
    || { echo "bundle.sh: vendor/fluidaudio не совпал с scripts/vendor.lock" >&2; exit 1; }
  FA_DST="$APP/Contents/Resources/engine/bin/macos-arm64"
  mkdir -p "$FA_DST" "$APP/Contents/Resources/engine/third-party/fluidaudio"
  cp "$FA_SRC/fluidaudiocli" "$FA_SRC/fluidaudiocli.sha256" "$FA_DST/"
  chmod 755 "$FA_DST/fluidaudiocli"
  cp "$FA_SRC/LICENSE" "$FA_SRC/NOTICE.md" "$APP/Contents/Resources/engine/third-party/fluidaudio/"
  FA_BUNDLED=1
else
  echo "bundle.sh: нет vendor/fluidaudio/fluidaudiocli — сборка без разделения встреч по голосам" >&2
fi

# Встроенный Python (П8, пункт 2): vendor/python — python-build-standalone со своим
# site-packages (scripts/vendor_python.py, пакеты — scripts/vendor-packages.txt). Без него
# приложение на чистой машине не запустит движок, поэтому это ошибка, а не предупреждение;
# MOSTIK_NO_PYTHON=1 — сборка без Python (снимки UI, CI без vendor/).
RES="$APP/Contents/Resources"
PY_SRC="${MOSTIK_VENDOR_PYTHON:-$ROOT/vendor/python}"
if [ "${MOSTIK_NO_PYTHON:-0}" = "1" ]; then
  echo "bundle.sh: MOSTIK_NO_PYTHON=1 — сборка без встроенного Python" >&2
else
  if [ ! -x "$PY_SRC/bin/python3" ]; then
    echo "bundle.sh: нет встроенного Python в $PY_SRC — см. scripts/vendor_python.py и docs/packaging.md" >&2
    exit 1
  fi
  # ditto на APFS клонирует файлы. Лишнее для движка — тесты stdlib, Tk, IDLE, pip, заголовки.
  ditto "$PY_SRC" "$RES/python"
  PYLIB="$(cd "$RES/python/lib" && ls -d python3.* | head -1)"
  (
    cd "$RES/python"
    rm -rf include share lib/pkgconfig lib/itcl* lib/tcl* lib/tk* lib/thread* lib/libtcl* \
      bin/idle* bin/pip* bin/pydoc* bin/*-config MOSTIK-VENDOR.json \
      "lib/$PYLIB/test" "lib/$PYLIB/idlelib" "lib/$PYLIB/tkinter" "lib/$PYLIB/turtledemo" \
      "lib/$PYLIB/ensurepip" "lib/$PYLIB/site-packages/pip" "lib/$PYLIB/site-packages"/pip-*.dist-info
    rm -f "lib/$PYLIB/lib-dynload"/_tkinter*.so
    find . -name '__pycache__' -type d -prune -exec rm -rf {} +
    find . -name 'direct_url.json' -path '*.dist-info/*' -delete
  )
  # Байткод заранее, без путей сборщика в co_filename (П10, С5) — см. scripts/compile-bytecode.sh.
  bash "$ROOT/scripts/compile-bytecode.sh" "$RES/python/bin/python3" "$RES" \
    "$RES/python/lib" "$RES/engine" \
    || echo "bundle.sh: compileall сообщил об ошибках (файлы-образцы в пакетах) — не критично" >&2
  # Вложенный код подписываем ad-hoc по отдельности (П8, пункт 2); Developer ID — в release.sh.
  find "$RES/python" -type f \( -name '*.so' -o -name '*.dylib' \) -print0 \
    | xargs -0 codesign --force --sign - --timestamp=none
  codesign --force --sign - --timestamp=none "$RES/python/bin/$(readlink "$RES/python/bin/python3" || echo python3)"
  # Проверка: встроенный Python запускается изолированно и видит движок со своими пакетами.
  env -i HOME=/tmp "$RES/python/bin/python3" -I -c \
    "import sys; sys.path.insert(0, '$RES/engine'); import numpy, onnx_asr, mlx.core, mlx_audio, mlx_lm, yaml; from mostik_engine import paths; import audio_transcription.cli as c; assert c.__file__.startswith('$RES/engine/vendor_transcriber/'), c.__file__" \
    || { echo "bundle.sh: встроенный Python не импортирует зависимости движка" >&2; exit 1; }
  # Копия transcriber находит fluidaudiocli бандла и принимает его сумму — тем же кодом, что в прогоне.
  if [ "$FA_BUNDLED" = 1 ]; then
    env -i HOME=/tmp "$RES/python/bin/python3" -I -c \
      "import sys; sys.path.insert(0, '$RES/engine'); from mostik_engine import paths; from audio_transcription import catalog as c; p = c.fluidaudio_binary_path(); assert p is not None and str(p).startswith('$RES/engine/bin/macos-arm64/'), p; assert c.bundled_binary_problem(p) is None, c.bundled_binary_problem(p)" \
      || { echo "bundle.sh: копия transcriber не находит fluidaudiocli бандла или его сумма не сходится" >&2; exit 1; }
  fi
fi

# Приёмник хуков Claude Code для озвучки (A1): кнопка в Настройках копирует его в данные приложения.
mkdir -p "$APP/Contents/Resources/hooks"
cp "$ROOT/integrations/claude-code/hooks/mostik-notify.sh" "$APP/Contents/Resources/hooks/"
# Очередь сообщений агенту посреди хода (A6): тоже ставится только кнопкой в Настройках.
cp "$ROOT/integrations/claude-code/hooks/mostik-queue.sh" "$APP/Contents/Resources/hooks/"

# Sparkle 2 (П8-3): фреймворк из vendor/sparkle/current (не в git, см. docs/release.md) — в Contents/Frameworks.
# Приложение грузит его в рантайме; без него сборка работает, а «Проверить обновления…» объясняет, почему нельзя.
SPARKLE_FW="${MOSTIK_SPARKLE:-$ROOT/vendor/sparkle/current/Sparkle.framework}"
if [ -d "$SPARKLE_FW" ]; then
  mkdir -p "$APP/Contents/Frameworks"
  ditto "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"
else
  echo "bundle.sh: Sparkle.framework не найден ($SPARKLE_FW) — сборка без автообновления" >&2
fi

# SBOM (П10, С9, С11): из чего собран бандл — версии и суммы из scripts/vendor.lock и
# scripts/requirements.lock, коммит Mostik с отметкой dirty и коммит transcriber, с которого снята
# копия engine/vendor_transcriber (её SOURCE.md). Без путей сборщика.
# Python и Sparkle попадают в SBOM, только если взяты из закреплённого vendor/, а не из переопределения.
SBOM_ARGS=()
if [ "${MOSTIK_NO_PYTHON:-0}" != "1" ] && [ -z "${MOSTIK_VENDOR_PYTHON:-}" ]; then
  SBOM_ARGS+=(--python)
fi
[ -d "$APP/Contents/Frameworks/Sparkle.framework" ] && [ -z "${MOSTIK_SPARKLE:-}" ] && SBOM_ARGS+=(--sparkle)
[ "$FA_BUNDLED" = 1 ] && SBOM_ARGS+=(--fluidaudio)
SBOM_PY="python3"
[ -x "$PY_SRC/bin/python3" ] && SBOM_PY="$PY_SRC/bin/python3"
"$SBOM_PY" -I "$ROOT/scripts/vendor_python.py" sbom --out "$RES/MOSTIK-VENDOR.json" \
  ${SBOM_ARGS[@]+"${SBOM_ARGS[@]}"}

# В продовой сборке путей к машине, на которой собирали, быть не должно (П8, пункт 1; П10, С5):
# весь Contents — бинарник, Info.plist, ресурсы, .pyc, фреймворки — байтовым поиском.
# Отладочная карта (N_SO/N_OSO) хранит абсолютные пути к исходникам и .o — снимаем её.
strip -S "$APP/Contents/MacOS/Mostik"
bash "$ROOT/scripts/check-leaks.sh" "$APP" "$(cd ~ && pwd -P)" "$HOME"
# Запрещённые строки (scripts/check-denylist.sh): у внешнего участника списка нет — предупреждение;
# выпуск (release.sh) проверяет строго.
bash "$ROOT/scripts/check-denylist.sh" --app "$APP" --allow-missing

# Ad-hoc, без entitlements; идентификатор стабилен, чтобы TCC узнавал приложение.
# Ad-hoc подпись по умолчанию требует совпадения хэша, и macOS забывает выданные
# разрешения после каждой пересборки. Явное требование по идентификатору держит их.
# Для релиза — подпись Developer ID, там требование задаёт Apple.
codesign --force --sign - --identifier app.mostik.mac --timestamp=none \
  --requirements '=designated => identifier "app.mostik.mac"' "$APP"
codesign --verify --verbose=2 "$APP"
echo "OK: $APP"
