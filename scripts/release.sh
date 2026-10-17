#!/bin/bash
# Выпуск Mostik: сборка, подпись изнутри наружу, нотаризация, .dmg с фоном, подпись Sparkle и appcast.
# Ничего не публикует: результат — в папке выпуска, выкладывает scripts/publish-release.sh. Пошагово — docs/release.md.
#
#   scripts/release.sh                — самоподписанный сертификат «Mostik Release» (по умолчанию): SHA-1
#                                       закреплён в release/release.conf, требование подписи
#                                       `identifier "app.mostik.mac" and certificate leaf = H"<SHA-1>"`
#                                       одно для всех сборок — разрешения macOS переживают обновление.
#                                       Без нотаризации: первая установка — «Всё равно открыть»
#   scripts/release.sh --developer-id — Developer ID + hardened runtime + нотаризация (нужны переменные ниже)
#   scripts/release.sh --adhoc        — проверка конвейера без сертификата: ad-hoc подпись, без нотаризации,
#                                   без подписи Sparkle и ленты; .dmg «только для этой машины»
#                                   (Mostik-<версия>-local-only.dmg): ad-hoc подпись с требованием
#                                   «только идентификатор» — любой бинарник с app.mostik.mac унаследует
#                                   разрешения TCC (П10, С2), раздавать такой образ нельзя
#
# Постоянное (адрес ленты, репозиторий, сертификат) — в release/release.conf, не в переменных.
#
# Переменные:
#   MOSTIK_SIGN_KEYCHAIN  связка ключей с сертификатом «Mostik Release» (по умолчанию — список поиска)
#   DEVELOPER_ID     «Developer ID Application: Имя (TEAMID)» — сертификат в связке ключей
#   TEAM_ID          10 символов Team ID, должен совпасть с тем, что в скобках у DEVELOPER_ID
#   NOTARY_PROFILE   профиль notarytool в связке ключей (по умолчанию mostik-notary)
#   VERSION, BUILD   версия (по умолчанию из Resources/Info.plist) и номер сборки (по умолчанию число коммитов)
#   MOSTIK_FEED_URL      запрещён: адрес ленты один, из release/release.conf (меняется только там и никогда
#                        после 0.1.0). В выпуск пишется SUFeedURL оттуда и SUEnableAutomaticChecks = true:
#                        проверка обновлений всегда включена, выключателя нет
#   MOSTIK_VENDOR_PYTHON, MOSTIK_SPARKLE  переопределения bundle.sh — в выпуске запрещены: Python и Sparkle
#                        берутся только из vendor/, сверенного с scripts/vendor.lock
#   MOSTIK_DOWNLOAD_URL  префикс https, где будут лежать .dmg (для <enclosure> в appcast); по умолчанию —
#                        GitHub Release этой версии: https://github.com/<репозиторий>/releases/download/v<версия>/.
#                        В --adhoc запрещён: ленту из ad-hoc сборки не делаем
#   MOSTIK_ALLOW_DIRTY   =1 — только в --adhoc и пробном выпуске: собрать из грязного дерева (dirty в SBOM)
#
# Пробный выпуск для проверки цепочки обновления на этой машине (scripts/update-e2e.sh), только с
# самоподписанным сертификатом. Всё «настоящее» подменяется пробным, образ называется *-test.dmg:
#   MOSTIK_TEST_RELEASE=1      включить; без него переменные ниже — остановка
#   MOSTIK_TEST_FEED_URL       лента на 127.0.0.1 (http://127.0.0.1:<порт>/appcast.xml)
#   MOSTIK_TEST_DOWNLOAD_URL   откуда брать .dmg, тоже 127.0.0.1
#   MOSTIK_SIGN_CERT_SHA1      временный сертификат из временной связки (MOSTIK_SIGN_KEYCHAIN)
#   SPARKLE_ED_KEY_FILE        временный ключ EdDSA из файла вместо ключа из связки ключей
#   MOSTIK_TEST_PUBLIC_ED_KEY  его публичная половина — в SUPublicEDKey пробной сборки
#   MOSTIK_RELEASE_OUT   папка выпуска (по умолчанию release-out/ в репозитории, она в .gitignore)
#   SPARKLE_ACCOUNT      учётка ключа EdDSA в связке ключей (по умолчанию app.mostik.mac)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MODE=self-signed
case "${1:-}" in
  "") ;;
  --adhoc) MODE=adhoc ;;
  --self-signed) MODE=self-signed ;;
  --developer-id) MODE=developer-id ;;
  *) printf 'release.sh: неизвестный режим %s (--self-signed | --developer-id | --adhoc)\n' "$1" >&2; exit 2 ;;
