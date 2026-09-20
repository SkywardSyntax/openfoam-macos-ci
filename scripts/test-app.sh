#!/bin/bash
# Acceptance tests for a packaged OpenFOAM.app.
#
#   APP=/path/to/OpenFOAM-v2606.app scripts/test-app.sh
#
# Exits non-zero if any required check fails. Known limitations are reported
# but do not fail the run.
#
# Deliberately a script rather than inline workflow YAML: embedded in a
# `bash -c "..."` inside a YAML block scalar, every quote has to survive two
# levels of escaping, and getting that wrong cost several CI runs. Here it is
# ordinary bash that can be run by hand against any .app, including one a user
# has already installed:
#
#   APP=/Applications/OpenFOAM-v2606.app scripts/test-app.sh
#
# Written for bash 3.2, which is what macOS ships as /bin/bash.

: "${APP:?set APP to the .app bundle to test}"
APP="$(cd "$APP" && pwd)"
RES="$APP/Contents/Resources"
APP_NAME="${APP_NAME:-$(basename "$APP" .app)}"
FOAM="$RES/$APP_NAME"
DEPS="$RES/deps"

PASS=0; FAIL=0; KNOWN=0
FAILED_NAMES=""

ok()    { PASS=$((PASS+1));  printf '  ok      %s\n' "$1"; }
bad()   { FAIL=$((FAIL+1));  FAILED_NAMES="$FAILED_NAMES
    $1"; printf '  NOT OK  %s\n' "$1"; [ -n "${2:-}" ] && printf '          %s\n' "$2"; return 0; }
known() { KNOWN=$((KNOWN+1)); printf '  known   %s\n' "$1"; [ -n "${2:-}" ] && printf '          %s\n' "$2"; return 0; }
section() { printf '\n=== %s ===\n' "$1"; }

# check <name> <command...>  -- passes if the command exits 0
check() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi
}

printf 'Testing %s\n' "$APP"
printf 'Homebrew present on this machine: %s\n' \
  "$([ -d /opt/homebrew ] && echo 'YES (self-containment claims are weaker)' || echo 'no')"

# ---------------------------------------------------------------------------
section "1. Bundle structure"
# ---------------------------------------------------------------------------
check "Info.plist exists"            test -f "$APP/Contents/Info.plist"
check "Info.plist is valid"          plutil -lint "$APP/Contents/Info.plist"
check "launcher is executable"       test -x "$APP/Contents/MacOS/launcher"
check "icon.icns present"            test -f "$RES/icon.icns"
check "session rcfile present"       test -f "$RES/openfoam-session.sh"
check "OpenFOAM tree present"        test -d "$FOAM/etc"
check "bundled deps present"         test -d "$DEPS/lib"
check "bundled headers present"      test -d "$DEPS/include"
check "ParaView bundled"             test -d "$RES/ParaView.app"
check "pvbin shim dir present"       test -d "$RES/pvbin"
check "foamView helper executable"   test -x "$RES/pvbin/foamView"
check "source tree shipped"          test -d "$FOAM/src"
check "tutorials shipped"            test -d "$FOAM/tutorials"
check "wmake toolchain shipped"      test -x "$FOAM/wmake/wmake"
check "case-sensitive src.dmg shipped" test -f "$RES/src.dmg"
grep -q '^LIB_SRC *?=' "$FOAM/wmake/makefiles/general" 2>/dev/null \
  && ok "LIB_SRC is environment-overridable" \
  || bad "LIB_SRC is environment-overridable" "wmake/makefiles/general still uses a plain ="

# The plain src/ inside the app went through a case-insensitive filesystem, so
# one file of each colliding pair is gone. The image must not have that damage.
NINST="$(ls "$FOAM/src/OpenFOAM/db/Time/instant/" 2>/dev/null | wc -l | tr -d ' ')"
printf '  ...in-app src/ db/Time/instant has %s entries (upstream has 5; case-folded)\n' "${NINST:-0}"

