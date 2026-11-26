#!/usr/bin/env bash
# Builds a universal, Developer ID–signed, notarized and stapled CleanTrash DMG.
#   scripts/release.sh [version] [build]
#   PUBLISH=1 NOTES_FILE=notes.md scripts/release.sh 1.1.0   → also tags, pushes and creates the GitHub release
# Also writes dist/appcast.xml (Sparkle feed, EdDSA-signed with the "cleantrash" key in the login keychain).
# The app reads it from …/releases/latest/download/appcast.xml, so it must be an asset of the newest release.
# Notarization uses an App Store Connect API key: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH
# (read from the environment, or from $ASC_ENV_FILE / ~/.config/babylua/asc.env).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="CleanTrash"
export APP_VERSION="${1:-${APP_VERSION:-1.0.0}}"
export BUILD_NUMBER="${2:-${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}}"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/$APP_NAME-$APP_VERSION.dmg"

ASC_ENV_FILE="${ASC_ENV_FILE:-$HOME/.config/babylua/asc.env}"
if [[ -z "${ASC_KEY_ID:-}" && -f "$ASC_ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ASC_ENV_FILE"
fi
: "${ASC_KEY_ID:?Falta ASC_KEY_ID}" "${ASC_ISSUER_ID:?Falta ASC_ISSUER_ID}" "${ASC_KEY_PATH:?Falta ASC_KEY_PATH}"

# Pin one Developer ID Application identity by hash (there may be duplicates in the keychain).
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2; exit}')}"
[[ -n "$IDENTITY" ]] || { echo "✗ No hay certificado Developer ID Application" >&2; exit 1; }

echo "→ $APP_NAME $APP_VERSION ($BUILD_NUMBER) · universal · $IDENTITY"
BUILD_ARCHS="arm64 x86_64" SKIP_SIGN=1 "$ROOT/scripts/build-app.sh" release

ENTITLEMENTS="$(mktemp -t cleantrash-ent).plist"
trap 'rm -f "$ENTITLEMENTS"' EXIT
cat > "$ENTITLEMENTS" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.automation.apple-events</key>
  <true/>
</dict>
</plist>
EOF

echo "→ Firmando (hardened runtime + timestamp)…"
# Sparkle: sign innermost code first (XPC services, Autoupdate, Updater.app), then the framework.
FW="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$FW" ]]; then
  SIGN=(codesign --force --options runtime --timestamp --sign "$IDENTITY")
  for xpc in "$FW"/Versions/B/XPCServices/*.xpc; do
    if [[ "$xpc" == *Downloader.xpc ]]; then
      "${SIGN[@]}" --preserve-metadata=entitlements "$xpc"
    else
      "${SIGN[@]}" "$xpc"
    fi
  done
  "${SIGN[@]}" "$FW/Versions/B/Autoupdate"
  "${SIGN[@]}" "$FW/Versions/B/Updater.app"
  "${SIGN[@]}" "$FW"
fi
if [[ -f "$APP/Contents/MacOS/cleantrash-hook" ]]; then
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/MacOS/cleantrash-hook"
fi
codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"

echo "→ Creando DMG…"
rm -f "$DMG"
# hdiutil -srcfolder (and create-dmg) fails with "Recurso ocupado" on this macOS, so build from a blank image.
# If diskimages is busy ("Simulators are still shutting down"), wait for the simulators and rerun.
RW="$(mktemp -u -t cleantrash-rw).dmg"
hdiutil create -size 120m -fs HFS+ -volname "$APP_NAME" -ov "$RW" >/dev/null
MNT="$(hdiutil attach "$RW" -nobrowse -noautoopen | awk -F'\t' '/\/Volumes\//{print $NF}')"
ditto "$APP" "$MNT/$APP_NAME.app"
ln -s /Applications "$MNT/Applications"
if [[ -f "$APP/Contents/Resources/AppIcon.icns" ]]; then
  cp "$APP/Contents/Resources/AppIcon.icns" "$MNT/.VolumeIcon.icns"
  SetFile -a C "$MNT" 2>/dev/null || true
fi
# Spotlight/Finder may still hold the fresh volume for a moment.
for _ in 1 2 3 4 5; do hdiutil detach "$MNT" >/dev/null 2>&1 && break; sleep 2; done
[[ -d "$MNT" ]] && hdiutil detach -force "$MNT" >/dev/null
hdiutil convert "$RW" -format UDZO -o "$DMG" -ov >/dev/null
rm -f "$RW"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

echo "→ Notarizando (puede tardar unos minutos)…"
xcrun notarytool submit "$DMG" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait

echo "→ Grapando ticket…"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

echo "→ Generando appcast…"
REPO_URL="https://github.com/crhistian-cornejo/cleantrash"
TAG="v$APP_VERSION"
SIGN_UPDATE="$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update"
ED_ATTRS="$("$SIGN_UPDATE" --account cleantrash "$DMG")"
PUB_DATE="$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")"
cat > "$DIST/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>CleanTrash</title>
    <link>$REPO_URL</link>
    <item>
      <title>CleanTrash $APP_VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$APP_VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$REPO_URL/releases/tag/$TAG</sparkle:fullReleaseNotesLink>
      <enclosure url="$REPO_URL/releases/download/$TAG/$APP_NAME-$APP_VERSION.dmg" $ED_ATTRS type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML

(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > SHA256SUMS.txt)
echo "✓ $DMG"
cat "$DIST/SHA256SUMS.txt"

if [[ -n "${PUBLISH:-}" ]]; then
  echo "→ Publicando $TAG en GitHub…"
  git -C "$ROOT" tag -a "$TAG" -m "$APP_NAME $APP_VERSION" 2>/dev/null || true
  git -C "$ROOT" push -q origin "$TAG"
  NOTES_ARGS=(--generate-notes)
  [[ -n "${NOTES_FILE:-}" ]] && NOTES_ARGS=(--notes-file "$NOTES_FILE")
  gh release create "$TAG" "$DMG" "$DIST/appcast.xml" "$DIST/SHA256SUMS.txt" \
    --repo crhistian-cornejo/cleantrash --title "$APP_NAME $APP_VERSION" --latest "${NOTES_ARGS[@]}"
fi
