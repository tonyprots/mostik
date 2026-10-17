#!/bin/bash
# Публикация выпуска Mostik: .dmg — в GitHub Release, лента — в ветку gh-pages (GitHub Pages).
# Отдельно от release.sh: тот собирает и подписывает, этот выкладывает. Пошагово — docs/release.md.
#
#   scripts/publish-release.sh <версия>             — сухой прогон (по умолчанию): все проверки, без записи
#   scripts/publish-release.sh <версия> --publish   — то же, затем вопрос в терминале и публикация
#
# Порядок публикации: сначала Release с .dmg, потом лента — лента не должна указывать на файл, которого нет.
# Подтверждение — набрать версию с клавиатуры (/dev/tty); без терминала публикации нет.
#
# Переменные:
#   MOSTIK_RELEASE_OUT  папка выпуска release.sh (по умолчанию release-out/)
#   SPARKLE_ACCOUNT     учётка ключа EdDSA в связке ключей (по умолчанию app.mostik.mac)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

die() { printf 'publish-release.sh: %s\n' "$*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }
ok() { printf '  ✓ %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }

VERSION="${1:-}"
[ -n "$VERSION" ] || die "использование: scripts/publish-release.sh <версия> [--publish]"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "версия — X.Y.Z, получено «${VERSION}»"
PUBLISH=0
case "${2:-}" in
  "") ;;
  --publish) PUBLISH=1 ;;
  *) die "неизвестный аргумент ${2}" ;;
esac

conf() {
  local line
  line="$(grep -E "^$1=" "$ROOT/release/release.conf" | tail -1)" || true
  line="${line#*=}"; line="${line%\"}"; line="${line#\"}"
  printf '%s' "$line"
}
FEED_URL="$(conf MOSTIK_FEED_URL)"
REPO="$(conf MOSTIK_GITHUB_REPO)"
OUT="${MOSTIK_RELEASE_OUT:-$ROOT/release-out}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-app.mostik.mac}"
SIGN_UPDATE="$ROOT/vendor/sparkle/current/bin/sign_update"
DMG="$OUT/Mostik-$VERSION.dmg"
FEED="$OUT/appcast.xml"
TAG="v$VERSION"
DMG_URL="https://github.com/$REPO/releases/download/$TAG/$(basename "$DMG")"

[ "$PUBLISH" = 1 ] && echo "Режим: ПУБЛИКАЦИЯ (после подтверждения)" || echo "Режим: сухой прогон — ничего не публикуется"
echo "Репозиторий: $REPO, тег $TAG, лента $FEED_URL"

# --- 1. Файлы выпуска и подписи EdDSA.
step "Файлы выпуска"
[ -f "$DMG" ] || die "нет $DMG — сначала scripts/release.sh (VERSION=$VERSION)"
[ -f "$DMG.sparkle-signature" ] || die "нет $DMG.sparkle-signature"
[ -f "$FEED" ] || die "нет $FEED"
[ -x "$SIGN_UPDATE" ] || die "нет $SIGN_UPDATE (vendor/sparkle)"
ok "$(basename "$DMG"), $(du -h "$DMG" | cut -f1)"

# Установщик одной командой лежит рядом с лентой; отпечаток сертификата в нём — тот же, что в конфиге.
INSTALLER="$ROOT/scripts/install.sh"
[ -f "$INSTALLER" ] || die "нет $INSTALLER"
CERT_SHA1="$(conf MOSTIK_SIGN_CERT_SHA1)"
grep -q "^CERT_SHA1=\"$CERT_SHA1\"$" "$INSTALLER" || die "отпечаток сертификата в scripts/install.sh не совпадает с release/release.conf"
grep -q "^FEED_URL=\"\${MOSTIK_FEED_URL:-$FEED_URL}\"$" "$INSTALLER" || die "адрес ленты в scripts/install.sh не совпадает с release/release.conf"
bash -n "$INSTALLER" || die "scripts/install.sh: синтаксическая ошибка"
ok "install.sh: тот же сертификат и та же лента"

SIG_LINE="$(cat "$DMG.sparkle-signature")"
ED_SIG="$(printf '%s' "$SIG_LINE" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
[ -n "$ED_SIG" ] || die "в $DMG.sparkle-signature нет sparkle:edSignature"
"$SIGN_UPDATE" --verify --account "$SPARKLE_ACCOUNT" "$DMG" "$ED_SIG" >/dev/null \
  || die ".dmg не проходит проверку EdDSA ключом «${SPARKLE_ACCOUNT}» — пересоберите release.sh"
