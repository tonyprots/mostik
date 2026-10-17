#!/bin/bash
# Сквозной тест без интерфейса: две свои записи через `Mostik --simulate`.
# Папка со своими WAV (16 кГц моно, от 5 с) — E2E_RECORDINGS, обязательно: записей в репозитории нет.
# Текст расшифровки не печатается и не пишется в файлы — только длины и тайминги.
# E2E_STREAM=1 — ещё и потоковый путь приложения (start/audio/stop).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REC_DIR="${E2E_RECORDINGS:-}"
if [ -z "$REC_DIR" ] || [ ! -d "$REC_DIR" ]; then
  echo "e2e: укажите папку со своими записями: E2E_RECORDINGS=<папка с WAV 16 кГц моно, от 5 с> scripts/e2e.sh" >&2
  echo "     нужны две записи; перевести запись в такой формат можно, например, так: ffmpeg -i in.m4a -ar 16000 -ac 1 out.wav" >&2
  exit 2
fi
BIN="${MOSTIK_BIN:-}"
if [ -z "$BIN" ]; then
  "$ROOT/scripts/swift.sh" build --scratch-path "${SCRATCH:-.build-platform}" --product Mostik >/dev/null
  BIN="$("$ROOT/scripts/swift.sh" build --scratch-path "${SCRATCH:-.build-platform}" --show-bin-path)/Mostik"
fi

# Две самые короткие записи от 5 с (16 кГц моно int16 = 32 000 байт/с): совсем короткие бывают тишиной.
FILES=()
while IFS= read -r f; do FILES+=("$f"); done < <(
  find "$REC_DIR" -name '*.wav' -size +160k -print0 | xargs -0 ls -S | tail -n 2)
[ "${#FILES[@]}" -eq 2 ] || { echo "FAIL: в $REC_DIR нужны две записи *.wav длиннее 5 с" >&2; exit 1; }

MODES=("file"); [ "${E2E_STREAM:-0}" = "1" ] && MODES+=("stream")
fail=0
for mode in "${MODES[@]}"; do
for f in "${FILES[@]}"; do
  extra=(); [ "$mode" = "stream" ] && extra=(--stream)
  start=$(date +%s)
  rc=0
  out="$("$BIN" --simulate "$f" --print ${extra[@]+"${extra[@]}"} 2>/tmp/mostik-e2e-stderr.$$)" || rc=$?
  if [ -z "$out" ]; then
    echo "FAIL [$mode] $(basename "$f"): exit $rc ($(tail -n 1 /tmp/mostik-e2e-stderr.$$))"
    fail=1; continue
  fi
  wall=$(( $(date +%s) - start ))
  json="$(printf '%s\n' "$out" | head -n 1)"
  stats="$(printf '%s' "$json" | /usr/bin/python3 -c '
import json, sys
r = json.load(sys.stdin)
t = r.get("timings", {})
print(len(r.get("text", "").strip()), len(r.get("doubts", [])), t.get("audio_s", 0), t.get("total_ms", 0), r.get("verifier", ""))
')"
  read -r chars doubts audio total verifier <<<"$stats"
  composed_len=$(printf '%s\n' "$out" | sed '1,2d' | LC_ALL=en_US.UTF-8 wc -m | tr -d ' ')
  if [ "$chars" -gt 0 ]; then
    echo "OK   [$mode] $(basename "$f"): chars=$chars composed_chars=$composed_len doubts=$doubts audio_s=$audio total_ms=$total verifier=$verifier wall_s=$wall"
  else
    echo "FAIL [$mode] $(basename "$f"): пустой текст (audio_s=$audio wall_s=$wall)"
    fail=1
  fi
done
done
rm -f /tmp/mostik-e2e-stderr.$$
exit $fail