esac

die() { printf 'release.sh: %s\n' "$*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

# release/release.conf — KEY=value без подстановок; читаем сами, а не `source`.
conf() {
  local line
  line="$(grep -E "^$1=" "$ROOT/release/release.conf" | tail -1)" || true
  line="${line#*=}"; line="${line%\"}"; line="${line#\"}"
  printf '%s' "$line"
}
FEED_URL="$(conf MOSTIK_FEED_URL)"
GITHUB_REPO="$(conf MOSTIK_GITHUB_REPO)"
CERT_NAME="$(conf MOSTIK_SIGN_CERT_NAME)"
CERT_SHA1="$(conf MOSTIK_SIGN_CERT_SHA1)"
TEST="${MOSTIK_TEST_RELEASE:-0}"
[ -z "${MOSTIK_FEED_URL:-}" ] || die "MOSTIK_FEED_URL задан: адрес ленты один — MOSTIK_FEED_URL в release/release.conf"

PLIST="$ROOT/Resources/Info.plist"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")}"
BUILD="${BUILD:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
OUT="${MOSTIK_RELEASE_OUT:-$ROOT/release-out}"
NOTARY_PROFILE="${NOTARY_PROFILE:-mostik-notary}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-app.mostik.mac}"
SPARKLE_BIN="${MOSTIK_SPARKLE_BIN:-$ROOT/vendor/sparkle/current/bin}"
if [ "$TEST" = 1 ]; then
  [ "$MODE" = self-signed ] || die "MOSTIK_TEST_RELEASE=1 — только с самоподписанным сертификатом"
  for v in MOSTIK_TEST_FEED_URL MOSTIK_TEST_DOWNLOAD_URL MOSTIK_SIGN_CERT_SHA1 SPARKLE_ED_KEY_FILE MOSTIK_TEST_PUBLIC_ED_KEY; do
    [ -n "${!v:-}" ] || die "пробный выпуск: не задан $v"
  done
  for u in "$MOSTIK_TEST_FEED_URL" "$MOSTIK_TEST_DOWNLOAD_URL"; do
    case "$u" in http://127.0.0.1:*/*) ;; *) die "пробный выпуск: адреса только http://127.0.0.1:<порт>/…, получено $u";; esac
  done
  [ -z "${MOSTIK_DOWNLOAD_URL:-}" ] || die "пробный выпуск: MOSTIK_DOWNLOAD_URL не нужен, есть MOSTIK_TEST_DOWNLOAD_URL"
  FEED_URL="$MOSTIK_TEST_FEED_URL"
  DOWNLOAD_URL="$MOSTIK_TEST_DOWNLOAD_URL"
  CERT_SHA1="$MOSTIK_SIGN_CERT_SHA1"
else
  for v in MOSTIK_TEST_FEED_URL MOSTIK_TEST_DOWNLOAD_URL MOSTIK_TEST_PUBLIC_ED_KEY SPARKLE_ED_KEY_FILE MOSTIK_SIGN_CERT_SHA1; do
    [ -z "${!v:-}" ] || die "$v — только для пробного выпуска (MOSTIK_TEST_RELEASE=1); сертификат закрепляется в release/release.conf"
  done
  DOWNLOAD_URL="${MOSTIK_DOWNLOAD_URL:-https://github.com/$GITHUB_REPO/releases/download/v$VERSION/}"
fi
CERT_SHA1="$(printf '%s' "$CERT_SHA1" | tr '[:lower:]' '[:upper:]' | tr -d ' :')"
case "$MODE" in
  adhoc) DMG="$OUT/Mostik-$VERSION-local-only.dmg" ;;
  *) if [ "$TEST" = 1 ]; then DMG="$OUT/Mostik-$VERSION-test.dmg"; else DMG="$OUT/Mostik-$VERSION.dmg"; fi ;;
