#!/bin/bash
# Байткод встроенного Python заранее (П8, пункт 2; П10, С5).
#   scripts/compile-bytecode.sh <python> <Contents/Resources> <папка>...
# Иначе Python при первом запуске пишет __pycache__ внутрь .app и ломает печать подписи
# (а из /Applications без прав записи компилирует на каждом старте).
# unchecked-hash — .pyc не сверяется с mtime исходника, после копирования он остаётся годным.
# -s/-p: в co_filename вместо пути сборки <Resources>/… пишется Mostik.app/Contents/Resources/…,
# иначе домашняя папка сборщика остаётся в каждом .pyc. Исходник трейсбек всё равно покажет:
# linecache берёт его через загрузчик модуля.
set -euo pipefail
PY="${1:?usage: compile-bytecode.sh <python> <Resources> <папка>...}"
RES="${2:?usage: compile-bytecode.sh <python> <Resources> <папка>...}"
shift 2
RES="$(cd "$RES" && pwd -P)"
dirs=()
for d in "$@"; do dirs+=("$(cd "$d" && pwd -P)"); done
# -B: сам Python и рабочие процессы -j 0 импортируют свою stdlib (encodings, pathlib,
# multiprocessing) и без -B пишут ей обычные .pyc с полным путём; -f перезаписывает такие,
# иначе compileall считает их свежими и пропускает (93 файла в первой сборке после правки).
"$PY" -B -I -m compileall -q -f -j 0 --invalidation-mode unchecked-hash \
  -s "$RES" -p "Mostik.app/Contents/Resources" "${dirs[@]}" >/dev/null
