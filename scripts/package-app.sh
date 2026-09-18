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
  <key>CFBundleIconFile</key><string>icon</string>
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

# A GUI-launched app inherits a minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin) that
# excludes Homebrew, so `brew` must be located by absolute path here.
BREW=""
for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew "$(command -v brew 2>/dev/null)"; do
  if [ -x "$candidate" ]; then BREW="$candidate"; break; fi
done

if [ -z "$BREW" ]; then
  osascript -e 'display dialog "Homebrew was not found.

OpenFOAM.app links against Homebrew-provided libraries. Install Homebrew from https://brew.sh, then run:

brew install open-mpi fftw scotch cgal boost gmp mpfr libomp" buttons {"OK"} with icon caution'
  exit 1
fi

MISSING=()
for pkg in open-mpi fftw scotch cgal boost gmp mpfr libomp; do
  "$BREW" --prefix "$pkg" >/dev/null 2>&1 || MISSING+=("$pkg")
done

if [ ${#MISSING[@]} -gt 0 ]; then
  osascript -e "display dialog \"Missing Homebrew packages: ${MISSING[*]}

Install with:
brew install ${MISSING[*]}\" buttons {\"OK\"} with icon caution"
  exit 1
fi

SESSION="$APP_RESOURCES/openfoam-session.sh"

osascript <<EOF
tell application "Terminal"
  activate
  do script "clear; BASH_SILENCE_DEPRECATION_WARNING=1 exec /bin/bash --rcfile '$SESSION' -i"
end tell
EOF
LAUNCHER

sed -i '' "s|__APP_NAME__|$APP_NAME|g" "$MACOS/launcher"
chmod +x "$MACOS/launcher"

# Interactive session rcfile: what the Terminal window actually runs.
cat > "$RES/openfoam-session.sh" <<'SESSION'
# Sourced as the rcfile of the interactive bash session opened by OpenFOAM.app.
_res="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# OpenFOAM's etc/bashrc is not written to be `set -e` safe, and probes for
# optional tooling (e.g. paraview) that may not be installed. errexit must stay
# off afterwards too: this shell is interactive, and any failing command (a typo,
# a solver erroring out) would otherwise close the user's window.
set +e
source "$_res/__APP_NAME__/etc/bashrc"

mkdir -p "$FOAM_RUN" 2>/dev/null
cd "$FOAM_RUN" 2>/dev/null || cd "$HOME"

_o=$'\e[38;5;208m'; _d=$'\e[2m'; _b=$'\e[1m'; _r=$'\e[0m'
printf '\n  %sOpenFOAM %s%s  %s· Apple Silicon native%s\n\n' \
  "$_b" "$WM_PROJECT_VERSION" "$_r" "$_d" "$_r"
printf '  %srun dir%s    %s  %s← you are here%s\n' "$_d" "$_r" "$FOAM_RUN" "$_d" "$_r"
printf '  %stutorials%s  %s\n\n' "$_d" "$_r" "$FOAM_TUTORIALS"
printf '  %sSolvers run inside a case directory%s%s, not here. Start one:%s\n' \
  "$_b" "$_r" "$_d" "$_r"
printf '    %scp -r $FOAM_TUTORIALS/incompressible/simpleFoam/pitzDaily .%s\n' "$_o" "$_r"
printf '    %scd pitzDaily && blockMesh && simpleFoam%s\n\n' "$_o" "$_r"
printf '  %scommon%s     blockMesh  snappyHexMesh  simpleFoam  decomposePar\n' "$_d" "$_r"
printf '  %s           foamInfo <name>%s  docs for any solver or utility\n\n' "$_d" "$_r"
unset _o _d _b _r _res

PS1='\[\e[38;5;208m\]OpenFOAM\[\e[0m\]:\[\e[1m\]\W\[\e[0m\]$ '
SESSION
sed -i '' "s|__APP_NAME__|$APP_NAME|g" "$RES/openfoam-session.sh"

# Build icon.icns from the committed 1024px master using only built-in macOS tools
ICON_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/icon/icon-1024.png"
if [ -f "$ICON_SRC" ]; then
  ICONSET="$(mktemp -d)/icon.iconset"
  mkdir -p "$ICONSET"
  for spec in "16:16x16" "32:16x16@2x" "32:32x32" "64:32x32@2x" \
              "128:128x128" "256:128x128@2x" "256:256x256" "512:256x256@2x" \
              "512:512x512" "1024:512x512@2x"; do
    px="${spec%%:*}"; name="${spec##*:}"
    sips -z "$px" "$px" "$ICON_SRC" --out "$ICONSET/icon_${name}.png" >/dev/null
  done
  iconutil --convert icns --output "$RES/icon.icns" "$ICONSET"
  echo "Icon built: $RES/icon.icns"
else
  echo "WARNING: $ICON_SRC not found; app will use the default icon."
fi

echo "Ad-hoc code-signing (required for Gatekeeper on Apple Silicon)..."
xattr -c -r "$APP"
codesign --force --deep --sign - "$APP"

echo "Packaged: $APP"
du -sh "$APP"
