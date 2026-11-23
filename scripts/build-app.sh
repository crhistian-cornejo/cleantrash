#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="CleanTrash"
BUNDLE_ID="com.cleantrash.mac"
CONFIG="${1:-release}"
DIST_DIR="$ROOT/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

echo "→ Building $APP_NAME ($CONFIG) with Swift…"
cd "$ROOT"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "✗ Built binary not found at $BIN_PATH" >&2
  exit 1
fi

echo "→ Assembling ${APP_BUNDLE}..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Generate monochrome AppIcon.icns from assets/icon.svg if sips + iconutil exist
ICONSET="$DIST_DIR/AppIcon.iconset"
rm -rf "$ICONSET"
if command -v qlmanage >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1 && [[ -f "$ROOT/assets/icon.svg" ]]; then
  mkdir -p "$ICONSET"
  TMP_PNG_DIR="$DIST_DIR/.tmp-icon"
  rm -rf "$TMP_PNG_DIR"
  mkdir -p "$TMP_PNG_DIR"
  qlmanage -t -s 1024 -o "$TMP_PNG_DIR" "$ROOT/assets/icon.svg" >/dev/null 2>&1 || true
  BASE_PNG="$TMP_PNG_DIR/icon.svg.png"
  if [[ -f "$BASE_PNG" ]]; then
    for size in 16 32 128 256 512; do
      sips -z $size $size "$BASE_PNG" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
      sips -z $((size*2)) $((size*2)) "$BASE_PNG" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns" || true
  fi
  rm -rf "$TMP_PNG_DIR" "$ICONSET"
fi

cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>CleanTrash</string>
  <key>CFBundleExecutable</key>
  <string>CleanTrash</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>CleanTrash</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSDesktopFolderUsageDescription</key>
  <string>CleanTrash maps disk usage and finds large build artifacts.</string>
  <key>NSDocumentsFolderUsageDescription</key>
  <string>CleanTrash maps disk usage and finds large build artifacts.</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>CleanTrash pide a Finder vaciar la Papelera cuando hay elementos bloqueados o protegidos.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>CleanTrash detects old installers (.dmg/.pkg) and maps disk usage.</string>
</dict>
</plist>
EOF

SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application|Apple Development/ {print $2; exit}')"
fi

# Hardened runtime blocks Apple Events (Finder "empty trash") unless this entitlement is present.
ENTITLEMENTS="$(mktemp -t cleantrash-entitlements).plist"
cat > "$ENTITLEMENTS" <<ENTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.automation.apple-events</key>
  <true/>
</dict>
</plist>
ENTEOF

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "→ Signing ${APP_BUNDLE} with ${SIGN_IDENTITY}..."
  codesign --force --deep --options runtime --timestamp=none --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP_BUNDLE" >/dev/null 2>&1 \
    || codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE" >/dev/null 2>&1 \
    || codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true
else
  echo "→ Ad-hoc signing ${APP_BUNDLE}..."
  codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true
fi

rm -f "$ENTITLEMENTS"
echo "✓ Built ${APP_BUNDLE}"

INSTALL_TARGET="/Applications/${APP_NAME}.app"
for arg in "${@:2}"; do
  if [[ "$arg" == "--install" ]]; then
    echo "→ Installing to ${INSTALL_TARGET}..."
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    rm -rf "$INSTALL_TARGET"
    cp -R "$APP_BUNDLE" "$INSTALL_TARGET"
    APP_BUNDLE="$INSTALL_TARGET"
    echo "✓ Installed ${INSTALL_TARGET}"
  fi
done

for arg in "${@:2}"; do
  if [[ "$arg" == "--run" ]]; then
    echo "→ Launching ${APP_NAME}..."
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    sleep 0.3
    open "$APP_BUNDLE"
  fi
done
