#!/bin/bash
# Пути машины сборщика в бандле (П8, пункт 1; П10, С5): ищет каждую строку по всему Contents —
# бинарник, Info.plist, ресурсы, байткод .pyc, фреймворки. Байтовый поиск (grep -a).
#   scripts/check-leaks.sh <Mostik.app> <путь>...       ищет «<путь>/» в <Mostik.app>/Contents
#   scripts/check-leaks.sh --tree <папка> <строка>...    ищет строку как есть по всей папке, со скрытыми
#                                                        файлами (Р2 Н5: смонтированный .dmg, его .DS_Store
#                                                        и фон); ссылки не раскрываются (Applications)
# Находка — код 1 и список до 20 файлов. Ошибка чтения — код 2: проверка не может молча пройти.
# Без `| head`: под pipefail grep получал SIGPIPE, и старая проверка не срабатывала на 5924 файлах.
set -euo pipefail
if [ "${1:-}" = "--tree" ]; then
  shift
  TREE="${1:?usage: check-leaks.sh --tree <папка> <строка>...}"
  SUFFIX=""
  [ -d "$TREE" ] || { echo "check-leaks: нет папки $TREE" >&2; exit 2; }
else
  APP="${1:?usage: check-leaks.sh <Mostik.app> <путь>...}"
  [ -d "$APP/Contents" ] || { echo "check-leaks: нет $APP/Contents" >&2; exit 2; }
  TREE="$APP/Contents"
  SUFFIX="/"
fi
shift
[ $# -gt 0 ] || { echo "check-leaks: не задан ни один путь" >&2; exit 2; }
for leak in "$@"; do
  [ -n "$leak" ] || { echo "check-leaks: пустая строка поиска" >&2; exit 2; }
  rc=0
  grep -r -q -a -F -- "$leak$SUFFIX" "$TREE" || rc=$?
  case $rc in
    0)
      echo "check-leaks: строка $leak$SUFFIX есть в $TREE — продовая сборка не должна знать машину сборщика:" >&2
      grep -r -l -a -F -- "$leak$SUFFIX" "$TREE" > "${TMPDIR:-/tmp}/mostik-leaks.$$" || true
      echo "  файлов: $(wc -l < "${TMPDIR:-/tmp}/mostik-leaks.$$" | tr -d ' ')" >&2
      sed -n '1,20p' "${TMPDIR:-/tmp}/mostik-leaks.$$" >&2
      rm -f "${TMPDIR:-/tmp}/mostik-leaks.$$"
      exit 1 ;;
    1) ;;
    *) echo "check-leaks: grep не смог прочитать $TREE (код $rc)" >&2; exit 2 ;;
  esac
done
echo "check-leaks: путей сборщика нет ($*)"