ok "подпись EdDSA .dmg"
"$SIGN_UPDATE" --verify --account "$SPARKLE_ACCOUNT" "$FEED" >/dev/null \
  || die "лента не проходит проверку EdDSA — её правили после release.sh? Пересоберите"
ok "подпись EdDSA ленты"

# --- 2. Запись версии в ленте совпадает с файлом и с адресом Release.
step "Лента"
ITEM_JSON="$(python3 -I - "$FEED" "$VERSION" <<'PY'
import json, sys
import xml.etree.ElementTree as ET
S = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
M = "{urn:app.mostik:appcast}"
root = ET.parse(sys.argv[1]).getroot()
for item in root.iter("item"):
    if (item.findtext(f"{S}shortVersionString") or "") == sys.argv[2]:
        enc = item.find("enclosure")
        print(json.dumps({
            "url": enc.get("url"), "length": enc.get("length"), "sig": enc.get(f"{S}edSignature"),
            "dr": item.findtext(f"{M}designatedRequirement") or "",
            "min": item.findtext(f"{S}minimumSystemVersion") or "",
        }))
        break
PY
)"
[ -n "$ITEM_JSON" ] || die "в ленте нет записи версии $VERSION"
field() { python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$ITEM_JSON" "$1"; }
[ "$(field url)" = "$DMG_URL" ] || die "адрес .dmg в ленте «$(field url)», а Release будет «${DMG_URL}»"
[ "$(field length)" = "$(stat -f %z "$DMG")" ] || die "длина в ленте $(field length) ≠ размер .dmg $(stat -f %z "$DMG")"
[ "$(field sig)" = "$ED_SIG" ] || die "подпись в ленте не та, что в $DMG.sparkle-signature"
[ -n "$(field min)" ] || die "в ленте нет sparkle:minimumSystemVersion"
FEED_DR="$(field dr)"
[ -n "$FEED_DR" ] || die "в ленте нет mostik:designatedRequirement — установленные копии не поставят обновление"
ok "запись $VERSION: адрес, длина, подпись, macOS от $(field min)"

# --- 3. Приложение в образе подписано так, как обещает лента, и не ad-hoc.
step "Приложение в образе"
MNT="$(mktemp -d /tmp/mostik-publish.XXXXXX)"
hdiutil attach -quiet -readonly -noverify -noautoopen -nobrowse -mountpoint "$MNT" "$DMG"
trap 'hdiutil detach -quiet "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true' EXIT
APP_DR="$(codesign -d -r- "$MNT/Mostik.app" 2>&1 | grep '^designated => ' || true)"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MNT/Mostik.app/Contents/Info.plist")"
APP_FEED="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$MNT/Mostik.app/Contents/Info.plist")"
codesign --verify --deep --strict "$MNT/Mostik.app" || die "подпись Mostik.app в образе не проходит codesign --verify"
hdiutil detach -quiet "$MNT"; rmdir "$MNT" 2>/dev/null || true
trap - EXIT
[ "$APP_VERSION" = "$VERSION" ] || die "в образе Mostik $APP_VERSION, а публикуем $VERSION"
[ "$APP_FEED" = "$FEED_URL" ] || die "SUFeedURL в образе «${APP_FEED}», а в release.conf «${FEED_URL}»"
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
[ "$(lower "$APP_DR")" = "$(lower "$FEED_DR")" ] || die "требование подписи приложения «${APP_DR}» ≠ ленте «${FEED_DR}»"
case "$APP_DR" in
  *"certificate leaf"*|*"anchor apple"*) ;;
  *) die "требование подписи «${APP_DR}» — ad-hoc; такой выпуск не публикуется" ;;
esac
ok "Mostik $APP_VERSION, $APP_DR"

# --- 4. GitHub: вход, репозиторий, тега ещё нет, Pages.
step "GitHub"
command -v gh >/dev/null || die "нет gh (brew install gh)"
gh auth status >/dev/null 2>&1 || die "gh не вошёл: gh auth login"
gh repo view "$REPO" --json name >/dev/null 2>&1 || die "репозитория $REPO нет или нет доступа"
ok "репозиторий $REPO"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  die "Release $TAG уже есть — выпуск не перезаписывается. Новая сборка — новая версия"
fi
ok "Release $TAG ещё нет"
PAGES="$(gh api "repos/$REPO/pages" --jq '.source.branch + " " + .source.path' 2>/dev/null || true)"
if [ "$PAGES" = "gh-pages /" ]; then
  ok "GitHub Pages: ветка gh-pages, корень"
