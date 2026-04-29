# Build zstd-IIS for x64.
#
# Output: out/zstd.dll  (last-build-wins; the bench's matrix runner copies
# this into out/variants/<variant>/zstd.dll for cross-arch comparisons)
#
# Parameters:
#   -Arch <avx2|sse2>  default: avx2
#     avx2 — /arch:AVX2 baseline (Intel Haswell+ / AMD Excavator+ / Zen+)
#     sse2 — x64 default codegen (no /arch: flag); SSE2 is implicit since
#            x64 ABI already mandates it. Used for the AVX2-vs-SSE2 keep/drop
#            measurement in the bench matrix.
#
# Prerequisites:
#   - Visual Studio 2022 Build Tools with the C++ workload + Windows SDK
#   - CMake on PATH. The VS-bundled CMake under VC\Tools\... is not
#     auto-discovered; either add its bin directory to PATH or install
#     CMake separately and put `cmake.exe` on PATH.
#   - Git (zstd library is a submodule)
#
# This fork's source already includes the windowLog=23 cap for Chrome
# compatibility (net::ERR_ZSTD_WINDOW_SIZE_TOO_BIG).

param(
    [ValidateSet('avx2','sse2')]
    [string]$Arch = 'avx2'
)

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
# `-products *` is required so BuildTools editions are not excluded — vswhere's
# default product filter (Community / Professional / Enterprise) silently
# drops Visual Studio 2022 Build Tools (productId
# Microsoft.VisualStudio.Product.BuildTools), even when the install is
# complete and visible to `vswhere -all`. The build-script comment
# claimed BuildTools support without the flag the assertion required.
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { throw "vswhere not found at $vswhere -- install VS 2022 Build Tools" }
$msbuild = & $vswhere -latest -products '*' -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
if (-not $msbuild) { throw "MSBuild not found via vswhere" }
$dumpbin = & $vswhere -latest -products '*' -find 'VC\Tools\MSVC\**\bin\Hostx64\x64\dumpbin.exe' | Select-Object -First 1
if (-not $dumpbin) { throw "dumpbin not found via vswhere -- install the VC++ build tools" }

# Compile flags applied to both libzstd_static and the plugin. /arch: is
# arch-conditional (see -Arch parameter); the rest is invariant.
#
# /arch:AVX2 vs no /arch: — when -Arch sse2, the script emits no /arch: flag.
# SSE2 is the x64-ABI default; /arch:SSE2 is accepted but emits the same
# codegen, and "absence of flag" is more honest about what the build is
# actually measuring against.
# /DNDEBUG is preserved: zstd has many asserts in compress hot paths;
# without NDEBUG an assert failure inside w3wp.exe calls abort() and
# takes down the entire app pool, including every co-tenant site.
# /MT explicitly: zstd's CMakeLists pins policies to 3.13, where CMP0091
# is OLD, which means CMAKE_MSVC_RUNTIME_LIBRARY is silently ignored.
# ZSTD_USE_STATIC_RUNTIME's flag-rewrite path only catches existing /MD
# entries, not flag strings that have no runtime option at all (which
# is what we hand it via CMAKE_C_FLAGS_RELEASE). Spelling /MT inline
# guarantees libzstd_static.lib uses the same CRT as the plugin's /MT
# vcxproj setting; without this, the plugin link step fails LNK2038/
# LNK4098.
$archFlag = if ($Arch -eq 'avx2') { '/arch:AVX2 ' } else { '' }
$compileFlags = "/O2 /Ob2 /Oi $($archFlag)/GL /DNDEBUG /MT"

