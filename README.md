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
   These are a *build-time* dependency only; step 7 bundles what the result
   actually needs into the app.
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
7. Bundles the Homebrew dependencies into the app via
   `scripts/bundle-deps.sh` and rewrites every install name to load from
   there (see below).
8. Packages the built tree into `dist/OpenFOAM-v2606.app` via
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

## Bundled dependencies (no Homebrew needed)

The app is self-contained. Download, unzip, move to `/Applications`, done —
there is nothing to `brew install`.

`scripts/bundle-deps.sh` does this at package time:

1. **Discovers** what the built tree actually links against, rather than
   trusting a package list. That matters: of the eight formulae this project
   used to tell people to install, only five are referenced at runtime —
   `cgal` and `boost` are header-only here, and **nothing links `libomp`
   at all**.
2. Walks the **transitive closure** (`libmpi` alone drags in pmix, hwloc and
   libevent) and copies it into `Contents/Resources/deps`. The whole runtime
   closure is about **8 MB across 14 dylibs**.
3. Bundles the **MPI runtime**. `libmpi` is not enough for a parallel run:
   `mpirun` is its own executable, and under Open MPI 5 it delegates to
   PRRTE's `prted` daemon, which Homebrew ships as a *separate* formula.
   Both have their prefix compiled in, which is why the session rcfile sets
   `OPAL_PREFIX`/`PRTE_PREFIX` — the documented relocation hooks.
4. Bundles the **headers** (~235 MB, mostly Boost and CGAL) for `wmake`.
   Note the case-sensitivity limitation below: these are necessary for
   compiling custom solvers but not currently sufficient.
5. Rewrites every Homebrew install name to `@rpath/...` and adds an
   `@loader_path`-relative `LC_RPATH`, computed per file — binaries sit at
   several depths, so `libPstream` in `lib/sys-openmpi/` needs a different
   rpath than `libscotchDecomp` in `lib/`.
6. **Re-signs** each patched file. `install_name_tool` invalidates a Mach-O
   signature, and on Apple Silicon an unsigned binary is killed outright
   rather than failing to link.
7. **Audits**, as a hard failure, that no Mach-O file in the app still
   references `/opt/homebrew`.

Everything goes into a single merged prefix, which is what makes it
tractable — `OPAL_PREFIX` and all of OpenFOAM's `*_ARCH_PATH` variables can
then point at the same directory.

Upstream's `etc/config.sh/{CGAL,FFTW,scotch}` resolve their paths by calling
`brew --prefix` *while the session is being sourced*, so the session rcfile
overrides those variables afterwards. Runtime linking does not depend on
that — the install names were already rewritten — but the compile path does.

### How this is verified

`scripts/test-app.sh` is an acceptance suite that runs on every build and can
be run by hand against any installed copy:

```
APP=/Applications/OpenFOAM-v2606.app scripts/test-app.sh
```

It checks bundle structure, self-containment (no Mach-O referencing
`/opt/homebrew`, valid code signatures), the session environment, ~50 shipped
executables, which libraries dyld *actually* maps at runtime, then runs
`blockMesh`, `checkMesh`, `simpleFoam`, `potentialFoam`, `pimpleFoam`, the
working decomposition methods (scotch, hierarchical, simple), a 2-way parallel
solve with `reconstructPar`, and the ParaView reader through `pvpython`.

Note on decomposition: `libmetisDecomp.dylib` and `libkahipDecomp.dylib` are
present but are **no-op stubs**. OpenFOAM builds those when METIS and KaHIP
are not available at build time; the library loads and then refuses at run
time, so the file existing proves nothing. The suite detects the stub message
explicitly and reports it rather than passing or failing. Real parallel
decomposition uses **scotch/ptscotch**, which is bundled and works.

Three things make it meaningful rather than decorative:

- **Homebrew is deleted from the runner** (`sudo mv /opt/homebrew`) before it
  runs, and restored in an `always()` step. Otherwise every check could pass
  by quietly falling back to it.
- **It tests the unzipped release artifact at a different path**, not the build
  directory. That covers the zip round-trip (`pvbin` and `lnInclude` are
  symlinks) and proves the app is relocatable.
- **It checks what dyld actually maps**, not just install names. Correct
  install names were not sufficient: a stale `DYLD_LIBRARY_PATH` entry once
  loaded Homebrew's `libmpi` over the bundled one, and only this check caught
  it.

### Compiling custom solvers, and the case-sensitivity problem

OpenFOAM's `src/` contains **37 pairs of paths that differ only by case** —
`instant.H`/`Instant.H`, `lduMatrix`/`LduMatrix`,
`leastSquaresGrad`/`LeastSquaresGrad`. macOS volumes are case-insensitive by
default, so copying that tree onto one silently merges every pair: one file of
each is lost, and the colliding *directories* are flattened together.

This affected the shipped app directly. `src/OpenFOAM/db/Time/instant/` has
five files upstream and four in the app, and `lnInclude/Instant.H` was a
broken symlink pointing at the `instant.H` that no longer existed. Compiling
anything against it failed at the first `#include`:

```
<cwchar> tried including <wchar.h> but didn't find libc++'s <wchar.h> header.
```

It is not repairable after the fact — merged directories cannot be unmerged by
copying files back. The source has to never touch a case-insensitive
filesystem.

So `scripts/package-app.sh` builds **`Contents/Resources/src.dmg`**: a
case-sensitive, compressed, read-only image populated straight from the
case-sensitive build volume. Packaging fails if a colliding pair does not
survive into it. At session start the app mounts it (`-nobrowse -readonly`,
under `~/Library/Caches`) and points **`LIB_SRC`** at the mount.

`LIB_SRC` is the one lever that matters: `wmake/makefiles/general` defines
every OpenFOAM include path from it, both the two wmake injects
(`$(LIB_SRC)/OpenFOAM/lnInclude`, `$(LIB_SRC)/OSspecific/...`) and the
`$(LIB_SRC)/...` entries in any `Make/options`. Packaging rewrites its plain
`=` assignment to `?=` so the environment can override it.

The acceptance suite compiles a real solver on every build and **fails if it
does not build**, so this cannot silently regress.

Compiling still needs Apple's Command Line Tools (`xcode-select --install`) —
an app cannot ship a compiler. Running the prebuilt solvers does not.

## Using the built app

Download the `OpenFOAM-v2606.app` artifact from the completed run, unzip, and
move it to `/Applications`.

Double-clicking the app opens a Terminal with the OpenFOAM environment
sourced (`blockMesh`, `simpleFoam`, etc. on `PATH`), including parallel runs
through the bundled Open MPI. It also carries the full `wmake` toolchain and
the third-party headers — but see the case-sensitivity limitation above
before relying on compiling your own solvers.
