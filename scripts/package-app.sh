#!/bin/bash -e
# Package a built OpenFOAM source tree into a double-clickable .app launcher.
#
# Required env vars:
#   FOAM_SRC_DIR   Built OpenFOAM source root (e.g. /Volumes/OpenFOAM-v2606/OpenFOAM-v2606)
#   APP_NAME       e.g. OpenFOAM-v2606
#   OUTPUT_DIR     Where to place APP_NAME.app

: "${FOAM_SRC_DIR:?}"
: "${APP_NAME:?}"
: "${OUTPUT_DIR:?}"

APP="$OUTPUT_DIR/$APP_NAME.app"
RES="$APP/Contents/Resources"
MACOS="$APP/Contents/MacOS"

rm -rf "$APP"
mkdir -p "$RES" "$MACOS"

echo "Copying built OpenFOAM tree (excluding intermediate build objects and .git)..."
rsync -a \
  --exclude='.git' \
  --exclude='/build' \
  "$FOAM_SRC_DIR"/ "$RES/$APP_NAME/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>org.longhornracing.solar.$APP_NAME</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleExecutable</key><string>launcher</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

cat > "$MACOS/launcher" <<'LAUNCHER'
#!/bin/bash
# Opens a Terminal window with the bundled OpenFOAM environment sourced.
APP_RESOURCES="$(cd "$(dirname "$0")/../Resources" && pwd)"
FOAM_DIR="$APP_RESOURCES/__APP_NAME__"

MISSING=()
for pkg in open-mpi fftw scotch cgal boost gmp mpfr libomp; do
  brew --prefix "$pkg" >/dev/null 2>&1 || MISSING+=("$pkg")
done

if [ ${#MISSING[@]} -gt 0 ]; then
  osascript -e "display dialog \"Missing Homebrew packages: ${MISSING[*]}\n\nInstall with:\nbrew install ${MISSING[*]}\" buttons {\"OK\"} with icon caution"
  exit 1
fi

osascript <<EOF
tell application "Terminal"
  activate
  do script "source '$FOAM_DIR/etc/bashrc' && echo 'OpenFOAM environment loaded (WM_PROJECT_DIR='\$WM_PROJECT_DIR')' && exec \$SHELL -l"
end tell
EOF
LAUNCHER

sed -i '' "s|__APP_NAME__|$APP_NAME|g" "$MACOS/launcher"
chmod +x "$MACOS/launcher"

echo "Ad-hoc code-signing (required for Gatekeeper on Apple Silicon)..."
xattr -c -r "$APP"
codesign --force --deep --sign - "$APP"

echo "Packaged: $APP"
du -sh "$APP"
