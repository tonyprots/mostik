#!/bin/bash
# swift с обходом Command Line Tools 27 (Swift 6.4) без Xcode. Аргументы те же, что у swift:
#   scripts/swift.sh build | run MostikCoreTests | run Mostik …
# В CLT 27 сборка по умолчанию (swiftbuild) падает сразу («Unknown error parsing property list»),
# а в SDK 27 @State стал макросом, плагина которого в CLT нет. Поэтому без Xcode: native-сборка и
# самый свежий SDK 26.x из CLT. С Xcode и на прежних CLT это обычный swift.
set -euo pipefail
cmd="${1:-}"
[ $# -gt 0 ] && shift

if ! xcode-select -p 2>/dev/null | grep -q '\.app/'; then
  if [ -z "${SDKROOT:-}" ]; then
    sdk="$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk 2>/dev/null | sort -V | tail -1 || true)"
    [ -n "$sdk" ] && export SDKROOT="$sdk"
  fi
  case "$cmd" in
    build|run|test)
      if swift build --help 2>/dev/null | grep -q -- '--build-system'; then
        exec swift "$cmd" --build-system native "$@"
      fi ;;
  esac
fi
exec swift "$cmd" "$@"