# ---------------------------------------------------------------------------
section "2. Self-containment"
# ---------------------------------------------------------------------------
LEFTOVER="$(mktemp)"
find "$FOAM/platforms" "$DEPS" -type f 2>/dev/null | while read -r f; do
  refs="$(otool -L "$f" 2>/dev/null | tail -n +2 | sed 's/^[[:space:]]*//; s/ (compatibility.*//' | grep '^/opt/homebrew')"
  if [ -n "$refs" ]; then echo "$f" >> "$LEFTOVER"; fi
done
if [ -s "$LEFTOVER" ]; then
  bad "no Mach-O references /opt/homebrew" "$(wc -l < "$LEFTOVER" | tr -d ' ') files still do, e.g. $(head -1 "$LEFTOVER")"
else
  ok "no Mach-O references /opt/homebrew"
fi
rm -f "$LEFTOVER"

# Signatures: install_name_tool invalidates them, and Apple Silicon refuses to
# run an unsigned binary, so this is what catches a missed re-sign.
SIGBAD=0; SIGBAD_NAMES=""
for f in "$DEPS"/lib/*.dylib "$DEPS"/bin/* "$FOAM"/platforms/*/bin/simpleFoam \
         "$FOAM"/platforms/*/lib/libscotchDecomp.dylib; do
  [ -f "$f" ] && [ ! -L "$f" ] || continue
  # Only Mach-O files carry signatures. deps/bin also holds open-mpi's shell
  # and python wrappers, which rsync -aL turned from symlinks into real files.
  file -b "$f" 2>/dev/null | grep -q 'Mach-O' || continue
  if ! codesign --verify "$f" >/dev/null 2>&1; then
    SIGBAD=$((SIGBAD+1)); SIGBAD_NAMES="$SIGBAD_NAMES $(basename "$f")"
  fi
done
[ "$SIGBAD" -eq 0 ] && ok "code signatures valid on bundled binaries" \
                    || bad "code signatures valid on bundled binaries" "$SIGBAD invalid:$SIGBAD_NAMES"

check "mpirun bundled"               test -x "$DEPS/bin/mpirun"
check "prted bundled (Open MPI 5)"   test -x "$DEPS/bin/prted"

# ---------------------------------------------------------------------------
section "3. Session environment"
# ---------------------------------------------------------------------------
ENVFILE="$(mktemp)"
bash -lc "
  set +e
  source '$RES/openfoam-session.sh' >/dev/null 2>&1
  {
    echo \"FOAM_MPI=\$FOAM_MPI\"
    echo \"WM_PROJECT_DIR=\$WM_PROJECT_DIR\"
    echo \"MPI_ARCH_PATH=\$MPI_ARCH_PATH\"
    echo \"DYLD1=\$(printf %s \"\$DYLD_LIBRARY_PATH\" | cut -d: -f1)\"
    echo \"DYLD_BREW=\$(printf %s \"\$DYLD_LIBRARY_PATH\" | tr ':' '\n' | grep -c homebrew)\"
    echo \"PATH_BREW=\$(printf %s \"\$PATH\" | tr ':' '\n' | grep -c homebrew)\"
    echo \"MPIRUN=\$(command -v mpirun)\"
    echo \"PARAVIEW=\$(command -v paraview)\"
    echo \"FOAMVIEW=\$(command -v foamView)\"
    echo \"LIB_SRC=\$LIB_SRC\"
    echo \"MPIEXEC=\$(command -v mpiexec)\"
  } > '$ENVFILE'
" >/dev/null 2>&1
getenvv() { grep "^$1=" "$ENVFILE" 2>/dev/null | head -1 | cut -d= -f2-; }

[ "$(getenvv FOAM_MPI)" = "sys-openmpi" ] \
  && ok "FOAM_MPI resolves (sys-openmpi)" \
  || bad "FOAM_MPI resolves (sys-openmpi)" "got '$(getenvv FOAM_MPI)'"

case "$(getenvv WM_PROJECT_DIR)" in "$APP"*) ok "WM_PROJECT_DIR points inside the app";;
  *) bad "WM_PROJECT_DIR points inside the app" "got '$(getenvv WM_PROJECT_DIR)'";; esac
case "$(getenvv MPI_ARCH_PATH)" in "$APP"*) ok "MPI_ARCH_PATH points inside the app";;
  *) bad "MPI_ARCH_PATH points inside the app" "got '$(getenvv MPI_ARCH_PATH)'";; esac
case "$(getenvv DYLD1)" in "$APP"*) ok "deps/lib is first on DYLD_LIBRARY_PATH";;
  *) bad "deps/lib is first on DYLD_LIBRARY_PATH" "got '$(getenvv DYLD1)'";; esac
[ "$(getenvv DYLD_BREW)" = "0" ] && ok "no Homebrew on DYLD_LIBRARY_PATH" \
  || bad "no Homebrew on DYLD_LIBRARY_PATH" "$(getenvv DYLD_BREW) entries"
[ "$(getenvv PATH_BREW)" = "0" ] && ok "no Homebrew on PATH" \
  || known "no Homebrew on PATH" "$(getenvv PATH_BREW) entries (harmless if brew is installed here)"
case "$(getenvv MPIRUN)" in "$APP"*) ok "mpirun resolves into the bundle";;
  *) bad "mpirun resolves into the bundle" "got '$(getenvv MPIRUN)'";; esac
case "$(getenvv PARAVIEW)" in "$APP"*) ok "paraview resolves into the bundle";;
  *) bad "paraview resolves into the bundle" "got '$(getenvv PARAVIEW)'";; esac
[ -n "$(getenvv FOAMVIEW)" ] && ok "foamView on PATH" || bad "foamView on PATH"
case "$(getenvv LIB_SRC)" in
  "$FOAM/src") bad "LIB_SRC points at the case-sensitive image" "still the case-folded in-app copy";;
  "")          bad "LIB_SRC points at the case-sensitive image" "unset -- src.dmg did not mount";;
  *)           ok "LIB_SRC points at the case-sensitive image";;
esac
LS="$(getenvv LIB_SRC)"
if [ -n "$LS" ] && [ -d "$LS/OpenFOAM/db/Time/instant" ]; then
  n="$(ls "$LS/OpenFOAM/db/Time/instant/" | wc -l | tr -d ' ')"
  [ "$n" -ge 5 ] && ok "case-colliding sources intact in the image ($n entries)" \
                 || bad "case-colliding sources intact in the image" "only $n entries"
else
  bad "case-colliding sources intact in the image" "LIB_SRC/OpenFOAM not readable"
fi
# ParaView ships an MPICH mpiexec that must never shadow OpenFOAM's OpenMPI.
case "$(getenvv MPIEXEC)" in
  *ParaView.app*) bad "ParaView MPICH does not shadow OpenMPI" "mpiexec=$(getenvv MPIEXEC)";;
  *) ok "ParaView MPICH does not shadow OpenMPI";;
esac
rm -f "$ENVFILE"

# ---------------------------------------------------------------------------
section "4. Shipped executables"
# ---------------------------------------------------------------------------
BIN="$(echo "$FOAM"/platforms/*/bin)"
present() { [ -x "$BIN/$1" ] && ok "$2: $1" || bad "$2: $1"; }

