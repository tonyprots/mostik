#!/bin/sh
# Очередь сообщений агенту посреди хода (Mostik, A6).
#   UserPromptSubmit → mostik-queue.sh prompt   агент занят; накопленное — в контекст запроса
#   PostToolUse      → mostik-queue.sh tool     агент ещё занят; накопленное — в контекст после инструмента
#   Stop             → mostik-queue.sh stop     есть накопленное — ход не кончается, агент его читает;
#                                               нет — агент свободен
# Сообщения кладёт приложение Mostik в queue/<session_id>/*.msg: текст уже экранирован для строки
# JSON. Без маркера .enabled (очередь выключена в Настройках) скрипт ничего не делает.
# Печатает только JSON для Claude Code, всегда выходит с 0 и не ждёт приложение.

kind="$1"
case "$kind" in
  prompt|tool|stop) ;;
  *) cat >/dev/null 2>&1; exit 0 ;;
esac

dir="${MOSTIK_QUEUE_DIR:-$HOME/Library/Application Support/Mostik/agent-queue}"
input=$(head -c 262144 2>/dev/null | tr '\n' ' ')
[ -f "$dir/.enabled" ] || exit 0

field() {
  printf '%s' "$input" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -n 1
}

sid=$(field session_id)
case "$sid" in
  ''|*[!A-Za-z0-9_-]*) exit 0 ;;
esac
cwd=$(field cwd)

busy="$dir/busy"
queue="$dir/queue/$sid"
mkdir -p "$busy" 2>/dev/null || exit 0

# Склеить сообщения по порядку имён и убрать отданные.
take() {
  out=""
  for f in "$queue"/*.msg; do
    [ -f "$f" ] || continue
    body=$(cat "$f" 2>/dev/null)
    rm -f "$f"
    [ -n "$body" ] || continue
    if [ -z "$out" ]; then out="$body"; else out="$out\\n\\n$body"; fi
  done
  printf '%s' "$out"
}

lead='Сообщение пользователя, надиктованное, пока ты работал (Mostik). Учти его в текущей задаче:\n\n'

case "$kind" in
  prompt|tool)
    printf '%s\n' "$cwd" > "$busy/$sid" 2>/dev/null
    msgs=$(take)
    if [ -n "$msgs" ]; then
      event=PostToolUse
      [ "$kind" = prompt ] && event=UserPromptSubmit
      printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s%s"}}\n' "$event" "$lead" "$msgs"
    fi
    ;;
  stop)
    msgs=$(take)
    if [ -n "$msgs" ]; then
      printf '%s\n' "$cwd" > "$busy/$sid" 2>/dev/null
      printf '{"decision":"block","reason":"%s%s"}\n' "$lead" "$msgs"
    else
      rm -f "$busy/$sid"
    fi
    ;;
esac
exit 0