else
  warn "GitHub Pages не включены на gh-pages / (сейчас: «${PAGES:-нет}»). Лента будет в ветке, но по адресу её не будет:"
  warn "Settings → Pages → Deploy from a branch → gh-pages, / (root). docs/release.md, «Публикация»"
fi

# --- 5. Текст страницы выпуска: первая установка + раздел журнала изменений.
NOTES="$(mktemp /tmp/mostik-notes.XXXXXX)"
trap 'rm -f "$NOTES"' EXIT
sed "s/{{VERSION}}/$VERSION/g" "$ROOT/release/release-notes.md" > "$NOTES"
python3 -I - "$ROOT/CHANGELOG.md" "$VERSION" >> "$NOTES" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(rf"^## \[?{re.escape(sys.argv[2])}\]?.*?$(.*?)(?=^## |\Z)", text, re.M | re.S)
if m:
    print("\n## Что нового\n" + m.group(1).strip())
PY
step "Страница выпуска (текст)"
sed 's/^/  | /' "$NOTES"

# --- 6. Публикация.
step "План"
echo "  1. gh release create $TAG $(basename "$DMG") --repo $REPO --title \"Mostik $VERSION\""
echo "  2. дождаться, пока $DMG_URL отдаётся"
echo "  3. appcast.xml и install.sh → ветка gh-pages репозитория $REPO, коммит «Лента: Mostik ${VERSION}», push"
echo "  4. дождаться, пока $FEED_URL отдаёт версию $VERSION"
if [ "$PUBLISH" != 1 ]; then
  echo
  echo "Сухой прогон: всё проверено, ничего не опубликовано. Публикация: scripts/publish-release.sh $VERSION --publish"
  exit 0
fi

[ -r /dev/tty ] || die "нет терминала для подтверждения — публикация только вручную"
printf '\nОпубликовать Mostik %s в %s? Наберите версию (%s): ' "$VERSION" "$REPO" "$VERSION" > /dev/tty
read -r answer < /dev/tty
[ "$answer" = "$VERSION" ] || die "не подтверждено — ничего не опубликовано"

step "1. GitHub Release"
gh release create "$TAG" "$DMG" --repo "$REPO" --title "Mostik $VERSION" --notes-file "$NOTES"

step "2. .dmg по адресу"
for _ in $(seq 1 30); do
  curl -sfIL -o /dev/null "$DMG_URL" && break
  sleep 2
done
curl -sfIL -o /dev/null "$DMG_URL" || die "$DMG_URL не отдаётся — лента не выкладывается. Release создан; проверьте и запустите шаг 3 снова"
ok "$DMG_URL"

step "3. Лента в gh-pages"
PAGES_DIR="$(mktemp -d /tmp/mostik-pages.XXXXXX)"
if git ls-remote --exit-code --heads "https://github.com/$REPO.git" gh-pages >/dev/null 2>&1; then
  gh repo clone "$REPO" "$PAGES_DIR" -- --branch gh-pages --depth 1 --quiet
else
  git -C "$PAGES_DIR" init -q -b gh-pages
  git -C "$PAGES_DIR" remote add origin "https://github.com/$REPO.git"
fi
cp "$FEED" "$PAGES_DIR/appcast.xml"
cp "$INSTALLER" "$PAGES_DIR/install.sh"
touch "$PAGES_DIR/.nojekyll"  # Pages отдаёт файлы как есть, без Jekyll
git -C "$PAGES_DIR" add appcast.xml install.sh .nojekyll
git -C "$PAGES_DIR" commit -q -m "Лента: Mostik $VERSION"
gh auth setup-git >/dev/null 2>&1 || true
git -C "$PAGES_DIR" push -q origin gh-pages
rm -rf "$PAGES_DIR"
ok "gh-pages обновлена"

step "4. Лента по адресу"
for _ in $(seq 1 36); do
  if curl -sfL "$FEED_URL" | grep -q "<sparkle:shortVersionString>$VERSION<"; then
    ok "$FEED_URL отдаёт $VERSION"
    echo; echo "Опубликовано: Mostik $VERSION. Установленные копии увидят его при следующей проверке (раз в день)."
    exit 0
  fi
  sleep 5
done
warn "$FEED_URL пока не отдаёт $VERSION — Pages собирается до нескольких минут; проверьте позже: curl -sL $FEED_URL"