for s in simpleFoam pimpleFoam potentialFoam pisoFoam icoFoam rhoSimpleFoam \
         rhoPimpleFoam interFoam buoyantSimpleFoam chtMultiRegionFoam \
         scalarTransportFoam laplacianFoam sonicFoam XiFoam reactingFoam \
         overPimpleDyMFoam SRFPimpleFoam; do
  present "$s" "solver"
done
for m in blockMesh snappyHexMesh checkMesh extrudeMesh surfaceFeatureExtract \
         topoSet createPatch refineMesh; do
  present "$m" "meshing"
done
for p in decomposePar reconstructPar reconstructParMesh redistributePar; do
  present "$p" "parallel"
done
for u in postProcess foamDictionary transformPoints setFields mapFields \
         foamListTimes foamFormatConvert; do
  present "$u" "utility"
done
# These ship as scripts in $FOAM/bin rather than compiled into platforms/*/bin.
for u in foamJob foamLog foamNewCase foamCloneCase paraFoam foamSystemCheck; do
  [ -x "$FOAM/bin/$u" ] && ok "script: $u" || bad "script: $u"
done
# Anything the session banner advertises must actually exist, or the first
# thing a new user types fails. foamInfo was advertised for months and is not
# shipped in v2606 at all.
for b in blockMesh snappyHexMesh simpleFoam decomposePar; do
  [ -x "$BIN/$b" ] && ok "banner command: $b" || bad "banner command: $b"
