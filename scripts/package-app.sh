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

# Optionally bundle a prebuilt ParaView.app (PARAVIEW_APP=/path/to/ParaView-x.y.z.app).
# Only the front-end tools are exposed on PATH via a shim dir: ParaView ships its
# own MPICH mpiexec, which would shadow OpenFOAM's OpenMPI and break parallel runs.
if [ -n "${PARAVIEW_APP:-}" ] && [ -d "$PARAVIEW_APP" ]; then
  echo "Bundling ParaView from $PARAVIEW_APP ..."
  rsync -a "$PARAVIEW_APP"/ "$RES/ParaView.app/"
  mkdir -p "$RES/pvbin"
  for tool in paraview pvpython pvbatch pvserver; do
    if [ -x "$RES/ParaView.app/Contents/MacOS/$tool" ]; then
      ln -sf "../ParaView.app/Contents/MacOS/$tool" "$RES/pvbin/$tool"
    elif [ -x "$RES/ParaView.app/Contents/bin/$tool" ]; then
      ln -sf "../ParaView.app/Contents/bin/$tool" "$RES/pvbin/$tool"
    fi
  done
  # ParaView requires the user to press Apply, pick a timestep and choose an
  # array before anything appears. foamView does all three for the case in $PWD.
  cat > "$RES/foamview_startup.py" <<'PVSTARTUP'
"""ParaView startup script: load the OpenFOAM case in $FOAMVIEW_CASE, apply it,
jump to the last time, and colour by velocity (or the first field found)."""
import os
from paraview.simple import *

case = os.environ.get("FOAMVIEW_CASE", os.getcwd())
stub = os.path.join(case, os.path.basename(case) + ".foam")
open(stub, "a").close()

r = OpenFOAMReader(registrationName=os.path.basename(stub), FileName=stub)
r.MeshRegions = ["internalMesh"]
r.UpdatePipeline()

view = GetActiveViewOrCreate("RenderView")
times = list(r.TimestepValues or [])
if times:
    GetTimeKeeper().Time = times[-1]
    view.ViewTime = times[-1]
    scene = GetAnimationScene()
    scene.UpdateAnimationUsingDataTimeSteps()
    scene.AnimationTime = times[-1]
    r.UpdatePipeline(times[-1])

disp = Show(r, view)          # the equivalent of pressing Apply

arrays = {}
for i in range(r.CellData.GetNumberOfArrays()):
    a = r.CellData.GetArray(i)
    arrays[a.Name] = a.GetNumberOfComponents()
field = "U" if "U" in arrays else next(iter(arrays), None)
if field:
    ColorBy(disp, ("CELLS", field, "Magnitude") if arrays[field] > 1 else ("CELLS", field))
    disp.RescaleTransferFunctionToDataRange(True, False)
    disp.SetScalarBarVisibility(view, True)

view.InteractionMode = "2D"
ResetCamera()
Render()
print("foamView: %s  t=%s  field=%s" % (case, times[-1] if times else "n/a", field))
PVSTARTUP

  cat > "$RES/pvbin/foamView" <<'FOAMVIEW'
#!/bin/bash
# Open the OpenFOAM case in the current directory in ParaView: applied, at the
# latest time, coloured by U. Plain `paraFoam -builtin` leaves all three to you.
_res="$(cd "$(dirname "$0")/.." && pwd)"
if [ ! -d system ] || [ ! -d constant ]; then
  echo "foamView: no OpenFOAM case here (expected system/ and constant/)." >&2
  echo "          cd into a case directory first." >&2
  exit 1
fi
FOAMVIEW_CASE="$PWD" exec "$_res/pvbin/paraview" --script="$_res/foamview_startup.py" "$@"
FOAMVIEW
  chmod +x "$RES/pvbin/foamView"

  echo "ParaView tools exposed: $(ls "$RES/pvbin" | tr '\n' ' ')"
else
  echo "No PARAVIEW_APP given; building without bundled ParaView."
fi

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

# Bundled ParaView front-end tools, if present. Deliberately a shim dir holding
# only paraview/pvpython/pvbatch/pvserver — ParaView's own dirs also contain an
# MPICH mpiexec that must not shadow OpenFOAM's OpenMPI.
if [ -d "$_res/pvbin" ]; then
  PATH="$_res/pvbin:$PATH"
  export PATH
fi

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
printf '  %s           foamInfo <name>%s  docs for any solver or utility\n' "$_d" "$_r"
if command -v foamView >/dev/null 2>&1; then
  printf '  %sview%s       %sfoamView%s  open this case in ParaView, applied, at the last time\n' \
    "$_d" "$_r" "$_o" "$_r"
fi
printf '\n'
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
