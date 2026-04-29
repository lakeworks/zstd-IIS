# Build zstd-IIS for x64 with AVX2 (Intel Haswell+ / AMD Excavator+).
#
# Output: out/zstd.dll
#
# Prerequisites:
#   - Visual Studio 2022 Build Tools with the C++ workload + Windows SDK
#   - CMake on PATH (or the one bundled with VS Build Tools)
#   - Git (zstd library is a submodule)
#
# This fork's source already includes the windowLog=23 cap for Chrome
# compatibility (net::ERR_ZSTD_WINDOW_SIZE_TOO_BIG).

$ErrorActionPreference = 'Stop'

$repoRoot = $PSScriptRoot
$zstdLib = Join-Path $repoRoot 'zstd'
$libBuildDir = Join-Path $zstdLib 'build/cmake/x64'
$pluginProj = Join-Path $repoRoot 'src/zstdIIS.vcxproj'
$outDir = Join-Path $repoRoot 'out'

if (-not (Test-Path (Join-Path $zstdLib 'lib/zstd.h'))) {
    throw "zstd submodule missing. Run: git submodule update --init --recursive"
}

# Locate msbuild via vswhere (works for Build Tools, Community, Pro, Enterprise).
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { throw "vswhere not found at $vswhere — install VS 2022 Build Tools" }
$msbuild = & $vswhere -latest -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
if (-not $msbuild) { throw "MSBuild not found via vswhere" }

# AVX2 + LTCG flags applied to both libzstd_static and the plugin.
# /arch:AVX2 baseline: Intel Haswell (2013+) / AMD Excavator (2015+) / Zen (2017+).
# /DNDEBUG is preserved: zstd has many asserts in compress hot paths;
# without NDEBUG an assert failure inside w3wp.exe calls abort() and
# takes down the entire app pool, including every co-tenant site.
$avx2Flags = '/O2 /Ob2 /Oi /arch:AVX2 /GL /DNDEBUG'
$linkFlags = '/LTCG /OPT:REF /OPT:ICF'

Write-Host "[1/4] Configuring libzstd (CMake) for x64..." -ForegroundColor Cyan
if (-not (Test-Path $libBuildDir)) { New-Item -ItemType Directory -Force -Path $libBuildDir | Out-Null }
& cmake -A x64 -S (Join-Path $zstdLib 'build/cmake') -B $libBuildDir `
    "-DCMAKE_C_FLAGS_RELEASE=$avx2Flags" `
    "-DCMAKE_EXE_LINKER_FLAGS_RELEASE=$linkFlags" `
    "-DCMAKE_STATIC_LINKER_FLAGS_RELEASE=/LTCG"
if ($LASTEXITCODE -ne 0) { throw "cmake configure failed" }

Write-Host "[2/4] Building libzstd_static..." -ForegroundColor Cyan
& $msbuild (Join-Path $libBuildDir 'zstd.sln') /t:libzstd_static:Rebuild /p:Configuration=Release /p:Platform=x64
if ($LASTEXITCODE -ne 0) { throw "libzstd build failed" }

Write-Host "[3/4] Building zstd-IIS plugin (msbuild) for x64 with AVX2..." -ForegroundColor Cyan
& $msbuild $pluginProj /p:Configuration=Release /p:Platform=x64 `
    /p:WholeProgramOptimization=true `
    /p:LinkTimeCodeGeneration=UseLinkTimeCodeGeneration `
    "/p:ForcedIncludeFiles=" `
    "/p:AdditionalOptions=$avx2Flags"
if ($LASTEXITCODE -ne 0) { throw "plugin build failed" }

Write-Host "[4/4] Locating built DLL and copying to $outDir..." -ForegroundColor Cyan
# zstdIIS.vcxproj overrides BaseOutputPath to ..\out\bin (relative to src/),
# so the built DLL lands at <repoRoot>\out\bin\Release\x64\zstd.dll.
$built = Join-Path $repoRoot 'out\bin\Release\x64\zstd.dll'
if (-not (Test-Path $built)) {
    throw "Could not locate built zstd.dll at expected path: $built"
}
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
Copy-Item -Force $built -Destination (Join-Path $outDir 'zstd.dll')

$info = Get-Item (Join-Path $outDir 'zstd.dll')
Write-Host ""
Write-Host "Built: $($info.FullName)" -ForegroundColor Green
Write-Host "Size:  $($info.Length) bytes"
Write-Host "Built: $($info.LastWriteTime)"
