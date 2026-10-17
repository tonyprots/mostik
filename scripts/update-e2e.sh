#!/bin/bash
# Проверка цепочки обновления целиком, без настоящего сертификата и без сети:
#   временная связка ключей + временный самоподписанный «Mostik Release» + временный ключ EdDSA →
#   два пробных выпуска (0.1.0 и 0.1.1, release.sh MOSTIK_TEST_RELEASE=1) → лента на 127.0.0.1 →
#   проба (scripts/update-probe: настоящий Sparkle и SparkleUpdateGuard) обновляет копию 0.1.0 в /tmp.
#
# Что проверяется:
#   1. испорченный .dmg — Sparkle отказывает (EdDSA);
#   2. лента изменена после подписи — отказ (SURequireSignedFeed);
#   3. в ленте другое требование подписи (подпись ленты верная) — отказ SparkleUpdateGuard с объяснением;
#   4. честное обновление 0.1.0 → 0.1.1 ставится; требование подписи у обеих версий одно; карантина нет.
#
# Настоящий Mostik не запускается и не трогается. Всё временное — в /tmp/mostik-e2e и во временной связке:
# она на время прогона в списке поиска (иначе codesign её не видит), в конце список возвращается, связка
# удаляется вместе с ключами SU*, которые Sparkle пишет в домен app.mostik.mac.
#
#   scripts/update-e2e.sh            сборка двух выпусков (~10 минут) и проверки
#   MOSTIK_E2E_KEEP=1 …              не удалять /tmp/mostik-e2e (посмотреть руками)
#   MOSTIK_E2E_REUSE=1 …             проверки на выпусках прошлого прогона с KEEP=1, без пересборки
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
E2E=/tmp/mostik-e2e
OPENSSL="$(ls /opt/homebrew/opt/openssl@3/bin/openssl /opt/homebrew/opt/openssl/bin/openssl 2>/dev/null | head -1)"
[ -x "$OPENSSL" ] || { echo "update-e2e: нужен OpenSSL 3 (brew install openssl@3)" >&2; exit 1; }
SPARKLE="$ROOT/vendor/sparkle/current"
CERT_NAME="$(sed -n 's/^MOSTIK_SIGN_CERT_NAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$ROOT/release/release.conf")"
KC="$E2E/mostik-e2e.keychain-db"
KC_PASS="mostik-e2e-$$"
REUSE="${MOSTIK_E2E_REUSE:-0}"
fail=0

step() { printf '\n=== %s\n' "$*"; }
pass() { printf 'ПРОЙДЕНО: %s\n' "$*"; }
bad() { printf 'ПРОВАЛ: %s\n' "$*"; fail=1; }

