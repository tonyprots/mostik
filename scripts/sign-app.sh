#!/bin/bash
# Подпись Mostik.app изнутри наружу (П8, пункт 4). Вызывает scripts/release.sh; можно и отдельно:
#   SIGN_MODE=adhoc scripts/sign-app.sh <Mostik.app>
#   SIGN_MODE=developer-id SIGN_IDENTITY="Developer ID Application: … (TEAMID)" scripts/sign-app.sh <Mostik.app>
#   SIGN_MODE=self-signed SIGN_IDENTITY=<SHA-1 сертификата> [SIGN_KEYCHAIN=<связка>] scripts/sign-app.sh <Mostik.app>
# self-signed — стабильный самоподписанный сертификат (docs/release.md): требование подписи
# `identifier "app.mostik.mac" and certificate leaf = H"<SHA-1>"` не меняется между сборками, и разрешения
# macOS переживают обновление. Без hardened runtime: проверка библиотек сравнивает Team ID, а его у
# самоподписанного сертификата нет — Sparkle.framework и Python не загрузились бы. Без метки времени.
# Порядок: отдельные Mach-O (встроенный Python, .so, .dylib, Autoupdate Sparkle) → вложенные бандлы
# от самых глубоких (XPC Sparkle, Updater.app, Sparkle.framework) → само приложение с entitlements.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?usage: sign-app.sh <Mostik.app>}"
MODE="${SIGN_MODE:-adhoc}"
APP_ENT="$ROOT/release/Mostik.entitlements"
ENGINE_ENT="$ROOT/release/Engine.entitlements"
case "$MODE" in
  developer-id)
    IDENTITY="${SIGN_IDENTITY:?SIGN_IDENTITY не задан}"
    SIGN_OPTS=(--options runtime --timestamp) ;;
  self-signed)
    IDENTITY="${SIGN_IDENTITY:?SIGN_IDENTITY (SHA-1 сертификата) не задан}"
    [[ "$IDENTITY" =~ ^[0-9A-F]{40}$ ]] || { echo "sign-app: SIGN_IDENTITY — 40 шестнадцатеричных знаков SHA-1 в верхнем регистре" >&2; exit 1; }
    SIGN_OPTS=(--timestamp=none)
    [ -z "${SIGN_KEYCHAIN:-}" ] || SIGN_OPTS+=(--keychain "$SIGN_KEYCHAIN") ;;
  adhoc)
    IDENTITY="-"
    SIGN_OPTS=(--timestamp=none) ;;
  *) echo "sign-app: неизвестный SIGN_MODE=$MODE (adhoc | self-signed | developer-id)" >&2; exit 1 ;;
esac

sign() { codesign --force --sign "$IDENTITY" "${SIGN_OPTS[@]}" "$@"; }
is_bundle_main() {  # главный исполняемый файл бандла подписывается вместе с бандлом
  case "$1" in
    */Contents/MacOS/*) return 0 ;;
    *.framework/Versions/*/*) [ "$(basename "$1")" = "$(basename "${1%%.framework/*}")" ] ;;
    *) return 1 ;;
  esac
}

# fluidaudiocli (разделение встреч по голосам) — готовый бинарник из transcriber с ad-hoc подписью.
# Переподпись меняет файл, а копия transcriber перед запуском сверяет его SHA-256 с fluidaudiocli.sha256
# рядом (catalog.bundled_binary_problem). Поэтому: сверить файл с суммой до подписи из
# scripts/vendor.lock, переподписать (Developer ID требует своей подписи с hardened runtime и меткой
# времени у каждого исполняемого файла) и записать в .sha256 сумму уже подписанного файла. Её
# закрепляет печать ресурсов приложения: правка .sha256 или бинарника ломает подпись .app.
# Entitlements движка ему не нужны: системные фреймворки, без исполняемой памяти и чужих библиотек.
FA="$APP/Contents/Resources/engine/bin/macos-arm64/fluidaudiocli"
if [ -e "$FA" ]; then
  python3 -I "$ROOT/scripts/vendor_python.py" fluidaudio --binary "$FA" \
    || { echo "sign-app: $FA не совпал с суммой из scripts/vendor.lock — не подписываю" >&2; exit 1; }
  sign "$FA"
  codesign --verify --strict "$FA"
  printf '%s  fluidaudiocli\n' "$(shasum -a 256 "$FA" | cut -d' ' -f1)" > "$FA.sha256"
  echo "sign-app: fluidaudiocli сверен с vendor.lock и переподписан, сумма после подписи — в fluidaudiocli.sha256"
fi

macho=0; engine=0
while IFS= read -r -d '' f; do
  is_bundle_main "$f" && continue
  [ "$f" = "$FA" ] && continue  # подписан выше, со сверкой суммы
  case "$(file -b "$f")" in
    *Mach-O*executable*)
      if [[ "$f" == "$APP/Contents/Resources/"* ]]; then
        sign --entitlements "$ENGINE_ENT" "$f"; engine=$((engine + 1))
      else
        sign "$f"
      fi ;;
    *Mach-O*) sign "$f" ;;
    *) continue ;;
  esac
  macho=$((macho + 1))
done < <(find "$APP/Contents" -type f \( -perm -u+x -o -name '*.so' -o -name '*.dylib' \) -print0)
echo "sign-app: отдельных Mach-O $macho, из них исполняемых движка $engine"

bundles=0
while IFS= read -r b; do
  sign --preserve-metadata=entitlements "$b"; bundles=$((bundles + 1))
done < <(find "$APP/Contents" -type d \( -name '*.xpc' -o -name '*.app' -o -name '*.framework' \) \
         | awk -F/ '{print NF "\t" $0}' | sort -rn | cut -f2-)
echo "sign-app: вложенных бандлов $bundles"

case "$MODE" in
  adhoc)
    # Как в bundle.sh: требование по идентификатору, чтобы TCC не забывал разрешения после пересборки.
    sign --entitlements "$APP_ENT" --identifier app.mostik.mac \
      --requirements '=designated => identifier "app.mostik.mac"' "$APP" ;;
  self-signed)
    # Требование явно, а не то, что выведет codesign: его сверяет release.sh, и по нему TCC узнаёт Mostik.
    sign --entitlements "$APP_ENT" --identifier app.mostik.mac \
      --requirements "=designated => identifier \"app.mostik.mac\" and certificate leaf = H\"$IDENTITY\"" "$APP" ;;
  *)
    sign --entitlements "$APP_ENT" "$APP" ;;
esac
codesign --verify --deep --strict --verbose=1 "$APP"
