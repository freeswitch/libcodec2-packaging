# escape=`
#
# Builds Codec2 on Windows as a SHARED library (codec2.dll + codec2.lib import
# library) with cl.exe from the Visual C++ toolchain, and packages the headers +
# binaries into zip files -- the same zips the GitHub Actions workflow produces.
#
# The Codec2 source is VENDORED in this repo (.\source\codec2) and COPYied into
# the image, so the build is fully offline -- no download, no CMake, no clang.
# build-codec2.ps1 compiles the curated vocoder subset directly with cl /LD and
# exports the API via libcodec2.def.
#
#   Build the toolchain image once:
#     docker build -t libcodec2-packaging .
#
#   Produce zips for a Codec2 release (writes to .\artifacts on the host):
#     docker run --rm --memory 4g `
#       -e CODEC2_VERSION=0.2 `
#       -v ${PWD}\artifacts:C:\artifacts `
#       libcodec2-packaging
#
# Requires Windows containers. The host must be able to run a Windows base image
# of an equal-or-older build than the host (process isolation), otherwise run
# with `--isolation=hyperv`.

ARG WINDOWS_BASE=mcr.microsoft.com/windows/servercore:ltsc2025
FROM ${WINDOWS_BASE}

# The Visual Studio bootstrapper. aka.ms/vs/17/release installs the latest VS 2022
# Build Tools.
ARG VS_BOOTSTRAPPER_URL=https://aka.ms/vs/17/release/vs_buildtools.exe

SHELL ["powershell", "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue';"]

# ---------------------------------------------------------------------------
# Visual Studio 2022 Build Tools: the C++ workload (MSVC v143 + Windows SDK).
# build-codec2.ps1 locates cl.exe via vswhere (installed by the bootstrapper)
# and drives the build directly -- no CMake, no Chocolatey.
# Exit code 3010 == success-but-reboot-required, which is fine in an image.
# ---------------------------------------------------------------------------
RUN Invoke-WebRequest -Uri $env:VS_BOOTSTRAPPER_URL -OutFile C:\vs_buildtools.exe; `
    Write-Host 'Installing Visual Studio Build Tools (this takes a while)...'; `
    $p = Start-Process -FilePath C:\vs_buildtools.exe -Wait -PassThru -ArgumentList `
        '--quiet','--wait','--norestart','--nocache', `
        '--installPath','C:\BuildTools', `
        '--add','Microsoft.VisualStudio.Workload.VCTools', `
        '--includeRecommended'; `
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw "VS Build Tools install failed ($($p.ExitCode))" }; `
    Remove-Item C:\vs_buildtools.exe -Force

# ---------------------------------------------------------------------------
# Build driver + vendored source.
# ---------------------------------------------------------------------------
COPY build-codec2.ps1 C:\build-codec2.ps1
COPY source C:\source

# Defaults; override any of these with `docker run -e ...`.
# CODEC2_VERSION is a label for the vendored source (which is codec2 0.2); it
# names the output zips/folders and is NOT used to fetch anything.
ENV CODEC2_VERSION=0.2 `
    CONFIGS="Release Debug" `
    PLATFORMS="x64" `
    PKG_PREFIX=libcodec2 `
    OUT_DIR=C:\artifacts `
    CODEC2_BUILD_ROOT=C:\cb

# NOTE: do NOT set `ENV PATH` here -- the Windows base image exports the variable
# as `Path` (mixed case) and Docker's ${...} substitution is case-sensitive, so
# `${PATH}` would expand to empty and wipe System32 from the path. The installer
# registers its dirs in the machine PATH (which container processes inherit), and
# build-codec2.ps1 invokes cl via vcvarsall at runtime.

ENTRYPOINT ["C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "C:\\build-codec2.ps1"]
