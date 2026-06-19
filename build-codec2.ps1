<#
.SYNOPSIS
    Builds Codec2 as a shared library (codec2.dll + codec2.lib import library) on
    Windows with the Visual C++ toolchain, from the codec2 source VENDORED IN THIS
    REPO (.\source\codec2), and packages the binaries + headers into zip files.

    Compiles only the curated VOCODER subset of .c files with cl.exe -- plus the
    pre-generated codebooks -- and exports the API via libcodec2.def (the
    codec2_create/encode/decode API + helpers).

    The source is codec2 0.2. It predates codec2's move to C99 variable-length
    arrays, so it compiles cleanly with MSVC cl -- no CMake, no clang, no Unix
    math lib, no download.

    Produces, in $OutDir:
      <prefix>-<ver>-headers.zip
          <prefix>-<ver>/include/codec2/{codec2.h, COPYING}
      <prefix>-<ver>-binaries-<platform>-<config>.zip
          <prefix>-<ver>/binaries/<Platform>/<Config>/{codec2.dll, codec2.lib, codec2.pdb, COPYING}
      SHA256SUMS.txt
#>
[CmdletBinding()]
param(
    [string]$Codec2Version = $env:CODEC2_VERSION,     # vendored source version (0.2)
    [string]$Configs       = $env:CONFIGS,            # space separated: "Release Debug"
    [string]$Platforms     = $env:PLATFORMS,          # space separated; default "x64"
    [string]$PkgPrefix     = $env:PKG_PREFIX,         # zip/folder name prefix (libcodec2)
    [string]$OutDir        = $env:OUT_DIR,            # where the zips land (mount this)
    [string]$BuildRoot     = $env:CODEC2_BUILD_ROOT   # scratch build dir
)

$ErrorActionPreference = 'Stop'

# --- defaults ---------------------------------------------------------------
if (-not $Codec2Version) { $Codec2Version = '0.2' }   # matches the vendored source
if (-not $Configs)       { $Configs       = 'Release Debug' }
if (-not $Platforms)     { $Platforms     = 'x64' }
if (-not $PkgPrefix)     { $PkgPrefix     = 'libcodec2' }
if (-not $OutDir)        { $OutDir        = 'C:\artifacts' }
if (-not $BuildRoot)     { $BuildRoot     = 'C:\cb' }

$ver = $Codec2Version.TrimStart('vV')
$pkg = "$PkgPrefix-$ver"

# Vendored source (committed in this repo; COPYied to C:\source in the Docker image).
$srcDir = Join-Path $PSScriptRoot 'source\codec2'
if (-not (Test-Path (Join-Path $srcDir 'codec2.c'))) {
    throw "Vendored source not found at '$srcDir' (expected the codec2 src tree with codec2.c, the codebooks, and libcodec2.def)."
}

# Codec2 license (LGPL), shipped in the root of every archive.
$licenseSrc = Join-Path $PSScriptRoot 'source\COPYING'
if (-not (Test-Path $licenseSrc)) {
    throw "License file not found at '$licenseSrc' (expected codec2's COPYING)."
}

$configList   = $Configs   -split '\s+' | Where-Object { $_ }
$platformList = $Platforms -split '\s+' | Where-Object { $_ }

# Curated VOCODER subset (the codec2_* encode/decode API).
$vocoderSrcs = @(
    'codec2.c','lpc.c','nlp.c','postfilter.c','sine.c','fifo.c','fdmdv.c',
    'kiss_fft.c','interp.c','lsp.c','phase.c','quantise.c','pack.c','dump.c'
)
# Pre-generated codebooks (vendored alongside the source).
$codebookSrcs = @(
    'codebook.c','codebookd.c','codebookdt.c','codebookge.c',
    'codebookjnd.c','codebookjvm.c','codebookvq.c','codebookvqanssi.c'
)

# --- locate Visual Studio (cl via vcvarsall) --------------------------------
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) { throw "vswhere.exe not found at '$vswhere' (Visual Studio 2017+ with the C++ toolset is required)." }
$vsInstall = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath) | Select-Object -First 1
if (-not $vsInstall) { throw "No Visual Studio install with the C++ toolset (VC.Tools.x86.x64) was found." }
$vcvarsall = Join-Path $vsInstall 'VC\Auxiliary\Build\vcvarsall.bat'
if (-not (Test-Path $vcvarsall)) { throw "vcvarsall.bat not found at '$vcvarsall'." }