# --- Уборка: временная связка, сервер, ключи Sparkle в домене app.mostik.mac, кэш установщика.
had_sparkle_cache=0
[ -e "$HOME/Library/Caches/app.mostik.mac" ] && had_sparkle_cache=1
SU_KEYS_BEFORE="$(defaults read app.mostik.mac 2>/dev/null | sed -n 's/^ *\(SU[A-Za-z]*\) = .*/\1/p' | sort -u || true)"
# codesign находит личность только в связке из списка поиска (`--keychain` без этого — «no identity found»):
# временная связка добавляется в список на время прогона, исходный список возвращается дословно.
SEARCH_BEFORE=()
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"; line="${line#\"}"; line="${line%\"}"
  [ -n "$line" ] && SEARCH_BEFORE+=("$line")
done < <(security list-keychains -d user)
cleanup() {
  local rc=$?
  [ ${#SEARCH_BEFORE[@]} -gt 0 ] && security list-keychains -d user -s "${SEARCH_BEFORE[@]}"
  [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true
  security delete-keychain "$KC" 2>/dev/null || true
  for k in $(defaults read app.mostik.mac 2>/dev/null | sed -n 's/^ *\(SU[A-Za-z]*\) = .*/\1/p' | sort -u); do
    printf '%s\n' "$SU_KEYS_BEFORE" | grep -qx "$k" || defaults delete app.mostik.mac "$k" 2>/dev/null || true
  done
  [ "$had_sparkle_cache" = 1 ] || rm -rf "$HOME/Library/Caches/app.mostik.mac"
  [ "${MOSTIK_E2E_KEEP:-0}" = 1 ] || rm -rf "$E2E"
  security list-keychains -d user | grep -q mostik-e2e && echo "update-e2e: временная связка осталась в списке поиска!" >&2
  exit "$rc"
}
trap cleanup EXIT

if [ "$REUSE" = 1 ]; then
  for f in "$E2E/port" "$E2E/keys/ed.key" "$E2E/out/Mostik-0.1.0-test.dmg" "$E2E/out/Mostik-0.1.1-test.dmg" "$E2E/out/appcast.xml"; do
    [ -f "$f" ] || { echo "update-e2e: MOSTIK_E2E_REUSE=1, а $f нет — сначала прогон с MOSTIK_E2E_KEEP=1" >&2; exit 1; }
  done
  PORT="$(cat "$E2E/port")"
  rm -rf "$E2E/probe" "$E2E/install" "$E2E/served"
else
  rm -rf "$E2E"
  mkdir -p "$E2E/keys" "$E2E/out"
  # Свободный порт: адрес ленты зашит в сборку 0.1.0, поэтому он выбирается один раз и хранится рядом.
  PORT="$(/usr/bin/python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
  echo "$PORT" > "$E2E/port"
fi
mkdir -p "$E2E/served" "$E2E/probe/Probe.app/Contents/MacOS" "$E2E/probe/Probe.app/Contents/Frameworks"

if [ "$REUSE" != 1 ]; then

step "Временная связка ключей и сертификат «${CERT_NAME}» (только в ней)"
security create-keychain -p "$KC_PASS" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$KC_PASS" "$KC"
security list-keychains -d user -s "${SEARCH_BEFORE[@]}" "$KC"
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$CERT_NAME" \
  -addext "basicConstraints=critical,CA:false" -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -keyout "$E2E/keys/cert.key" -out "$E2E/keys/cert.pem" 2>/dev/null
"$OPENSSL" pkcs12 -export -legacy -inkey "$E2E/keys/cert.key" -in "$E2E/keys/cert.pem" \
  -out "$E2E/keys/cert.p12" -passout pass:e2e
security import "$E2E/keys/cert.p12" -k "$KC" -P e2e -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KC" >/dev/null
SHA1="$("$OPENSSL" x509 -in "$E2E/keys/cert.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"
echo "SHA-1 временного сертификата: $SHA1"

step "Временный ключ EdDSA"
"$OPENSSL" genpkey -algorithm ed25519 -outform DER -out "$E2E/keys/ed.der"
tail -c 32 "$E2E/keys/ed.der" | base64 > "$E2E/keys/ed.key"
ED_PUB="$("$OPENSSL" pkey -inform DER -in "$E2E/keys/ed.der" -pubout -outform DER | tail -c 32 | base64)"
echo "SUPublicEDKey пробных сборок: $ED_PUB"

build() {  # build <версия> <номер сборки>
  step "Пробный выпуск $1 ($2)"
  VERSION="$1" BUILD="$2" MOSTIK_TEST_RELEASE=1 \
  MOSTIK_TEST_FEED_URL="http://127.0.0.1:$PORT/appcast.xml" MOSTIK_TEST_DOWNLOAD_URL="http://127.0.0.1:$PORT/" \
  MOSTIK_SIGN_CERT_SHA1="$SHA1" MOSTIK_SIGN_KEYCHAIN="$KC" SPARKLE_ED_KEY_FILE="$E2E/keys/ed.key" \
  MOSTIK_TEST_PUBLIC_ED_KEY="$ED_PUB" MOSTIK_RELEASE_OUT="$E2E/out" MOSTIK_ALLOW_DIRTY="${MOSTIK_ALLOW_DIRTY:-0}" \
    bash "$ROOT/scripts/release.sh" --self-signed > "$E2E/build-$1.log" 2>&1 \
    || { tail -30 "$E2E/build-$1.log"; echo "update-e2e: выпуск $1 не собрался" >&2; exit 1; }
  grep -E '^Требование подписи|подписан «' "$E2E/build-$1.log" || true
}
build 0.1.0 100
cp "$E2E/out/appcast.xml" "$E2E/appcast-0.1.0.xml"
build 0.1.1 101
fi

step "Проба: настоящий Sparkle + SparkleUpdateGuard"
swiftc -O -module-name MostikCore -F "$SPARKLE" -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  "$ROOT/Sources/MostikCore/UpdatePolicy.swift" "$ROOT/Sources/MostikKit/CodeRequirement.swift" \
  "$ROOT/Sources/MostikKit/SparkleUpdateGuard.swift" "$ROOT/scripts/update-probe/main.swift" \
  -o "$E2E/probe/Probe.app/Contents/MacOS/update-probe" 2>&1 | grep -v 'ignoring import\|^ *[0-9|`]\|^$' || true
ditto "$SPARKLE/Sparkle.framework" "$E2E/probe/Probe.app/Contents/Frameworks/Sparkle.framework"
cat > "$E2E/probe/Probe.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>app.mostik.e2e-probe</string>
  <key>CFBundleExecutable</key><string>update-probe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
codesign --force --deep --sign - "$E2E/probe/Probe.app" 2>/dev/null
PROBE="$E2E/probe/Probe.app/Contents/MacOS/update-probe"

DMG010="$E2E/out/Mostik-0.1.0-test.dmg"
DMG011="$E2E/out/Mostik-0.1.1-test.dmg"
INSTALLED="$E2E/install/Mostik.app"
install_010() {
  rm -rf "$E2E/install"; mkdir -p "$E2E/install"
  local mnt; mnt="$(mktemp -d /tmp/mostik-e2e-mnt.XXXXXX)"
  hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$mnt" "$DMG010"
  ditto "$mnt/Mostik.app" "$INSTALLED"
  hdiutil detach -quiet "$mnt"; rmdir "$mnt"
}
version_of() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null || echo "?"; }
dr_of() { codesign -d -r- "$1" 2>&1 | grep '^designated => ' | tr '[:upper:]' '[:lower:]'; }
serve() {  # serve <лента> <.dmg 0.1.1>
  rm -f "$E2E/served/"*   # саму папку не удалять: в ней работает http.server
  cp "$1" "$E2E/served/appcast.xml"
  cp "$2" "$E2E/served/Mostik-0.1.1-test.dmg"
  cp "$DMG010" "$E2E/served/"
}
probe() {  # probe → печатает строку RESULT; запросы к серверу за этот запуск — в $E2E/requests.log
  defaults delete app.mostik.mac SUSkippedVersion 2>/dev/null || true
  local before; before=$(wc -l < "$E2E/http.log")
  "$PROBE" "$INSTALLED" > "$E2E/probe.log" 2>&1 || true
  sleep 1
  tail -n +$((before + 1)) "$E2E/http.log" | grep -o '"GET [^"]*"' > "$E2E/requests.log" || true
  sed -n 's/^RESULT: //p' "$E2E/probe.log" | tail -1
}
fetched() { grep -q "GET /$1" "$E2E/requests.log"; }
wait_version() {  # wait_version <ожидаемая> <секунд>
  local i
  for ((i = 0; i < $2; i++)); do [ "$(version_of "$INSTALLED")" = "$1" ] && return 0; sleep 1; done
  return 1
}

/usr/bin/python3 -I -m http.server "$PORT" --bind 127.0.0.1 --directory "$E2E/served" >"$E2E/http.log" 2>&1 &
SERVER_PID=$!
sleep 1
# Порт мог занять кто-то ещё между выбором и запуском: сервер должен быть наш и отдавать наш файл.
kill -0 "$SERVER_PID" 2>/dev/null || { cat "$E2E/http.log"; echo "update-e2e: сервер на 127.0.0.1:$PORT не запустился" >&2; exit 1; }
echo probe > "$E2E/served/ping.txt"
for _ in 1 2 3 4 5; do [ "$(curl -s --noproxy "*" "http://127.0.0.1:$PORT/ping.txt")" = probe ] && break; sleep 1; done
[ "$(curl -s --noproxy "*" "http://127.0.0.1:$PORT/ping.txt")" = probe ] || { echo "update-e2e: на 127.0.0.1:$PORT отвечает не наш сервер" >&2; exit 1; }

step "1. Испорченный .dmg"
install_010
cp "$DMG011" "$E2E/broken.dmg"
size=$(stat -f %z "$E2E/broken.dmg")
printf '\xff' | dd of="$E2E/broken.dmg" bs=1 seek=$((size / 2)) conv=notrunc 2>/dev/null
serve "$E2E/out/appcast.xml" "$E2E/broken.dmg"
r="$(probe)"; echo "$r"
sleep 5
if [ "$(version_of "$INSTALLED")" = 0.1.0 ] && [[ "$r" == error* ]] && fetched Mostik-0.1.1-test.dmg; then pass "испорченный .dmg скачан и не поставлен"; else bad "испорченный .dmg: $r, версия $(version_of "$INSTALLED"), запросы: $(tr '\n' ' ' < "$E2E/requests.log")"; fi

step "2. Лента изменена после подписи"
install_010
sed 's/Mostik-0.1.1-test.dmg/Mostik-0.1.1-test.dmg?x=1/' "$E2E/out/appcast.xml" > "$E2E/tampered.xml"
serve "$E2E/tampered.xml" "$DMG011"
r="$(probe)"; echo "$r"
sleep 5
if [ "$(version_of "$INSTALLED")" = 0.1.0 ] && [[ "$r" == error* || "$r" == none* ]] && fetched appcast.xml && ! fetched Mostik-0.1.1; then pass "изменённая лента отвергнута до скачивания"; else bad "изменённая лента: $r, версия $(version_of "$INSTALLED"), запросы: $(tr '\n' ' ' < "$E2E/requests.log")"; fi

step "3. Другое требование подписи в ленте (лента подписана верно)"
install_010
python3 -I - "$E2E/out/appcast.xml" "$E2E/other-dr.xml" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
text = re.sub(r"<!-- sparkle-signatures:.*?-->\s*", "", text, flags=re.S)
items = text.split("<item>")
items[1] = re.sub(r'H"[0-9a-fA-F]{40}"', 'H"' + "0" * 40 + '"', items[1], count=1)
open(sys.argv[2], "w", encoding="utf-8").write("<item>".join(items))
PY
"$SPARKLE/bin/sign_update" --ed-key-file "$E2E/keys/ed.key" "$E2E/other-dr.xml"
"$SPARKLE/bin/sign_update" --verify --ed-key-file "$E2E/keys/ed.key" "$E2E/other-dr.xml" || bad "переподписанная лента не проверяется"
grep -c 'H"0000000000000000000000000000000000000000"' "$E2E/other-dr.xml" >/dev/null || bad "требование в ленте не подменилось"
serve "$E2E/other-dr.xml" "$DMG011"
r="$(probe)"; echo "$r"
sleep 5
if [ "$(version_of "$INSTALLED")" = 0.1.0 ] && [[ "$r" == "error app.mostik.update"* ]] && ! fetched Mostik-0.1.1; then pass "другое требование подписи — отказ с объяснением, .dmg не скачивался"; else bad "другое требование: $r, версия $(version_of "$INSTALLED"), запросы: $(tr '\n' ' ' < "$E2E/requests.log")"; fi

step "4. Честное обновление 0.1.0 → 0.1.1"
install_010
DR_BEFORE="$(dr_of "$INSTALLED")"
serve "$E2E/out/appcast.xml" "$DMG011"
r="$(probe)"; echo "$r"
if wait_version 0.1.1 90; then
  pass "установлена 0.1.1 ($r)"
  fetched Mostik-0.1.1-test.dmg || bad ".dmg 0.1.1 не скачивался с нашего сервера"
  DR_AFTER="$(dr_of "$INSTALLED")"
  echo "до:    $DR_BEFORE"
  echo "после: $DR_AFTER"
  [ -n "$DR_BEFORE" ] && [ "$DR_BEFORE" = "$DR_AFTER" ] && pass "требование подписи одно и то же" || bad "требование подписи изменилось"
  q="$(xattr -r "$INSTALLED" 2>/dev/null | grep -c com.apple.quarantine || true)"
  [ "$q" = 0 ] && pass "карантина на установленной копии нет" || bad "карантин на $q файлах"
  codesign --verify --deep --strict "$INSTALLED" 2>&1 && pass "подпись установленной копии цела" || bad "codesign --verify"
else
  bad "обновление не установилось: $r, версия $(version_of "$INSTALLED")"
  tail -20 "$E2E/probe.log"
fi

step "Итог"
[ "$fail" = 0 ] && echo "Все проверки пройдены" || echo "Есть провалы — см. выше и $E2E (MOSTIK_E2E_KEEP=1)"
exit "$fail"