Write-Host "[1/4] Configuring libzstd (CMake) for x64 ($($Arch.ToUpper()))..." -ForegroundColor Cyan
# Remove any stale cache before reconfigure. CMake refuses to overwrite a
# cache produced by a different generator OR different flag set, so a
# previous -Arch invocation would block the next one. The plugin vcxproj
# (line 100) hard-codes the link path as ..\zstd\build\cmake\x64\lib\Release
# without an arch suffix, so reusing the same dir is what keeps the link
# step finding libzstd_static.lib without a vcxproj edit on every
# arch-switch.
if (Test-Path $libBuildDir) { Remove-Item -Recurse -Force $libBuildDir }
New-Item -ItemType Directory -Force -Path $libBuildDir | Out-Null
# Disable everything we don't link into the IIS plugin -- we are encoder-only:
#  - PROGRAMS: builds the unused `zstd` CLI tool.
#  - SHARED:   builds libzstd.dll; we link the static lib only.
#  - DECOMPRESSION + LEGACY_SUPPORT: pulls decoder code (incl. v0.1-v0.7
#    legacy decoders, which have a CVE history) into the static lib. Dead
#    code that LTCG should strip, but stripping unused attack surface at
#    source is more reliable than trusting the linker.
#  - DICTBUILDER:    unused dictionary trainer.
#  - MULTITHREAD:    `nbWorkers` is never set above 0 in the plugin.
#  - TESTS:          no test code in the static lib build.
# EXE_LINKER_FLAGS / SHARED_LINKER_FLAGS would be unused -- both targets are
# disabled below. STATIC_LINKER_FLAGS=/LTCG is needed so libzstd_static.lib
# is link-time-codegen-compatible with the plugin's /GL objects.
# Pin -G "Visual Studio 17 2022": CMake's default-generator selection picks
# Ninja whenever ninja.exe is on PATH (e.g. Strawberry Perl ships ninja in
# c:\Strawberry\c\bin\ on a default PATH), but the `-A x64` platform spec is
# VS-generator-only — Ninja errors with "does not support platform
# specification". Explicit -G makes the build host-independent of whichever
# generators happen to be discoverable on PATH; the platform/architecture
# split (-A x64) and the AVX2 cflags below are unchanged.
& cmake -G 'Visual Studio 17 2022' -A x64 -S (Join-Path $zstdLib 'build/cmake') -B $libBuildDir `
    "-DCMAKE_C_FLAGS_RELEASE=$compileFlags" `
    "-DCMAKE_STATIC_LINKER_FLAGS_RELEASE=/LTCG" `
    "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded" `
    -DZSTD_USE_STATIC_RUNTIME=ON `
    -DZSTD_BUILD_PROGRAMS=OFF `
    -DZSTD_BUILD_SHARED=OFF `
    -DZSTD_BUILD_DECOMPRESSION=OFF `
    -DZSTD_BUILD_DICTBUILDER=OFF `
    -DZSTD_LEGACY_SUPPORT=OFF `
    -DZSTD_MULTITHREAD_SUPPORT=OFF `
    -DZSTD_BUILD_TESTS=OFF
if ($LASTEXITCODE -ne 0) { throw "cmake configure failed" }

Write-Host "[2/4] Building libzstd_static..." -ForegroundColor Cyan
& $msbuild (Join-Path $libBuildDir 'zstd.sln') /t:libzstd_static:Rebuild /p:Configuration=Release /p:Platform=x64
if ($LASTEXITCODE -ne 0) { throw "libzstd build failed" }

Write-Host "[3/4] Building zstd-IIS plugin (msbuild) for x64 with $($Arch.ToUpper())..." -ForegroundColor Cyan
# /t:Rebuild forces a clean compile of the plugin. Without it, msbuild's
# incremental build sees the .c source unchanged and skips recompile if
# only build-script flags or upstream libzstd outputs changed -- producing
# a stale DLL whose timestamp still updates.
$pluginArchProp = if ($Arch -eq 'avx2') { '/arch:AVX2' } else { '' }
& $msbuild $pluginProj /t:Rebuild /p:Configuration=Release /p:Platform=x64 `
    /p:WholeProgramOptimization=true `
    /p:LinkTimeCodeGeneration=UseLinkTimeCodeGeneration `
    "/p:ZstdIisArchFlag=$pluginArchProp" `
    "/p:ForcedIncludeFiles="
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

# Sanity check: verify all six IIS-ABI exports are present. A DLL missing
# any of these will fail to register and cause IIS to refuse to start the
# affected application pool -- the only error surfaces in the System event
# log on the next request, not at deploy time. Catch it here instead.
$exports = (& $dumpbin /exports (Join-Path $outDir 'zstd.dll')) -join "`n"
foreach ($sym in @('InitCompression','DeInitCompression','CreateCompression','ResetCompression','Compress','DestroyCompression')) {
    if ($exports -notmatch [Regex]::Escape($sym)) {
        throw "Required IIS export '$sym' missing from built DLL -- check src/zstd.def"
    }
}

$info = Get-Item (Join-Path $outDir 'zstd.dll')
Write-Host ""
Write-Host "Built: $($info.FullName)" -ForegroundColor Green
Write-Host "Size:  $($info.Length) bytes"
Write-Host "Built: $($info.LastWriteTime)"