function Get-VcArch([string]$plat) {
    switch ($plat) { 'x64' { 'x64' } 'Win32' { 'x86' } default { throw "Unsupported platform '$plat' (use 'x64' or 'Win32')." } }
}

# Run a .bat with stdout+stderr -> a log FILE via cmd (NOT PowerShell's 2>&1, which
# under Windows PowerShell 5.1 + ErrorActionPreference=Stop turns native stderr into
# a terminating error). Echo the log; throw with error lines on failure.
function Invoke-Logged([string]$batBody, [string]$log, [string]$what) {
    $batFile = Join-Path $BuildRoot 'step.bat'
    Set-Content -Path $batFile -Value "@echo off`r`n$batBody" -Encoding ASCII
    & cmd.exe /c "`"$batFile`" > `"$log`" 2>&1"
    $code = $LASTEXITCODE
    if (Test-Path $log) { Get-Content $log }
    if ($code -ne 0) {
        Write-Host ""
        Write-Host "===== $what FAILED (exit $code) - error lines from $log =====" -ForegroundColor Red
        Select-String -Path $log -Pattern '(: |\b)(error|fatal error|unresolved|cannot open)\b' -CaseSensitive:$false |
            Select-Object -Last 60 | ForEach-Object { Write-Host $_.Line }
        throw "$what failed with exit code $code. Full log: $log"
    }
}

Write-Host "==================================================================="
Write-Host " Codec2 version : $ver  (vendored in-tree)"
Write-Host " Platforms      : $($platformList -join ', ')"
Write-Host " Configs        : $($configList -join ', ')"
Write-Host " Library type   : SHARED (codec2.dll + codec2.lib), MSVC vocoder subset"
Write-Host " VS install     : $vsInstall"
Write-Host " Source         : $srcDir"
Write-Host " Build root     : $BuildRoot"
Write-Host " Output dir     : $OutDir"
Write-Host "==================================================================="

# --- prep dirs --------------------------------------------------------------
if (Test-Path $BuildRoot) { Remove-Item -Recurse -Force $BuildRoot }
New-Item -ItemType Directory -Force -Path $BuildRoot | Out-Null
New-Item -ItemType Directory -Force -Path $OutDir    | Out-Null
$stage = Join-Path $BuildRoot 'stage'
New-Item -ItemType Directory -Force -Path $stage     | Out-Null

# Work on a copy of the vendored source so the repo tree stays clean.
$build = Join-Path $BuildRoot 'codec2'
Copy-Item -Recurse -Force $srcDir $build

# Sanity: every source we intend to compile must be present.
foreach ($f in ($vocoderSrcs + $codebookSrcs)) {
    if (-not (Test-Path (Join-Path $build $f))) { throw "Expected source '$f' not found in vendored tree." }
}
if (-not (Test-Path (Join-Path $build 'libcodec2.def'))) { throw "libcodec2.def not found in vendored tree." }