done
if grep -q 'foamInfo' "$RES/openfoam-session.sh" 2>/dev/null; then
  [ -x "$BIN/foamInfo" ] || [ -x "$FOAM/bin/foamInfo" ] \
    && ok "banner command: foamInfo" \
    || bad "banner command: foamInfo" "advertised in the banner but not shipped"
fi
for c in fluentMeshToFoam gmshToFoam ideasUnvToFoam star4ToFoam plot3dToFoam; do
  present "$c" "converter"
done
for w in wmake wclean wmakeLnInclude wmakeCollect; do
  [ -x "$FOAM/wmake/$w" ] && ok "wmake tool: $w" || bad "wmake tool: $w"
done
printf '  ...%s executables in the bundle\n' "$(ls "$BIN" | wc -l | tr -d ' ')"

# ---------------------------------------------------------------------------
section "5. Runtime library resolution"
# ---------------------------------------------------------------------------
# Static install names being right is not sufficient: DYLD_LIBRARY_PATH takes
# precedence over @rpath, and a stale Homebrew entry there silently loaded a
# different libmpi. This checks what dyld actually maps.
# Each probe binary is one that actually pulls the library in: simpleFoam
# loads Pstream (MPI), foamyHexMesh links gmp/mpfr. scotch and fftw are
# covered by the functional decomposition tests below.
RESOLVED="$(mktemp)"
for probe in simpleFoam foamyHexMesh; do
  bash -c "
    set +e
    source '$RES/openfoam-session.sh' >/dev/null 2>&1
    DYLD_PRINT_LIBRARIES=1 '$BIN/$probe' -help 2>&1 | sed 's|.*<[^>]*> ||'
  " >> "$RESOLVED" 2>&1
done
for lib in libmpi libpmix libgmp libmpfr; do
  hit="$(grep -m1 "/$lib" "$RESOLVED" 2>/dev/null)"
  if [ -z "$hit" ]; then
    known "$lib not loaded by this binary (nothing to check)"
  else
    case "$hit" in
      "$APP"*) ok "$lib loads from the bundle";;
      *)       bad "$lib loads from the bundle" "loaded $hit";;
    esac
  fi
done
rm -f "$RESOLVED"

# ---------------------------------------------------------------------------
section "6. Functional: meshing, solvers, parallel"
# ---------------------------------------------------------------------------
WORK="$(mktemp -d)"
BODY="$(mktemp)"
OUT="$(mktemp)"
cat > "$BODY" <<'BODYEOF'
t() {
  n="$1"; shift
  if "$@" > /tmp/t.log 2>&1; then
    echo "RESULT $n ok"
  else
    echo "RESULT $n fail :: $(grep -m1 -iE 'error|cannot|no such|not found' /tmp/t.log | tr -s ' ' | cut -c1-90)"
  fi
}
cd "$FOAMTEST_WORK" || exit 1

# --- steady: blockMesh -> checkMesh -> simpleFoam -> postProcess
cp -r "$FOAM_TUTORIALS/incompressible/simpleFoam/pitzDaily" steady 2>/dev/null
cd steady || exit 1
[ -d 0.orig ] && cp -r 0.orig 0
t blockMesh          blockMesh
t checkMesh          checkMesh
t simpleFoam         simpleFoam
t postProcess        postProcess -latestTime -func writeCellCentres
t foamDictionary     foamDictionary system/controlDict -entry application
t foamListTimes      foamListTimes

