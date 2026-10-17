#!/bin/sh
# Приёмник хуков Claude Code для озвучки Mostik (A1).
#   Stop          → mostik-notify.sh stop
#   Notification  → mostik-notify.sh notification
# Хук получает JSON на stdin. Скрипт кладёт его в папку событий Mostik одним файлом:
# первая строка — заголовок (событие, панель tmux, время), дальше — JSON хука как есть.
# Mostik не запущен или озвучка выключена (нет маркера .listening) — ничего не пишет.
# Ничего не печатает, всегда выходит с 0 и не ждёт приложение: хук не должен мешать агенту.

kind="$1"
case "$kind" in
  stop|notification) ;;
  *) cat >/dev/null 2>&1; exit 0 ;;
esac

dir="${MOSTIK_EVENTS_DIR:-$HOME/Library/Application Support/Mostik/agent-events}"
if [ ! -f "$dir/.listening" ]; then
  cat >/dev/null 2>&1
  exit 0
fi

# Панель tmux, из которой запущен агент, — чтобы озвучка назвала сессию. Только вида %12.
pane=""
case "${TMUX_PANE:-}" in
  %*[!0-9]*|%) ;;
  %[0-9]*) pane="$TMUX_PANE" ;;
esac

ts=$(date +%s)
tmp="$dir/.tmp.$$.$ts"
{
  printf '{"mostik":1,"event":"%s","tmux_pane":"%s","at":%s}\n' "$kind" "$pane" "$ts"
  head -c 262144
} > "$tmp" 2>/dev/null && mv -f "$tmp" "$dir/$ts-$$-$kind.json" 2>/dev/null
exit 0