esac
# Подпись EdDSA: ключ из связки ключей; в пробном выпуске — временный из файла.
if [ "$TEST" = 1 ]; then
  ED_ARGS=(--ed-key-file "$SPARKLE_ED_KEY_FILE")
else
  ED_ARGS=(--account "$SPARKLE_ACCOUNT")
fi
KC_ARGS=()
[ -z "${MOSTIK_SIGN_KEYCHAIN:-}" ] || KC_ARGS=("$MOSTIK_SIGN_KEYCHAIN")

# --- 0. Что нужно до старта. Без Developer ID — честная остановка, а не наполовину подписанный выпуск.
step "Проверка: режим $MODE, версия $VERSION ($BUILD)"
# Р2, низкие: выпуск берёт Python и Sparkle только из vendor/, который сверяется с lock-файлами ниже.
# Р3 Н-6: и бинарники Sparkle (`sign_update`, `generate_keys`) — они получают ключ EdDSA из связки ключей.
for override in MOSTIK_VENDOR_PYTHON MOSTIK_SPARKLE MOSTIK_SPARKLE_BIN; do
  [ -z "${!override:-}" ] || die "$override задан: выпуск берёт Python и Sparkle только из vendor/, сверенного с lock-файлами"
done
if [ "$MODE" = adhoc ]; then
  [ -z "${MOSTIK_DOWNLOAD_URL:-}" ] || die "MOSTIK_DOWNLOAD_URL в --adhoc: ленту из ad-hoc сборки не делаем (П10, С2)"
elif [ "$TEST" != 1 ]; then
  case "$DOWNLOAD_URL" in https://*) ;; *) die "MOSTIK_DOWNLOAD_URL должен быть https";; esac
  case "$FEED_URL" in https://*) ;; *) die "MOSTIK_FEED_URL в release/release.conf должен быть https";; esac