# --- potential flow
cd "$FOAMTEST_WORK" || exit 1
cp -r "$FOAM_TUTORIALS/basic/potentialFoam/pitzDaily" potential 2>/dev/null
cd potential || exit 1
[ -d 0.orig ] && cp -r 0.orig 0            # what the tutorial's restore0Dir does
blockMesh >/dev/null 2>&1
t potentialFoam      potentialFoam -writePhi -writep

# --- transient: pimpleFoam, capped to a few steps so this stays quick
cd "$FOAMTEST_WORK" || exit 1
cp -r "$FOAM_TUTORIALS/incompressible/pimpleFoam/RAS/pitzDaily" transient 2>/dev/null
cd transient || exit 1
[ -d 0.orig ] && cp -r 0.orig 0
blockMesh >/dev/null 2>&1
foamDictionary system/controlDict -entry endTime -set 0.001 >/dev/null 2>&1
foamDictionary system/controlDict -entry writeInterval -set 0.001 >/dev/null 2>&1
t pimpleFoam         pimpleFoam

# --- parallel, across every decomposition method that was built
cd "$FOAMTEST_WORK/steady" || exit 1
for method in scotch hierarchical simple; do
  cat > system/decomposeParDict <<DPD
FoamFile { version 2.0; format ascii; class dictionary; object decomposeParDict; }
numberOfSubdomains 2;
method $method;
coeffs { n (2 1 1); }
DPD
  t "decompose-$method" decomposePar -force
done
# metis and kahip build as no-op stub libraries when the real solvers are not
# available. The library exists and loads, then refuses at run time, so
# presence of libmetisDecomp.dylib proves nothing. Report which it is.
for method in metis kahip; do
  cat > system/decomposeParDict <<DPD
FoamFile { version 2.0; format ascii; class dictionary; object decomposeParDict; }
numberOfSubdomains 2;
method $method;
DPD
  if decomposePar -force > /tmp/dec.log 2>&1; then
    echo "RESULT decompose-$method ok"
  elif grep -q 'dummy.*stub library' /tmp/dec.log; then
    echo "RESULT decompose-$method stub"
  else
    echo "RESULT decompose-$method fail :: $(grep -m1 -i error /tmp/dec.log | cut -c1-90)"
  fi
done

# Full parallel solve + reconstruct, using scotch
cat > system/decomposeParDict <<'DPD'
FoamFile { version 2.0; format ascii; class dictionary; object decomposeParDict; }
numberOfSubdomains 2;
method scotch;
DPD
decomposePar -force >/dev/null 2>&1
if mpirun -np 2 simpleFoam -parallel >/tmp/par.log 2>&1 && grep -q 'Finalising parallel run' /tmp/par.log; then
  echo "RESULT parallel-simpleFoam ok"
else
  echo "RESULT parallel-simpleFoam fail"
  tail -5 /tmp/par.log
fi
t reconstructPar     reconstructPar -latestTime
BODYEOF

FOAMTEST_WORK="$WORK" bash -c "
  set +e
  source '$RES/openfoam-session.sh' >/dev/null 2>&1
  export FOAMTEST_WORK='$WORK'
  source '$BODY'
" > "$OUT" 2>&1

if ! grep -q '^RESULT ' "$OUT"; then
  bad "functional tests ran at all" "nothing recorded; first output: $(head -3 "$OUT" | tr '\n' ' ' | cut -c1-140)"
else
for name in blockMesh checkMesh simpleFoam postProcess foamDictionary foamListTimes \
            potentialFoam pimpleFoam decompose-scotch decompose-hierarchical \
            decompose-simple decompose-metis decompose-kahip \
            parallel-simpleFoam reconstructPar; do
  line="$(grep -m1 "^RESULT $name " "$OUT" 2>/dev/null)"
  case "$line" in
    *" ok")     ok "$name";;
    *" stub")   known "$name" "built as a no-op stub; the real library was not available at build time";;
    *" fail"*)  bad "$name" "${line#*fail}";;
    *)        bad "$name" "no result recorded (an earlier case may have aborted)";;
  esac
done
fi

