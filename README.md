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

Every build verifies the bundle end to end: it opens the real user session,
checks that `paraview` resolves inside the app and that MPICH has not shadowed
OpenMPI, then runs `pvpython` against a meshed `pitzDaily` case and asserts the
OpenFOAM reader returns a non-empty mesh.

The ParaView version is **pinned** in `build.yml`
(`PARAVIEW_VERSION` / `PARAVIEW_DMG_NAME`, currently 6.1.1). The release
watcher only tracks OpenFOAM, so bumping ParaView is a manual two-line edit;
older ParaView downloads stay available, so the pin never breaks on its own.

## Automatic release tracking

`.github/workflows/release-watch.yml` runs **hourly** (`cron: '23 * * * *'`)
and ships new OpenFOAM versions without anyone pressing a button:

1. Reads OpenFOAM's upstream tags with `scripts/latest-openfoam-tag.sh` and
   takes the newest release (`OpenFOAM-vYYMM`, or a `.NNNNNN` patch tag on
   top of one).
2. If this repo already has a GitHub release for that version *carrying a
   `macos-arm64.zip` asset*, there is nothing to do. The release is the
   state — no separate version file to drift out of sync.
3. Otherwise it dispatches `build.yml` with `openfoam_version=<tag>`, and
   that workflow builds, verifies and publishes the release itself.

Three guards keep the hourly tick from stacking up multi-hour macOS builds
(which bill at 10x):

- The watcher refuses to dispatch while any `build.yml` run is queued or
  in progress.
- `build.yml` has a `concurrency` group keyed by the OpenFOAM version, as a
  backstop against a manual re-dispatch of a build already running.
- On failure `build.yml` opens an issue labelled `build-failure` titled
  `Build failed: OpenFOAM-<tag>`, and the watcher skips any version that has
  one open. **Close the issue to ask for a retry** — the next hourly tick
  picks it up. A later successful build closes it automatically.

GitHub disables `schedule` triggers in a repository with no commit activity
for 60 days; re-enable them from the Actions tab.

## Running the workflow by hand

```
gh workflow run build.yml -f openfoam_version=v2606
gh run watch
```

Or force the watcher to re-evaluate right now:

```
gh workflow run release-watch.yml              # respects "already released"
gh workflow run release-watch.yml -f force=true  # rebuild even if released
```

Both are also available from the Actions tab. The build's app name, release
tag and asset name are all derived from `openfoam_version`, so no file needs
editing to ship a new version.

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