fi
[ -x "$SPARKLE_BIN/sign_update" ] || die "нет Sparkle ($SPARKLE_BIN/sign_update). Распакуйте релиз Sparkle 2 в vendor/sparkle/<версия> и сделайте ссылку vendor/sparkle/current — см. docs/release.md"
if [ "$MODE" = self-signed ]; then
  [ -n "$CERT_NAME" ] || die "в release/release.conf нет MOSTIK_SIGN_CERT_NAME"
  if [ -z "$CERT_SHA1" ]; then
    printf 'release.sh: сертификат подписи не закреплён: MOSTIK_SIGN_CERT_SHA1 в release/release.conf пуст.\n' >&2
    printf '  Создайте «%s» (docs/release.md, «Сертификат „Mostik Release“») и впишите его SHA-1:\n' "$CERT_NAME" >&2
    printf '  security find-certificate -c "%s" -Z | grep SHA-1\n' "$CERT_NAME" >&2
    printf 'Проверить конвейер без сертификата: scripts/release.sh --adhoc\n' >&2
    exit 2
  fi
  [[ "$CERT_SHA1" =~ ^[0-9A-F]{40}$ ]] || die "MOSTIK_SIGN_CERT_SHA1 — 40 шестнадцатеричных знаков, получено «${CERT_SHA1}»"
  # Сертификат с этим именем и именно с закреплённым SHA-1. Другой — значит, его пересоздали: все
  # установленные копии потеряли бы разрешения, а Mostik отказался бы ставить такое обновление.
  found_sha="$(security find-certificate -a -c "$CERT_NAME" -Z ${KC_ARGS[@]+"${KC_ARGS[@]}"} 2>/dev/null | awk '/^SHA-1 hash:/ {print toupper($3)}')"
  if ! printf '%s\n' "$found_sha" | grep -qx "$CERT_SHA1"; then
    if [ -n "$found_sha" ]; then
      die "сертификат «${CERT_NAME}» в связке ключей не тот: закреплён $CERT_SHA1, найден $(echo $found_sha). Новый сертификат = все установленные копии теряют разрешения; восстановите прежний из резервной копии .p12 (docs/release.md)"
    fi
    die "нет сертификата «${CERT_NAME}» в связке ключей${MOSTIK_SIGN_KEYCHAIN:+ $MOSTIK_SIGN_KEYCHAIN}. Создание и резервная копия — docs/release.md, «Сертификат „Mostik Release“»"
  fi
  # Закрытый ключ рядом с сертификатом (без -v: самоподписанному сертификату система не доверяет, это нормально).
  security find-identity -p codesigning ${KC_ARGS[@]+"${KC_ARGS[@]}"} 2>/dev/null | grep -q "$CERT_SHA1" \
    || die "сертификат $CERT_SHA1 есть, а закрытого ключа к нему нет — импортируйте .p12 целиком, а не только сертификат"
  IDENTITY="$CERT_SHA1"
  EXPECTED_DR="designated => identifier \"app.mostik.mac\" and certificate leaf = H\"$CERT_SHA1\""
elif [ "$MODE" = developer-id ]; then
  missing=()
  [ -n "${DEVELOPER_ID:-}" ] || missing+=("DEVELOPER_ID (например \"Developer ID Application: Your Name (ABCDE12345)\")")
  [ -n "${TEAM_ID:-}" ] || missing+=("TEAM_ID (10 символов из developer.apple.com → Membership)")
  if [ ${#missing[@]} -gt 0 ]; then
    printf 'release.sh: для подписи Developer ID и нотаризации не хватает:\n' >&2
    printf '  - %s\n' "${missing[@]}" >&2
    printf 'Что это и где взять — docs/release.md. Проверить конвейер без Apple: scripts/release.sh --adhoc\n' >&2
    exit 2
  fi
  case "$DEVELOPER_ID" in *"($TEAM_ID)"*) ;; *) die "TEAM_ID=$TEAM_ID не совпадает с DEVELOPER_ID=\"$DEVELOPER_ID\"";; esac
  security find-identity -v -p codesigning | grep -qF "\"$DEVELOPER_ID\"" \
    || die "сертификата \"$DEVELOPER_ID\" нет в связке ключей (security find-identity -v -p codesigning)"
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || die "профиля notarytool \"$NOTARY_PROFILE\" нет или он не входит. Создайте: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id … --team-id $TEAM_ID"
  IDENTITY="$DEVELOPER_ID"
else
  IDENTITY="-"
