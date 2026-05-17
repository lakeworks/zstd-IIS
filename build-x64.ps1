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
#   -Lto <on|off>  default: on
#     on  — whole-program optimization: /GL on the compile flags, /LTCG on
#           the static linker (CMAKE_STATIC_LINKER_FLAGS_RELEASE) and the
#           plugin msbuild (WholeProgramOptimization=true +
#           LinkTimeCodeGeneration=UseLinkTimeCodeGeneration).
#     off — none of the above (/GL dropped, static linker flag empty,
#           WholeProgramOptimization=false — the load-bearing /LTCG-off
#           control — and LinkTimeCodeGeneration set to an explicit empty
#           string). Used for the LTO-on-vs-off cost measurement in the
#           bench matrix.
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
    [string]$Arch = 'avx2',

    [ValidateSet('on','off')]
    [string]$Lto = 'on'
)

$ErrorActionPreference = 'Stop'

$repoRoot = $PSScriptRoot
$zstdLib = Join-Path $repoRoot 'zstd'
# Build the zstd static lib out-of-tree, under the gitignored out/, so a
# build never leaves untracked scratch inside the zstd submodule working
# tree (a dirty submodule masks a genuinely drifted gitlink SHA at review).
$libBuildDir = Join-Path $repoRoot 'out/zstd-build/x64'
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
# Computed once from $Arch and reused for both the cmake cflags below and
# the plugin msbuild /p:ZstdIisArchFlag property in step 3.
$archFlag = if ($Arch -eq 'avx2') { '/arch:AVX2' } else { '' }
# LTO compile flag: /GL when -Lto on, dropped entirely when off. Rebuilt as a
# filtered join so an empty $archFlag or $ltoCompileFlag leaves no stray
# double space in the flag string handed to cmake.
$ltoCompileFlag = if ($Lto -eq 'on') { '/GL' } else { '' }
$compileFlags = (@('/O2','/Ob2','/Oi',$archFlag,$ltoCompileFlag,'/DNDEBUG','/MT') | Where-Object { $_ }) -join ' '

$ltoDescription = if ($Lto -eq 'on') { 'LTO on (/GL + /LTCG)' } else { 'LTO off (no /GL, no /LTCG)' }

Write-Host "[1/4] Configuring libzstd (CMake) for x64 ($($Arch.ToUpper()), $ltoDescription)..." -ForegroundColor Cyan
# Remove any stale cache before reconfigure. CMake refuses to overwrite a
# cache produced by a different generator OR different flag set, so a
# previous -Arch invocation would block the next one. The plugin vcxproj
# links against ..\out\zstd-build\x64\lib\Release to match $libBuildDir;
# reusing the same dir (no arch suffix) is what keeps the link step
# finding libzstd_static.lib without a vcxproj edit on every arch-switch.
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
# disabled below. STATIC_LINKER_FLAGS=/LTCG (when -Lto on) is needed so
# libzstd_static.lib is link-time-codegen-compatible with the plugin's /GL
# objects; when -Lto off the flag is empty (no /GL objects to match).
# Pin -G "Visual Studio 17 2022": CMake's default-generator selection picks
# Ninja whenever ninja.exe is on PATH (e.g. Strawberry Perl ships ninja in
# c:\Strawberry\c\bin\ on a default PATH), but the `-A x64` platform spec is
# VS-generator-only — Ninja errors with "does not support platform
# specification". Explicit -G makes the build host-independent of whichever
# generators happen to be discoverable on PATH; the platform/architecture
# split (-A x64) and the AVX2 cflags below are unchanged.
$ltoStaticLinker = if ($Lto -eq 'on') { '/LTCG' } else { '' }
& cmake -G 'Visual Studio 17 2022' -A x64 -S (Join-Path $zstdLib 'build/cmake') -B $libBuildDir `
    "-DCMAKE_C_FLAGS_RELEASE=$compileFlags" `
    "-DCMAKE_STATIC_LINKER_FLAGS_RELEASE=$ltoStaticLinker" `
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
# Build logs are captured at detailed verbosity so the post-build axis
# verification (after step 3) can grep the actual cl.exe / link.exe
# command lines. MSBuild emits compile/link invocations only at
# /verbosity:detailed or higher.
$libBuildLog = Join-Path $libBuildDir 'libzstd-build-detailed.log'
& $msbuild (Join-Path $libBuildDir 'zstd.sln') /t:libzstd_static:Rebuild /p:Configuration=Release /p:Platform=x64 `
    "/verbosity:detailed" "/fileLogger" "/fileLoggerParameters:LogFile=$libBuildLog;Verbosity=detailed"
