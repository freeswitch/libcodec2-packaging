# libcodec2-packaging

Builds **[Codec2](https://github.com/drowe67/codec2) as a shared library
(`codec2.dll` + `codec2.lib` import library) on Windows** and packages the
headers + binaries into zip files, via either GitHub Actions or a local Docker
toolchain image.

The Codec2 source is **vendored in this repo** (`source/codec2`) and built
directly with `cl.exe` — no download, no CMake, no clang. The build compiles the
**vocoder subset** of `.c` files (the `codec2_*` encode/decode API) plus the
pre-generated codebooks, and exports the API via `libcodec2.def`.

The vendored source is **codec2 0.2**. It predates codec2's move to C99
variable-length arrays, so it compiles cleanly with MSVC `cl` — no Unix math lib,
no clang.

## What it produces

For package version `0.2`, building `x64` × `Release Debug`:

```
libcodec2-0.2-headers.zip                  libcodec2-0.2/include/codec2/{codec2.h, COPYING}
libcodec2-0.2-binaries-x64-release.zip     libcodec2-0.2/binaries/x64/Release/{codec2.dll, codec2.lib, codec2.pdb, COPYING}
libcodec2-0.2-binaries-x64-debug.zip       libcodec2-0.2/binaries/x64/Debug/{codec2.dll, codec2.lib, codec2.pdb, COPYING}
SHA256SUMS.txt
```

Each archive ships Codec2's `COPYING` (LGPL) next to its payload — not at the
package root, since all zips extract into the same `libcodec2-0.2\` folder and a
root-level copy would collide across them.

Zip *filenames* are lower-cased (`...-x64-release.zip`); the *paths inside* keep
their original case (`binaries\x64\Release\...`).

> **x64 only** by default. Pass `PLATFORMS="x64 Win32"` to also build 32-bit.

## Repository layout

```
.github/workflows/build-codec2.yml    CI: build on a Windows runner, upload zip artifacts
build-codec2.ps1                      the build + package script (shared by CI and Docker)
Dockerfile                            Windows-container toolchain image (for local/offline builds)
source/codec2/                        vendored codec2 0.2 source + libcodec2.def (the API export list)
README.md
```

## Building

### Option A — GitHub Actions (recommended)

The **Build Codec2 (Windows)** workflow runs on a `windows-2022` runner (which
already has Visual Studio 2022 with the C++ toolset) and runs `build-codec2.ps1`.

- **Manually:** Actions tab → *Build Codec2 (Windows)* → **Run workflow**, then
  enter the version label (e.g. `0.2`), configs (`Release Debug`), and platforms (`x64`).
- **By tag:** push a tag like `codec2-v0.2`. The workflow builds it and also
  attaches the zips to a GitHub Release.

### Option B — Local, via the Docker toolchain image

Requires Docker with **Windows containers** enabled.

```powershell
# Build the toolchain image once (installs VS Build Tools).
# This layer is large and slow; subsequent builds reuse it.
docker build -t libcodec2-packaging .

# Produce zips (writes to .\artifacts on the host).
# CONFIGS picks the configurations (default "Release Debug" -> builds BOTH);
# PLATFORMS defaults to x64. See the parameters table below for every knob.
docker run --rm --memory 4g `
  -e CODEC2_VERSION=0.2 `
  -e CONFIGS="Release Debug" `
  -v ${PWD}\artifacts:C:\artifacts `
  libcodec2-packaging
```

cmd.exe: replace `${PWD}` with `%cd%`.

`CONFIGS` is space-separated; override it to build a single configuration:

```powershell
# Debug only (omit -e CONFIGS entirely to get the default Release + Debug)
docker run --rm --memory 4g -e CODEC2_VERSION=0.2 -e CONFIGS=Debug `
  -v ${PWD}\artifacts:C:\artifacts libcodec2-packaging
```

The host must run a Windows base image of equal-or-older build for process
isolation (the Dockerfile defaults to `servercore:ltsc2025`); otherwise pass
`--build-arg WINDOWS_BASE=...:ltsc2022` or run with `--isolation=hyperv`.

### Option C — Local, native

If you already have **Visual Studio 2022 (C++ workload)** installed, just run the
script directly (it locates `cl.exe` via `vswhere`):

```powershell
$env:CODEC2_VERSION = '0.2'
$env:CONFIGS        = 'Release Debug'
$env:OUT_DIR        = "$PWD\artifacts"
.\build-codec2.ps1
```

### Build parameters (env vars)

| Var                 | Default          | Notes |
|---------------------|------------------|-------|
| `CODEC2_VERSION`    | `0.2`            | Label for the vendored source; names the output zips/folders. Not used to fetch anything. |
| `CONFIGS`           | `Release Debug`  | Space-separated: `Release`, `Debug`, or `Release Debug` (default builds both). |
| `PLATFORMS`         | `x64`            | Space-separated. `x64` and/or `Win32`. |
| `PKG_PREFIX`        | `libcodec2`      | Zip/folder name prefix. |
| `OUT_DIR`           | `C:\artifacts`   | Where the zips are written (mount this in Docker). |
| `CODEC2_BUILD_ROOT` | `C:\cb`          | Scratch build dir (kept short to dodge MAX_PATH). |

## Consuming the zips

1. Extract `libcodec2-<ver>-binaries-x64-<cfg>.zip` and
   `libcodec2-<ver>-headers.zip` (they share the `libcodec2-<ver>\` root).
2. Add `libcodec2-<ver>\include` (for `<codec2/codec2.h>`) and
   `…\include\codec2` (for `<codec2.h>`) to the include path.
3. Link **`codec2.lib`** (the import library) and **ship `codec2.dll`** next to
   your binary — because Codec2 is dynamically linked, the DLL must ship.

## How the build works

`build-codec2.ps1`:

1. Copies the vendored `source\codec2` tree to a short scratch dir (keeps the repo
   clean) and sanity-checks that every source it compiles — plus `libcodec2.def` —
   is present.
2. Locates `cl.exe` via `vswhere` and, per platform × config, compiles the vocoder
   subset + pre-generated codebooks with `cl /LD` (`/MD` Release, `/MDd /Od /RTC1`
   Debug), exporting the API via `/DEF:libcodec2.def` and emitting the import lib
   with `/IMPLIB:codec2.lib`. This yields `codec2.dll` + `codec2.lib` + `codec2.pdb`.
3. Packages the DLL/lib/PDB into the per-config binaries zip; packages `codec2.h`
   (and any local headers it `#include`s) into the headers zip; drops Codec2's
   `COPYING` license next to the payload in each zip; writes `SHA256SUMS.txt`.

## Notes & gotchas

- **Shared library.** This builds a DLL + import lib. The consumer must ship
  `codec2.dll` alongside its binary.
- **`libcodec2.def` is the export list.** Only the symbols listed there are
  exported (and so end up in `codec2.lib`). If a consumer needs another `codec2_*`
  function, add it to `source\codec2\libcodec2.def` — a missing entry shows up as
  an `LNK2019` unresolved external in the consumer, not here.
- **`LIBRARY codec2`** in the `.def` must match the output DLL name (`codec2.dll`),
  so the import lib records the right DLL to load at runtime.
- **MSVC runtime.** Built with the dynamic CRT (`/MD`, `/MDd` for Debug); the
  consumer must use the same CRT.
- **Offline & reproducible.** The source is vendored, so a build needs no network
  and any version label builds cleanly without a manual refresh.
