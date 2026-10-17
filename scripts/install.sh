#!/bin/bash
# Mostik installer: curl -fsSL https://tonyprots.github.io/mostik/install.sh | bash
#
# Why a script and not just the .dmg: a .dmg downloaded by a browser or a messenger gets the
# quarantine flag, and macOS then blocks an app that is not notarized by Apple. curl sets no
# quarantine, so the app opens normally. Trust comes from the signature check below instead:
# the app must be signed by the pinned "Mostik Release" certificate (the same requirement macOS
# uses to keep Mostik's permissions across updates), or nothing is installed.
#
# Uses only tools that ship with macOS. Changes nothing outside the install folder.
# Environment (for testing): MOSTIK_FEED_URL, MOSTIK_INSTALL_DIR, MOSTIK_NO_LAUNCH=1.
set -euo pipefail

# Pinned in the script, not read from the feed: a tampered feed must not be able to change it.
# Must match MOSTIK_SIGN_CERT_SHA1 in release/release.conf (publish-release.sh checks this).
CERT_SHA1="BB63A4C6A7B9AF545DD12FAEEBD7B979DBD7C864"
BUNDLE_ID="app.mostik.mac"
REQUIREMENT="identifier \"${BUNDLE_ID}\" and certificate leaf = H\"${CERT_SHA1}\""

FEED_URL="${MOSTIK_FEED_URL:-https://tonyprots.github.io/mostik/appcast.xml}"
INSTALL_DIR="${MOSTIK_INSTALL_DIR:-/Applications}"

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

# --- The Mac -----------------------------------------------------------------------------------
[ "$(uname -s)" = "Darwin" ] || fail "Mostik runs on macOS only."
[ "$(uname -m)" = "arm64" ] || fail "Mostik needs a Mac with Apple silicon (M1 or newer)."

version_ge() {  # version_ge 14.6.1 14.2
  local IFS=.
  local -a a=($1) b=($2)
  local i
  for i in 0 1 2; do
    local x=${a[$i]:-0} y=${b[$i]:-0}
    [ "$x" -gt "$y" ] && return 0
    [ "$x" -lt "$y" ] && return 1
  done
  return 0
}

case "$FEED_URL" in
  https://*) ;;
  file://*) [ "${MOSTIK_INSTALL_TEST:-}" = "1" ] || fail "Feed must be https." ;;
  *) fail "Feed must be https." ;;
esac

TMP="$(mktemp -d -t mostik-install)"
MNT=""
cleanup() {
  [ -n "$MNT" ] && hdiutil detach -quiet "$MNT" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# --- Latest version from the update feed (the same one the app's updater reads) ----------------
say "Checking the latest version"
curl -fsSL --proto '=https,file' --retry 3 "$FEED_URL" -o "$TMP/appcast.xml" || fail "Could not download $FEED_URL"

# The newest release is the first <item>. Plain text tools: no xmllint dependency.
ITEM="$(awk '/<item>/{f=1} f{print} /<\/item>/{exit}' "$TMP/appcast.xml")"
[ -n "$ITEM" ] || fail "The update feed has no releases yet."
field() { printf '%s\n' "$ITEM" | sed -n "s|.*<$1>\(.*\)</$1>.*|\1|p" | head -1; }
VERSION="$(field 'sparkle:shortVersionString')"
MIN_OS="$(field 'sparkle:minimumSystemVersion')"
DMG_URL="$(printf '%s\n' "$ITEM" | sed -n 's|.*<enclosure url="\([^"]*\)".*|\1|p' | head -1)"
DMG_LEN="$(printf '%s\n' "$ITEM" | sed -n 's|.*<enclosure [^>]*length="\([0-9]*\)".*|\1|p' | head -1)"
[ -n "$VERSION" ] && [ -n "$DMG_URL" ] || fail "Could not read the latest release from the feed."

OS="$(sw_vers -productVersion)"
if [ -n "$MIN_OS" ] && ! version_ge "$OS" "$MIN_OS"; then
  fail "Mostik ${VERSION} needs macOS ${MIN_OS} or later; this Mac has ${OS}."
fi

case "$DMG_URL" in
  https://github.com/tonyprots/mostik/releases/download/*) ;;
  file://*) [ "${MOSTIK_INSTALL_TEST:-}" = "1" ] || fail "Unexpected download address: $DMG_URL" ;;
  *) fail "Unexpected download address: $DMG_URL" ;;
esac

# --- Download and check -------------------------------------------------------------------------
say "Downloading Mostik ${VERSION}"
curl -fL --proto '=https,file' --retry 3 --progress-bar "$DMG_URL" -o "$TMP/Mostik.dmg" || fail "Download failed."
if [ -n "$DMG_LEN" ]; then
  GOT="$(stat -f %z "$TMP/Mostik.dmg")"
  [ "$GOT" = "$DMG_LEN" ] || fail "Downloaded file has the wrong size (${GOT}, expected ${DMG_LEN})."
fi

MNT="$TMP/mnt"
mkdir -p "$MNT"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MNT" "$TMP/Mostik.dmg" || { MNT=""; fail "Could not open the disk image."; }
SRC="$MNT/Mostik.app"
[ -d "$SRC" ] || fail "The disk image has no Mostik.app."

say "Checking the signature"
codesign --verify --deep --strict "$SRC" 2>/dev/null || fail "Mostik.app is damaged or modified: signature check failed. Nothing was installed."
codesign --verify -R="$REQUIREMENT" "$SRC" 2>/dev/null || fail "Mostik.app is not signed by the Mostik Release certificate. Nothing was installed."

# --- Install ------------------------------------------------------------------------------------
DEST="$INSTALL_DIR/Mostik.app"
if pgrep -xq Mostik; then
  fail "Mostik is running. Quit it (menu bar icon → Quit) and run this command again."
fi
if [ -d "$DEST" ] && ! codesign --verify -R="$REQUIREMENT" "$DEST" 2>/dev/null; then
  say "Replacing an older Mostik signed differently: macOS will ask for its permissions once more."
fi
if [ ! -w "$INSTALL_DIR" ] || { [ -d "$DEST" ] && [ ! -w "$DEST" ]; }; then
  INSTALL_DIR="$HOME/Applications"
  DEST="$INSTALL_DIR/Mostik.app"
  mkdir -p "$INSTALL_DIR"
  say "No write access to /Applications, installing to ~/Applications"
fi

say "Installing to ${DEST}"
STAGE="$INSTALL_DIR/.Mostik.app.installing.$$"
rm -rf "$STAGE"
ditto "$SRC" "$STAGE"
codesign --verify --deep --strict -R="$REQUIREMENT" "$STAGE" 2>/dev/null || { rm -rf "$STAGE"; fail "Signature check failed after copying. Nothing was installed."; }
rm -rf "$DEST"
mv "$STAGE" "$DEST"

hdiutil detach -quiet "$MNT" 2>/dev/null || true
MNT=""

say "Mostik ${VERSION} is installed. It updates itself from now on."
if [ "${MOSTIK_NO_LAUNCH:-}" != "1" ]; then
  open "$DEST"
fi
