#!/bin/bash -e
# Bundle every Homebrew-provided dependency into the .app, so the shipped
# application needs no Homebrew at all — neither to run solvers nor to
# compile custom ones against the bundled wmake toolchain.
#
# Required env:
#   APP        the .app being built
#   APP_NAME   e.g. OpenFOAM-v2606
#
# Everything lands in one merged prefix:
#
#   Contents/Resources/deps/{bin,lib,include,share}
#
# A single prefix is what makes this tractable: OPAL_PREFIX, PRTE_PREFIX and
# all of OpenFOAM's *_ARCH_PATH variables can then point at the same place,
# and Open MPI relocates cleanly when they do.
#
# Written for bash 3.2 (what macOS ships as /bin/bash): no associative
# arrays — sets are kept as sorted files under $TMP.

: "${APP:?}"
: "${APP_NAME:?}"

RES="$APP/Contents/Resources"
FOAM="$RES/$APP_NAME"
DEPS="$RES/deps"
BREW="$(brew --prefix)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$DEPS/lib" "$DEPS/bin" "$DEPS/include" "$DEPS/share"

macho_refs() {   # $1 = file -> its Homebrew install-name references
  otool -L "$1" 2>/dev/null | tail -n +2 \
    | sed 's/^[[:space:]]*//; s/ (compatibility.*//' \
    | grep "^$BREW/" || true
}

# ---------------------------------------------------------------------------
# 1. Discover what the built tree actually pulls in.
#
# Deliberately discovered rather than hardcoded: of the eight formulae the
# install docs list, only five are referenced at runtime (cgal and boost are
# header-only here, and nothing links libomp at all), and that set moves
# between OpenFOAM releases.
# ---------------------------------------------------------------------------
echo "Scanning the built tree for Homebrew references..."
: > "$TMP/foam_files"
find "$FOAM/platforms" -type f 2>/dev/null | while read -r f; do
  refs="$(macho_refs "$f")"
  if [ -n "$refs" ]; then
    echo "$f" >> "$TMP/foam_files"
    echo "$refs"
  fi
done | sort -u > "$TMP/direct"
echo "  $(wc -l < "$TMP/direct" | tr -d ' ') dylibs referenced directly"

# Transitive closure — the direct refs drag in pmix, hwloc, libevent, ...
cp "$TMP/direct" "$TMP/queue"
: > "$TMP/closure"
while [ -s "$TMP/queue" ]; do
  cur="$(head -1 "$TMP/queue")"
  sed -i '' '1d' "$TMP/queue"
  grep -qxF "$cur" "$TMP/closure" 2>/dev/null && continue
  echo "$cur" >> "$TMP/closure"
  if [ -e "$cur" ]; then
    macho_refs "$cur" >> "$TMP/queue"
  else
    echo "  WARNING: $cur does not exist"
  fi
done
sort -u -o "$TMP/closure" "$TMP/closure"
echo "  $(wc -l < "$TMP/closure" | tr -d ' ') dylibs in the full transitive closure"

# Copy in, keyed by the basename other binaries *reference* — which is not
# always the real filename (libscotch.7.0.dylib is really libscotch.7.0.15.dylib).
while read -r src; do
  [ -e "$src" ] || continue
  cp -L "$src" "$DEPS/lib/$(basename "$src")"
  chmod u+w "$DEPS/lib/$(basename "$src")"
done < "$TMP/closure"