# ---------------------------------------------------------------------------
section "7. ParaView"
# ---------------------------------------------------------------------------
PVOUT="$(mktemp)"
cat > "$WORK/pvcheck.py" <<'PY'
from paraview.simple import OpenFOAMReader
r = OpenFOAMReader(FileName='case.foam'); r.UpdatePipeline()
n = r.GetDataInformation().GetNumberOfCells()
assert n > 0, 'reader returned an empty mesh'
print('PARAVIEW_READER_OK cells=%d' % n)
PY
bash -c "
  set +e
  source '$RES/openfoam-session.sh' >/dev/null 2>&1
  cd '$WORK/steady' 2>/dev/null || exit 1
  touch case.foam
  cp '$WORK/pvcheck.py' .
  pvpython pvcheck.py
" > "$PVOUT" 2>&1
grep -q PARAVIEW_READER_OK "$PVOUT" \
  && ok "pvpython reads the OpenFOAM case ($(grep -o 'cells=[0-9]*' "$PVOUT" | head -1))" \
  || bad "pvpython reads the OpenFOAM case" "$(tail -3 "$PVOUT" | tr '\n' ' ')"
check "foamview_startup.py present"  test -f "$RES/foamview_startup.py"
rm -f "$PVOUT"

# ---------------------------------------------------------------------------
section "8. Known limitations"
# ---------------------------------------------------------------------------
# Compiling against the packaged app fails on a case-insensitive filesystem:
# OpenFOAM's lnInclude dirs contain wchar.H/time.H/string.H/complex.H, so
# #include <wchar.h> resolves to OpenFOAM's C++ header instead of libc's.
# Reported, never gated -- bundling headers cannot fix it.
mkdir -p "$WORK/custom/Make"
cat > "$WORK/custom/myApp.C" <<'CPP'
#include "fvCFD.H"
int main(int argc, char *argv[])
{
    #include "setRootCase.H"
    #include "createTime.H"
    Info<< "CUSTOM_SOLVER_OK" << endl;
    return 0;
}
CPP
printf 'myApp.C\nEXE = $(FOAM_USER_APPBIN)/myApp\n' > "$WORK/custom/Make/files"
printf 'EXE_INC = -I$(LIB_SRC)/finiteVolume/lnInclude -I$(LIB_SRC)/meshTools/lnInclude\nEXE_LIBS = -lfiniteVolume -lmeshTools\n' \
  > "$WORK/custom/Make/options"
CBUILD="$(mktemp)"
bash -c "
  set +e
  source '$RES/openfoam-session.sh' >/dev/null 2>&1
  cd '$WORK/custom' || exit 1
  wmake
  [ -x \"\$FOAM_USER_APPBIN/myApp\" ] && echo COMPILE_PRODUCED_BINARY
" > "$CBUILD" 2>&1
# Only a binary that actually got built counts. Inferring success from the
# absence of "error:" reported a pass when wmake had not run at all.
# Now a required check: the case-sensitive src.dmg exists precisely so this
# works. If it regresses, the headers this app ships are dead weight again.
if grep -q COMPILE_PRODUCED_BINARY "$CBUILD"; then
  ok "custom solver compiles against the bundled headers"
elif grep -q "didn't find libc++" "$CBUILD"; then
  bad "custom solver compiles against the bundled headers" \
      "libc++ header shadowed -- LIB_SRC is not pointing at the case-sensitive image"
else
  bad "custom solver compiles against the bundled headers" \
      "$(grep -m1 -E 'error:|Error' "$CBUILD" | tr -s ' ' | cut -c1-160)"
fi
rm -f "$CBUILD" "$BODY" "$OUT"
rm -rf "$WORK"

# ---------------------------------------------------------------------------
printf '\n=== Summary ===\n'
printf '  passed: %s\n  failed: %s\n  known limitations: %s\n' "$PASS" "$FAIL" "$KNOWN"
if [ "$FAIL" -gt 0 ]; then
  printf '\nFailed checks:%s\n' "$FAILED_NAMES"
  exit 1
fi
printf '\nAll required checks passed.\n'