fi
# Цепочка поставки (П10, С9–С11): встроенный Python, его пакеты и Sparkle — против сумм из git
# (scripts/vendor.lock, scripts/requirements.lock); код — из чистого дерева. Код transcriber —
# копия в engine/vendor_transcriber (П10 С11), её покрывает та же проверка. П10 р4, поставка-2: до первого
# запуска generate_keys — он получает ключ EdDSA из связки ключей.
step "Цепочка поставки"
python3 -I "$ROOT/scripts/vendor_python.py" verify || die "vendor не совпал с scripts/vendor.lock и scripts/requirements.lock"
dirty=()
python3 -I "$ROOT/scripts/vendor_python.py" git-state "$ROOT" || dirty+=("Mostik ($ROOT)")
if [ ${#dirty[@]} -gt 0 ]; then
  if { [ "$MODE" = adhoc ] || [ "$TEST" = 1 ]; } && [ "${MOSTIK_ALLOW_DIRTY:-0}" = "1" ]; then
    printf 'release.sh: грязное дерево — %s; MOSTIK_ALLOW_DIRTY=1, в SBOM будет dirty\n' "${dirty[*]}" >&2
  else
    die "незакоммиченные изменения: ${dirty[*]}. Выпуск собирается только из коммита (в --adhoc можно MOSTIK_ALLOW_DIRTY=1)"
  fi
fi

if [ "$MODE" != adhoc ] && [ "$TEST" != 1 ]; then  # в --adhoc ключ EdDSA не нужен: подписи Sparkle там нет
  "$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -p >/dev/null 2>&1 \
    || die "нет ключа EdDSA \"$SPARKLE_ACCOUNT\" в связке ключей: $SPARKLE_BIN/generate_keys --account $SPARKLE_ACCOUNT"
  KEY_IN_PLIST="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST")"
  [ "$("$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -p)" = "$KEY_IN_PLIST" ] \
    || die "SUPublicEDKey в Info.plist не совпадает с ключом \"$SPARKLE_ACCOUNT\" в связке ключей"
fi

# Выпуск строго: без списка запрещённых строк (.git/info/denylist) не собираем, в репозитории их быть не должно.
step "Запрещённые строки: файлы и история"
bash "$ROOT/scripts/check-denylist.sh" --tracked || die "запрещённые строки в файлах репозитория"
bash "$ROOT/scripts/check-denylist.sh" --history || die "запрещённые строки в истории git"

# --- 1. Сборка в свою папку: dist/ и запущенный Mostik не трогаем.
step "Сборка"
STAGE="$OUT/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
MOSTIK_DIST="$STAGE" bash "$ROOT/scripts/bundle.sh"
APP="$STAGE/Mostik.app"
bash "$ROOT/scripts/check-denylist.sh" --app "$APP" || die "запрещённые строки в собранном приложении"
[ -d "$APP/Contents/Frameworks/Sparkle.framework" ] || die "в сборке нет Sparkle.framework — выпуск без автообновления не делаем"
SBOM="$APP/Contents/Resources/MOSTIK-VENDOR.json"
[ -f "$SBOM" ] || die "в сборке нет SBOM (Contents/Resources/MOSTIK-VENDOR.json)"
if [ "$MODE" != adhoc ] && [ "$TEST" != 1 ] && grep -q '"dirty": true' "$SBOM"; then
  die "SBOM: дерево изменилось во время сборки (dirty) — пересоберите из коммита"
fi

need_kb=$(( $(du -sk "$APP" | cut -f1) * 4 ))
free_kb=$(df -k "$OUT" | awk 'NR==2 {print $4}')
[ "$free_kb" -gt "$need_kb" ] || die "мало места: нужно ~$((need_kb / 1024)) МБ, свободно $((free_kb / 1024)) МБ"

INFO="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$INFO"
if [ "$MODE" != adhoc ]; then
  # Проверка обновлений всегда включена (решение автора): без вопроса и без выключателя. Установка —
  # по кнопке в окне Sparkle; «ставить автоматически» пользователь включает там же, галочкой.
  /usr/libexec/PlistBuddy -c "Set :SUFeedURL $FEED_URL" -c "Set :SUEnableAutomaticChecks true" "$INFO"
  if [ "$TEST" = 1 ]; then
    /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $MOSTIK_TEST_PUBLIC_ED_KEY" "$INFO"
  fi
fi
# Лента обязана быть подписана (П10, инфо): иначе можно подсунуть старую подписанную версию.
/usr/libexec/PlistBuddy -c "Set :SURequireSignedFeed true" "$INFO" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :SURequireSignedFeed bool true" "$INFO"
[ "$(/usr/libexec/PlistBuddy -c 'Print :SURequireSignedFeed' "$INFO")" = true ] || die "SURequireSignedFeed не включился"
echo "SUFeedURL: $(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$INFO"), SURequireSignedFeed: true"