# --- build each platform x config -------------------------------------------
$incCaptured = $false
foreach ($plat in $platformList) {
    $vcArch = Get-VcArch $plat
    foreach ($config in $configList) {
        Write-Host "-------------------------------------------------------------------"
        Write-Host "Building Codec2 $ver  [$plat / $config]  (cl, vocoder subset)"
        Write-Host "-------------------------------------------------------------------"

        $obj = Join-Path $BuildRoot "obj-$plat-$config"
        if (Test-Path $obj) { Remove-Item -Recurse -Force $obj }
        New-Item -ItemType Directory -Force -Path $obj | Out-Null

        $isDebug = ($config -ieq 'Debug')
        $optFlag = if ($isDebug) { '/Od /RTC1' } else { '/O2' }
        $rtFlag  = if ($isDebug) { '/MDd' }      else { '/MD' }
        $cfgDef  = if ($isDebug) { '/D_DEBUG' }  else { '/DNDEBUG' }

        $srcArgs = ($vocoderSrcs + $codebookSrcs) -join ' '
        $defines = "/DWIN32 $cfgDef /D_WINDOWS /D_USRDLL /DLIBlibcodec2_EXPORTS /D_CRT_SECURE_NO_DEPRECATE /D_CRT_NONSTDC_NO_DEPRECATE /D_USE_MATH_DEFINES"

        $bldBat = @"
call "$vcvarsall" $vcArch || exit /b 1
cd /d "$build" || exit /b 1
cl /nologo /LD /Zi /W3 $optFlag $rtFlag $defines /I"$build" $srcArgs /Fe:"$obj\codec2.dll" /Fo:$obj\ /Fd:"$obj\codec2_compiler.pdb" /link /DEBUG /DEF:libcodec2.def /IMPLIB:"$obj\codec2.lib" /PDB:"$obj\codec2.pdb" || exit /b 1
"@
        Invoke-Logged $bldBat (Join-Path $OutDir "build-$plat-$config.log") "Codec2 build [$plat/$config]"

        $dll = Join-Path $obj 'codec2.dll'
        $lib = Join-Path $obj 'codec2.lib'
        if (-not (Test-Path $dll)) { throw "Expected '$dll' was not produced." }
        if (-not (Test-Path $lib)) { throw "Expected import library '$lib' was not produced." }

        $binDst = Join-Path $stage "bin-$plat-$config\$pkg\binaries\$plat\$config"
        New-Item -ItemType Directory -Force -Path $binDst | Out-Null
        Copy-Item $dll -Destination (Join-Path $binDst 'codec2.dll')
        Copy-Item $lib -Destination (Join-Path $binDst 'codec2.lib')
        $pdb = Join-Path $obj 'codec2.pdb'
        if (Test-Path $pdb) { Copy-Item $pdb -Destination (Join-Path $binDst 'codec2.pdb') }
        else { Write-Host "  NOTE: codec2.pdb not found; continuing without it." -ForegroundColor Yellow }

        Copy-Item $licenseSrc -Destination (Join-Path $binDst 'COPYING')

        $zip = Join-Path $OutDir ("$pkg-binaries-$plat-$config.zip".ToLower())
        if (Test-Path $zip) { Remove-Item -Force $zip }
        Compress-Archive -Path (Join-Path $stage "bin-$plat-$config\$pkg") -DestinationPath $zip
        Write-Host "  -> $zip"

        if (-not $incCaptured) {
            $hdrDst = Join-Path $stage "hdr\$pkg\include\codec2"
            New-Item -ItemType Directory -Force -Path $hdrDst | Out-Null
            # codec2.h is the public header (no further includes in 0.2); also copy
            # any local headers it does #include, to be safe across versions.
            $wanted = New-Object System.Collections.Generic.HashSet[string]
            [void]$wanted.Add('codec2.h')
            (Get-Content (Join-Path $build 'codec2.h')) |
                Select-String '^\s*#\s*include\s*"([^"]+\.h)"' |
                ForEach-Object { [void]$wanted.Add($_.Matches[0].Groups[1].Value) }
            foreach ($h in $wanted) {
                $hp = Join-Path $build $h
                if (Test-Path $hp) { Copy-Item $hp -Destination $hdrDst }
            }
            $incCaptured = $true
        }
    }
}

# --- package headers --------------------------------------------------------
Write-Host "-------------------------------------------------------------------"
Write-Host "Packaging headers ..."
Copy-Item $licenseSrc -Destination (Join-Path $stage "hdr\$pkg\include\codec2\COPYING")
$hdrZip = Join-Path $OutDir ("$pkg-headers.zip".ToLower())
if (Test-Path $hdrZip) { Remove-Item -Force $hdrZip }
Compress-Archive -Path (Join-Path $stage "hdr\$pkg") -DestinationPath $hdrZip
Write-Host "  -> $hdrZip"

# --- checksums --------------------------------------------------------------
$sums = Join-Path $OutDir 'SHA256SUMS.txt'
Get-ChildItem -Path $OutDir -Filter '*.zip' | ForEach-Object {
    "{0}  {1}" -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower(), $_.Name
} | Set-Content -Encoding ASCII $sums

Write-Host "==================================================================="
Write-Host " Done. Codec2 $ver packaged in $OutDir :"
Get-ChildItem -Path $OutDir -Filter '*.zip' | ForEach-Object {
    Write-Host ("   {0,14:N0}  {1}" -f $_.Length, $_.Name)
}
Write-Host "==================================================================="