# Unversioned symlinks (libgmp.dylib -> libgmp.10.dylib) so that `-lgmp`
# resolves when someone compiles a custom solver.
for formula in gmp mpfr fftw scotch open-mpi pmix hwloc libevent; do
  fdir="$BREW/opt/$formula/lib"
  [ -d "$fdir" ] || continue
  for link in "$fdir"/*.dylib; do
    [ -L "$link" ] || continue
    target="$(basename "$(readlink "$link")")"
    [ -f "$DEPS/lib/$target" ] && ln -sf "$target" "$DEPS/lib/$(basename "$link")"
  done
done

# ---------------------------------------------------------------------------
# 2. Open MPI runtime.
#
# libmpi alone does not give you a parallel run: mpirun is its own executable,
# and under Open MPI 5 it delegates to PRRTE's prted daemon, which Homebrew
# ships as a *separate* formula. Both carry compiled-in prefixes, which is
# what OPAL_PREFIX/PRTE_PREFIX (set in the session rcfile) override.
#
# share/doc is 63M of Open MPI's 68M and is pure documentation — dropped.
# ---------------------------------------------------------------------------
echo "Bundling the MPI runtime (open-mpi, prrte, pmix, hwloc, libevent)..."
for formula in open-mpi prrte pmix hwloc libevent; do
  src="$BREW/opt/$formula"
  [ -d "$src" ] || { echo "  skip $formula (not installed)"; continue; }
  rsync -aL \
    --exclude 'share/doc' --exclude 'share/man' --exclude 'share/info' \
    --exclude 'lib/pkgconfig' --exclude 'lib/cmake' --exclude '*.a' \
    --exclude 'INSTALL_RECEIPT.json' --exclude '.brew' \
    "$src"/ "$DEPS"/ 2>/dev/null || true
done
echo "  mpirun: $([ -x "$DEPS/bin/mpirun" ] && echo present || echo MISSING)"
echo "  prted:  $([ -x "$DEPS/bin/prted" ] && echo present || echo MISSING)"

# ---------------------------------------------------------------------------
# 3. Headers, so `wmake` can compile custom solvers with no Homebrew present.
# ---------------------------------------------------------------------------
echo "Bundling headers..."
for formula in boost cgal fftw gmp mpfr scotch open-mpi; do
  src="$BREW/opt/$formula/include"
  [ -d "$src" ] || continue
  rsync -aL "$src"/ "$DEPS/include"/ 2>/dev/null || true
done
echo "  $(du -sh "$DEPS/include" | cut -f1) of headers"

# ---------------------------------------------------------------------------
# 4. Repoint every Homebrew install name at the bundle.
#
# install_name_tool invalidates a Mach-O signature, and on Apple Silicon an
# unsigned binary will not load at all — so every file touched here is
# re-signed immediately afterwards, and the app as a whole is signed later
# by package-app.sh.
# ---------------------------------------------------------------------------
relpath() { python3 -c 'import os,sys;print(os.path.relpath(sys.argv[1],sys.argv[2]))' "$1" "$2"; }

has_rpath() {    # $1 = file, $2 = rpath
  otool -l "$1" 2>/dev/null | grep -A2 LC_RPATH | grep -q "path $2 "
}

fix_macho() {    # $1 = file, $2 = rpath to reach $DEPS/lib
  local f="$1" rp="$2" ref
  [ -L "$f" ] && return 0
  file "$f" 2>/dev/null | grep -q 'Mach-O' || return 0

  local refs
  refs="$(macho_refs "$f")"
  [ -n "$refs" ] || return 0

  while read -r ref; do
    [ -n "$ref" ] || continue
    install_name_tool -change "$ref" "@rpath/$(basename "$ref")" "$f" 2>/dev/null || true
  done <<< "$refs"

  has_rpath "$f" "$rp" || install_name_tool -add_rpath "$rp" "$f" 2>/dev/null || true
  codesign --force --sign - "$f" 2>/dev/null || true
}

echo "Repointing install names at the bundle..."

# 4a. The bundled dylibs: give each an @rpath id, and let them find each
#     other through their own directory.
for f in "$DEPS"/lib/*.dylib; do
  [ -f "$f" ] && [ ! -L "$f" ] || continue
  install_name_tool -id "@rpath/$(basename "$f")" "$f" 2>/dev/null || true
  fix_macho "$f" "@loader_path"
done

# 4b. MPI plugin bundles (lib/openmpi, lib/pmix, lib/prte) and the binaries
#     in deps/bin.
find "$DEPS/lib" -mindepth 2 -type f \( -name '*.so' -o -name '*.dylib' \) 2>/dev/null \
  | while read -r f; do fix_macho "$f" "@loader_path/.."; done
find "$DEPS/bin" -type f 2>/dev/null \
  | while read -r f; do fix_macho "$f" "@loader_path/../lib"; done

# 4c. The OpenFOAM tree. Files sit at several depths (platforms/ARCH/bin,
#     .../lib, .../lib/sys-openmpi), so the rpath is computed per file.
count=0
while read -r f; do
  [ -n "$f" ] || continue
  rp="@loader_path/$(relpath "$DEPS/lib" "$(dirname "$f")")"
  fix_macho "$f" "$rp"
  count=$((count + 1))
done < "$TMP/foam_files"
echo "  patched $count files in the OpenFOAM tree"

# ---------------------------------------------------------------------------
# 5. Build-time flags for custom solvers.
#
# The build-time etc/prefs.sh points at /opt/homebrew, which is not there on
# a user's machine. Replace it with the bundle-relative equivalent.
# ---------------------------------------------------------------------------
cat > "$FOAM/etc/prefs.sh" <<'PREFS'
# Rewritten by scripts/bundle-deps.sh at package time. The build-time version
# of this file pointed at /opt/homebrew, which does not exist on a user's
# machine; these paths resolve inside the .app instead, so `wmake` can build
# custom solvers with no Homebrew installed.
_deps="${WM_PROJECT_DIR%/*}/deps"
export FOAM_EXTRA_CFLAGS="-I$_deps/include $FOAM_EXTRA_CFLAGS"
export FOAM_EXTRA_CXXFLAGS="-I$_deps/include $FOAM_EXTRA_CXXFLAGS"
export FOAM_EXTRA_LDFLAGS="-L$_deps/lib $FOAM_EXTRA_LDFLAGS"
unset _deps
PREFS

# ---------------------------------------------------------------------------
# 6. Audit: nothing anywhere may still point at Homebrew.
#
# This is the check that actually proves the bundle is self-contained, so it
# is a hard failure rather than a warning.
# ---------------------------------------------------------------------------
echo "Auditing for leftover Homebrew references..."
: > "$TMP/leftover"
# `[ -n ... ] && echo` as the loop's last command would make the whole loop
# exit 1 on the final no-match file, which `set -e` would treat as a failure.
find "$FOAM/platforms" "$DEPS" -type f 2>/dev/null | while read -r f; do
  refs="$(macho_refs "$f")"
  if [ -n "$refs" ]; then
    echo "$f: $refs" >> "$TMP/leftover"
  fi
done
if [ -s "$TMP/leftover" ]; then
  echo "FAIL: Mach-O files still reference $BREW:"
  head -20 "$TMP/leftover"
  exit 1
fi

echo "Bundled dependencies: $(du -sh "$DEPS" | cut -f1)"
echo "No Mach-O file in the app references $BREW."