# --- 2. Подпись изнутри наружу (scripts/sign-app.sh): Python, .so, Sparkle XPC, фреймворк, приложение.
step "Подпись ($IDENTITY)"
SIGN_IDENTITY="$IDENTITY" SIGN_MODE="$MODE" SIGN_KEYCHAIN="${MOSTIK_SIGN_KEYCHAIN:-}" bash "$ROOT/scripts/sign-app.sh" "$APP"
# Требование подписи (designated requirement) — то, по чему macOS узнаёт Mostik в разрешениях. Оно уходит
# в ленту (`mostik:designatedRequirement`), и установленный Mostik не ставит обновление с другим.
ACTUAL_DR="$(codesign -d -r- "$APP" 2>&1 | grep '^designated => ' || true)"
[ -n "$ACTUAL_DR" ] || die "codesign не показал требование подписи у $APP"
echo "Требование подписи: $ACTUAL_DR"
if [ "$MODE" = self-signed ]; then
  lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
  [ "$(lower "$ACTUAL_DR")" = "$(lower "$EXPECTED_DR")" ] \
    || die "требование подписи не совпало с закреплённым: ждали «${EXPECTED_DR}», получили «${ACTUAL_DR}»"
  # Встроенный Python и Sparkle подписаны тем же сертификатом: другой подписи у вложенного кода быть не должно.
  for part in "$APP/Contents/Frameworks/Sparkle.framework" \
              "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" \
              "$APP/Contents/Resources/python/bin/python3"; do
    [ -e "$part" ] || continue
    authority="$(codesign -dvv "$part" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
    [ "$authority" = "$CERT_NAME" ] || die "$part подписан не «${CERT_NAME}» (Authority=$authority)"
  done
  echo "Вложенный код (Python, Sparkle) подписан «${CERT_NAME}»"
fi

# --- 3. Нотаризация приложения и скрепка: Sparkle распаковывает .app из .dmg, у него должен быть свой билет.
if [ "$MODE" = developer-id ]; then
  step "Нотаризация приложения"
  ditto -c -k --keepParent "$APP" "$OUT/Mostik-notarize.zip"
  xcrun notarytool submit "$OUT/Mostik-notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$OUT/Mostik-notarize.zip"
  spctl --assess --type execute --verbose=2 "$APP"
fi

# --- 4. .dmg: фон рисуется кодом, ссылка на /Applications, раскладка окна — .DS_Store без AppleScript.
# Р2 Н5: промежуточное — во временной папке, не в release-out под домом сборщика: путь к образу
# не должен попасть ни в какие метаданные тома.
step "Образ .dmg"
WORK="$(mktemp -d /tmp/mostik-release.XXXXXX)"
ROOTDIR="$WORK/dmg-root"
RW="$WORK/Mostik-rw.dmg"
rm -f "$DMG"
mkdir -p "$ROOTDIR/.background"
ditto "$APP" "$ROOTDIR/Mostik.app"
ln -s /Applications "$ROOTDIR/Applications"
swift "$ROOT/scripts/dmg-layout.swift" background "$WORK/bg"
tiffutil -cathidpicheck "$WORK/bg/background.png" "$WORK/bg/background@2x.png" -out "$ROOTDIR/.background/background.tiff" >/dev/null
hdiutil create -quiet -volname Mostik -srcfolder "$ROOTDIR" -fs HFS+ -format UDRW -ov "$RW"
MNT="$(mktemp -d /tmp/mostik-dmg.XXXXXX)"
hdiutil attach -quiet -readwrite -noverify -noautoopen -nobrowse -mountpoint "$MNT" "$RW"
trap 'hdiutil detach -quiet "$MNT" 2>/dev/null || true; rm -rf "$WORK"' EXIT
swift "$ROOT/scripts/dmg-layout.swift" dsstore "$MNT" Mostik.app
hdiutil detach -quiet "$MNT"
rmdir "$MNT" 2>/dev/null || true
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -rf "$WORK"
trap - EXIT

