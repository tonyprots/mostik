#!/bin/bash
# Строки, которых не должно быть в публичном репозитории и в сборке: названия внутренних систем,
# адреса, имена переменных с ключами. Сам список в репозиторий не кладётся — он и был бы утечкой:
#   MOSTIK_DENYLIST          строки через перевод строки (секрет CI);
#   MOSTIK_DENYLIST_FILE     файл со строками; по умолчанию .git/info/denylist — git его не публикует.
# В файле строка = подстрока без учёта регистра; пустые и начатые с # пропускаются.
#
#   scripts/check-denylist.sh [--tracked]       файлы и имена файлов в git (по умолчанию)
#   scripts/check-denylist.sh --staged          то, что уходит в коммит (хук .githooks/pre-commit)
#   scripts/check-denylist.sh --history         вся история: изменения и сообщения всех коммитов
#   scripts/check-denylist.sh --app <Mostik.app>  собранное приложение, байтовым поиском
#   --allow-missing   нет списка — предупредить и выйти с 0 (CI без секрета, сборка у внешнего участника)
#
# Печатает только где нашлось (файл:строка, коммит) — ни строку из списка, ни найденный текст:
# логи CI публичного репозитория видны всем. Находка — код 1, нет списка или ошибка — код 2.
set -euo pipefail

mode=tracked
app=""
allow_missing=0
while [ $# -gt 0 ]; do
  case "$1" in
    --tracked|--staged|--history) mode="${1#--}" ;;
    --app) mode=app; app="${2:?check-denylist: --app <Mostik.app>}"; shift ;;
    --allow-missing) allow_missing=1 ;;
    *) echo "check-denylist: неизвестный аргумент $1" >&2; exit 2 ;;
  esac
  shift
done

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
work="$(mktemp -d "${TMPDIR:-/tmp}/mostik-denylist.XXXXXX")"
trap 'rm -rf "$work"' EXIT

missing() {
  if [ "$allow_missing" -eq 1 ]; then
    echo "check-denylist: $1 — проверка пропущена (--allow-missing)" >&2
    [ -n "${GITHUB_ACTIONS:-}" ] && echo "::warning::check-denylist: $1, проверка пропущена"
    exit 0
  fi
  echo "check-denylist: $1. Положите строки в .git/info/denylist или задайте MOSTIK_DENYLIST." >&2
  exit 2
}

if [ -n "${MOSTIK_DENYLIST:-}" ]; then
  printf '%s\n' "$MOSTIK_DENYLIST" > "$work/raw"
else
  list="${MOSTIK_DENYLIST_FILE:-$(git rev-parse --git-path info/denylist)}"
  [ -f "$list" ] || missing "нет списка $list"
  cp "$list" "$work/raw"
fi
# Пробелы по краям срезаем: строка « x» из секрета не должна молча превратиться в другую.
sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^#/d' -e '/^$/d' "$work/raw" > "$work/patterns"
[ -s "$work/patterns" ] || missing "список пуст"
count="$(wc -l < "$work/patterns" | tr -d ' ')"

found() {
  echo "check-denylist: найдены запрещённые строки ($1):" >&2
  sed -n '1,50p' "$work/hits" >&2
  total="$(wc -l < "$work/hits" | tr -d ' ')"
  [ "$total" -le 50 ] || echo "  … и ещё $((total - 50))" >&2
  exit 1
}

# git grep: 0 — нашлось, 1 — нет, остальное — ошибка; проверка не может молча пройти.
run_grep() {
  local rc=0
  "$@" > "$work/out" || rc=$?
  case $rc in
    0|1) ;;
    *) echo "check-denylist: поиск упал (код $rc)" >&2; exit 2 ;;
  esac
}

case "$mode" in
  tracked|staged)
    cached=()
    [ "$mode" = staged ] && cached=(--cached)
    # -I: двоичные файлы git grep пропускает, их ловит --app по собранному приложению.
    run_grep git grep ${cached[@]+"${cached[@]}"} -n -I -i -F -f "$work/patterns" --
    cut -d: -f1,2 "$work/out" > "$work/hits"
    if [ "$mode" = staged ]; then
      git diff --cached --name-only --diff-filter=ACMR > "$work/names"
    else
      git ls-files > "$work/names"
    fi
    grep -i -F -f "$work/patterns" "$work/names" | sed 's/$/ (имя файла)/' >> "$work/hits" || true
    [ -s "$work/hits" ] && found "$mode"
    ;;
  history)
    # Каждая строка истории — изменение или сообщение коммита; печатаем только хеши коммитов.
    git log --all -p --no-color --no-ext-diff --format='@@MOSTIK-COMMIT %h%n%B' > "$work/log"
    awk -v pats="$work/patterns" '
      BEGIN { while ((getline p < pats) > 0) list[++n] = tolower(p) }
      /^@@MOSTIK-COMMIT / { commit = $2; next }
      {
        line = tolower($0)
        for (i = 1; i <= n; i++) if (index(line, list[i])) { if (!(commit in seen)) { seen[commit] = 1; print commit } break }
      }
    ' "$work/log" > "$work/hits"
    [ -s "$work/hits" ] && found "история, коммиты"
    ;;
  app)
    [ -d "$app/Contents" ] || { echo "check-denylist: нет $app/Contents" >&2; exit 2; }
    # Без ripgrep: сотни мегабайт байтовым поиском. В UTF-8 grep -i сравнивает по символам и идёт минуты; в C-локали —
    # секунды, но только пока в списке нет не-ASCII: кириллица с -i снова включает медленный путь (замер:
    # 620 МБ — 5,5 мин против 15 с). Поэтому два прохода: латиница с -i, кириллица — явными вариантами
    # регистра без -i (как в списке, строчные, ПРОПИСНЫЕ, С заглавной; разнобой вроде «пРиМер» не ловится).
    LC_ALL=C grep -v '[^ -~]' "$work/patterns" > "$work/ascii" || true
    LC_ALL=C grep '[^ -~]' "$work/patterns" | python3 -I -c 'import sys
seen = set()
for w in (l.strip() for l in sys.stdin):
    for v in (w, w.lower(), w.upper(), w.capitalize()):
        if v and v not in seen:
            seen.add(v); print(v)' > "$work/other" || true
    : > "$work/hits"
    rc=1
    # ripgrep сравнивает регистр по Unicode и проходит 620 МБ меньше чем за секунду; системный grep на
    # macOS (BSD) — минуты даже в C-локали. Его двухпроходная схема ниже — запасной путь, не основной.
    if command -v rg > /dev/null; then
      rc=0
      rg --no-config --no-ignore --hidden -a -l -i -F -f "$work/patterns" "$app/Contents" > "$work/hits" || rc=$?
      set -- skip
    else
      set -- ascii other
    fi
    for pass in "$@"; do
      [ "$pass" = skip ] && break
      [ -s "$work/$pass" ] || continue
      flags=(-r -l -a -F)
      [ "$pass" = ascii ] && flags+=(-i)
      prc=0
      LC_ALL=C grep "${flags[@]}" -f "$work/$pass" "$app/Contents" >> "$work/hits" || prc=$?
      case $prc in
        0) rc=0 ;;
        1) ;;
        *) rc=$prc; break ;;
      esac
    done
    sort -u -o "$work/hits" "$work/hits"
    case $rc in
      0) found "сборка" ;;
      1) ;;
      *) echo "check-denylist: grep не смог прочитать $app (код $rc)" >&2; exit 2 ;;
    esac
    ;;
esac
echo "check-denylist: чисто ($mode, строк в списке: $count)"
