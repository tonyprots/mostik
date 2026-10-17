#!/bin/bash
# Копия папки из git — только отслеживаемые файлы (Р2, низкие): игнорируемое и неотслеживаемое
# рабочего дерева (.env, черновики, кэши) в бандл не едет. Содержимое — из рабочего дерева;
# release.sh отдельно требует чистое дерево.
#   scripts/copy-tracked.sh <папка в репозитории> <куда> [исключить-подпапку]...
set -euo pipefail
SRC="${1:?usage: copy-tracked.sh <папка> <куда> [исключить]...}"
DST="${2:?usage: copy-tracked.sh <папка> <куда> [исключить]...}"
shift 2
pathspec=(.)
for skip in "$@"; do pathspec+=(":(exclude)$skip"); done
rm -rf "$DST"
mkdir -p "$DST"
# Список файлов — в отдельный файл, а не в pipe: под pipefail сбой git не должен дать пустую копию.
list="$(mktemp "${TMPDIR:-/tmp}/mostik-tracked.XXXXXX")"
trap 'rm -f "$list"' EXIT
git -C "$SRC" ls-files -z -- "${pathspec[@]}" > "$list"
[ -s "$list" ] || { echo "copy-tracked: в $SRC нет отслеживаемых файлов" >&2; exit 1; }
tar -C "$SRC" --null -T "$list" -cf - | tar -C "$DST" -xf -