# Р2 Н5: готовый образ — только на чтение и целиком, со скрытыми .DS_Store и .background:
# ни домашней папки, ни логина сборщика.
step "Проверка образа на пути сборщика"
MNT="$(mktemp -d /tmp/mostik-dmg.XXXXXX)"
hdiutil attach -quiet -readonly -noverify -noautoopen -nobrowse -mountpoint "$MNT" "$DMG"
trap 'hdiutil detach -quiet "$MNT" 2>/dev/null || true' EXIT
leak_rc=0
bash "$ROOT/scripts/check-leaks.sh" --tree "$MNT" "$(cd ~ && pwd -P)" "$HOME" "$(id -un)" || leak_rc=$?
hdiutil detach -quiet "$MNT"
trap - EXIT
rmdir "$MNT" 2>/dev/null || true
[ "$leak_rc" -eq 0 ] || die "в образе $DMG есть пути или логин сборщика (код $leak_rc)"
if [ "$MODE" = developer-id ]; then
  codesign --force --sign "$IDENTITY" --timestamp "$DMG"
  step "Нотаризация .dmg"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi
hdiutil verify -quiet "$DMG"

# --- 5. Подпись Sparkle (EdDSA, ключ из связки) и подписанная лента. Только после скрепки: она меняет .dmg.
# В --adhoc не подписываем: подпись EdDSA превратила бы образ «только для этой машины» в обновление.
if [ "$MODE" != adhoc ]; then
  step "Sparkle"
  # П10 р4, поставка-2: между первой сверкой и подписью — минуты сборки и нотаризации; vendor/ сверяем ещё раз.
  python3 -I "$ROOT/scripts/vendor_python.py" verify || die "vendor/ изменился во время выпуска — подпись EdDSA не выдаём"
  SIG="$("$SPARKLE_BIN/sign_update" "${ED_ARGS[@]}" "$DMG")"
  echo "$SIG"
  echo "$SIG" > "$DMG.sparkle-signature"
  [ -f "$OUT/appcast.xml" ] || cp "$ROOT/release/appcast.xml" "$OUT/appcast.xml"
  MIN_SYSTEM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO")"
  python3 -I "$ROOT/scripts/appcast.py" "$OUT/appcast.xml" --version "$VERSION" --build "$BUILD" \
    --url "${DOWNLOAD_URL%/}/$(basename "$DMG")" --signature "$SIG" --min-system "$MIN_SYSTEM" \
    --requirement "$ACTUAL_DR"
  # SURequireSignedFeed: подпись ленты встраивается в сам appcast.xml и заменяется при каждом выпуске.
  "$SPARKLE_BIN/sign_update" "${ED_ARGS[@]}" "$OUT/appcast.xml"
  "$SPARKLE_BIN/sign_update" --verify "${ED_ARGS[@]}" "$OUT/appcast.xml" \
    || die "подпись appcast.xml не проверяется"
else
  rm -f "$DMG.sparkle-signature"
  echo "Ad-hoc: без подписи Sparkle и без ленты (П10, С2)"
fi

step "Готово ($MODE)"
ls -lh "$DMG"
if [ "$MODE" = adhoc ]; then
  echo "Ad-hoc: образ только для этой машины. Не раздавать: требование подписи «только идентификатор»"
  echo "позволяет любому бинарнику с app.mostik.mac унаследовать разрешения TCC (docs/release.md)."
fi
[ "$TEST" = 1 ] && echo "Пробный выпуск: временные сертификат и ключ EdDSA, лента на 127.0.0.1 — не публиковать."
echo "Ничего не опубликовано. Выкладка — scripts/publish-release.sh $VERSION (по умолчанию сухой прогон), docs/release.md."
