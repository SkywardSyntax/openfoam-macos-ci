# OpenFOAM.app (macOS, built via GitHub Actions)

Builds OpenFOAM v2606 (ESI/OpenCFD) natively for Apple Silicon macOS using a
`macos-15` GitHub Actions runner, and packages the result as a double-clickable
`.app` that opens a Terminal window with the OpenFOAM environment loaded.

No forked/third-party macOS packaging project is used — this builds straight
from OpenFOAM's own upstream source (`gitlab.com/openfoam/core/openfoam`,
tag `OpenFOAM-v2606`) using OpenFOAM's own `foamConfigurePaths` Homebrew
integration (`-with-homebrew`, `-sys-openmpi`).

## How it works

1. Installs third-party deps via Homebrew (OpenMPI, FFTW, Scotch, CGAL,
   Boost, GMP, MPFR, libomp) — prebuilt bottles, not built from source.
2. Creates a case-sensitive APFS disk image to hold the OpenFOAM source
   (required: OpenFOAM's source tree has files/dirs that only differ by case,
   e.g. `InterfaceCompositionModel.C` vs `interfaceCompositionModel.C`, which
   silently collide on macOS's default case-insensitive filesystem).
3. Clones OpenFOAM v2606 and runs `scripts/configure.sh`, which points
   `foamConfigurePaths` at the Homebrew-installed dependencies and Apple Clang.
4. Runs `./Allwmake -j` to build everything.
5. Smoke-tests `blockMesh`/`simpleFoam` against the `pitzDaily` tutorial.
6. Downloads the official prebuilt ParaView arm64 binary (cached between
   runs) and bundles it into the app.
7. Packages the built tree into `dist/OpenFOAM-v2606.app` via
   `scripts/package-app.sh`, ad-hoc code-signs it, zips it, and uploads it
   as a workflow artifact and a GitHub release asset.

## ParaView

ParaView is **bundled but not compiled** — OpenFOAM's own build docs call
building it from source "the most difficult part of any third-party
compilation," and there's no need: ParaView ships a built-in OpenFOAM
reader, so the official prebuilt binary works as-is. `paraFoam -builtin`
opens the current case.

Only `paraview`, `pvpython`, `pvbatch` and `pvserver` are exposed on `PATH`,
through a shim directory. This is deliberate: ParaView also ships its own
MPICH `mpiexec`, and putting its `bin` directories on `PATH` would shadow
the Homebrew OpenMPI that OpenFOAM's parallel runs are built against.

## Running the workflow

```
gh workflow run build.yml
gh run watch
```

Or trigger it from the Actions tab (workflow_dispatch), optionally overriding
the `openfoam_version` input (defaults to `v2606`).

## Using the built app

Download the `OpenFOAM-v2606.app` artifact from the completed run, unzip, and
move it to `/Applications`. **The target Mac needs the same Homebrew
dependencies installed** (the app links against them at their Homebrew
paths rather than bundling them):

```
brew install open-mpi fftw scotch cgal boost gmp mpfr libomp
```

Double-clicking the app opens a Terminal with the OpenFOAM environment
sourced (`blockMesh`, `simpleFoam`, etc. on `PATH`). It also contains the
full `wmake` toolchain and headers, so you can compile custom solvers
against it.
