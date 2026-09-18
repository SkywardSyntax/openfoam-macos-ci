#!/bin/bash -e
# Configure OpenFOAM to build natively on macOS (Apple Silicon) using
# Apple Clang + Homebrew-provided third-party libraries.
#
# Expects to be run with cwd = the OpenFOAM source root (on a case-sensitive
# volume), i.e. `cd "$FOAM_SRC_DIR" && "$OLDPWD"/scripts/configure.sh`.

BREW_PREFIX="$(brew --prefix)"
LIBOMP_PREFIX="$(brew --prefix libomp)"

bin/tools/foamConfigurePaths \
    -system-compiler Clang \
    -sys-openmpi \
    -boost-brew \
    -cgal-brew \
    -fftw-brew \
    -scotch-brew \
    -gmp-brew \
    -mpfr-brew \
    -paraview system

# OpenMP: Apple Clang needs libomp from Homebrew explicitly on the include/link paths.
{
  echo "export FOAM_EXTRA_CFLAGS=\"-I${LIBOMP_PREFIX}/include \$FOAM_EXTRA_CFLAGS\""
  echo "export FOAM_EXTRA_CXXFLAGS=\"-I${LIBOMP_PREFIX}/include \$FOAM_EXTRA_CXXFLAGS\""
  echo "export FOAM_EXTRA_LDFLAGS=\"-L${LIBOMP_PREFIX}/lib \$FOAM_EXTRA_LDFLAGS\""
} >> etc/prefs.sh

echo "Configured. etc/prefs.sh:"
cat etc/prefs.sh