if ($LASTEXITCODE -ne 0) { throw "libzstd build failed" }

Write-Host "[3/4] Building zstd-IIS plugin (msbuild) for x64 with $($Arch.ToUpper()), $ltoDescription..." -ForegroundColor Cyan
# /t:Rebuild forces a clean compile of the plugin. Without it, msbuild's
# incremental build sees the .c source unchanged and skips recompile if
# only build-script flags or upstream libzstd outputs changed -- producing
# a stale DLL whose timestamp still updates.
# LTO controls for the plugin link. WholeProgramOptimization=false is the
# LOAD-BEARING control for -Lto off: MSBuild's C++ link target derives /LTCG
# from LinkTimeCodeGeneration=UseLinkTimeCodeGeneration *or* from WPO=true, so
# WPO=false is what actually guarantees no /LTCG. LinkTimeCodeGeneration is
# set to an explicit empty string (not the magic word "Default") on the off
# branch — "Default" is not a documented "off" value and could resolve to
# LTCG-on if WPO were ever true; empty is unambiguously "no LTCG option".
# With WPO=false the LinkTimeCodeGeneration value is, by design, irrelevant.
$wpo = if ($Lto -eq 'on') { 'true' } else { 'false' }
$ltcg = if ($Lto -eq 'on') { 'UseLinkTimeCodeGeneration' } else { '' }
$pluginBuildLog = Join-Path $libBuildDir 'plugin-build-detailed.log'
& $msbuild $pluginProj /t:Rebuild /p:Configuration=Release /p:Platform=x64 `
    "/p:WholeProgramOptimization=$wpo" `
    "/p:LinkTimeCodeGeneration=$ltcg" `
    "/p:ZstdIisArchFlag=$archFlag" `
    "/p:ForcedIncludeFiles=" `
    "/verbosity:detailed" "/fileLogger" "/fileLoggerParameters:LogFile=$pluginBuildLog;Verbosity=detailed"
if ($LASTEXITCODE -ne 0) { throw "plugin build failed" }

# --- Post-build axis verification -------------------------------------
# Catches a silent flag default: the requested -Arch / -Lto axis must
# actually appear in the compiler/linker command lines of BOTH the
# libzstd static lib and the plugin DLL, else the matrix would archive a
# mislabelled variant. The export-surface check below proves the DLL is
# loadable; this proves it is the variant the label claims.
Write-Host "Verifying requested axis flags emitted..." -ForegroundColor Cyan
foreach ($logPair in @(@('libzstd', $libBuildLog), @('plugin', $pluginBuildLog))) {
    $logName = $logPair[0]
    $logPath = $logPair[1]
    if (-not (Test-Path $logPath)) { throw "Axis verification: $logName build log not found at $logPath" }
    $logText = Get-Content -Raw $logPath

    # LTO: /GL must appear on compile lines and /LTCG on the link line
    # when -Lto on; both must be absent when -Lto off.
    $hasGL   = $logText -match '(?m)[/-]GL(\s|")'
    $hasLTCG = $logText -match '(?m)[/-]LTCG(\s|"|:)'
    if ($Lto -eq 'on') {
        if (-not $hasGL)   { throw "LTO verification failed ($logName): -Lto on but /GL absent from build log" }
        if (-not $hasLTCG) { throw "LTO verification failed ($logName): -Lto on but /LTCG absent from build log" }
    } else {
        if ($hasGL)   { throw "LTO verification failed ($logName): -Lto off but /GL present in build log" }
        if ($hasLTCG) { throw "LTO verification failed ($logName): -Lto off but /LTCG present in build log" }
    }

    # Arch: /arch:AVX2 must appear when -Arch avx2, and must be absent
    # when -Arch sse2 (the script emits no /arch: flag for sse2).
    $hasArchAVX2 = $logText -match '/arch:AVX2(\s|")'
    if ($Arch -eq 'avx2') {
        if (-not $hasArchAVX2) { throw "Arch verification failed ($logName): -Arch avx2 but /arch:AVX2 absent from build log" }
    } else {
        if ($hasArchAVX2) { throw "Arch verification failed ($logName): -Arch sse2 but /arch:AVX2 present in build log" }
    }
}
Write-Host "Axis verification passed (Arch=$Arch, LTO=$Lto)." -ForegroundColor Green
# ----------------------------------------------------------------------

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
Write-Host "Built:   $($info.FullName)" -ForegroundColor Green
Write-Host "Size:    $($info.Length) bytes"
Write-Host "Built:   $($info.LastWriteTime)"
Write-Host "Variant: $($Arch.ToUpper()) -- $ltoDescription"
