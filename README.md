zstd IIS Compression Scheme Plugin
==================================

> **Note for users of the `lakeworks` fork** (`production-hardening` branch): this branch tightens the upstream module for browser-facing IIS deployment.
> Two operational differences from the instructions below:
> 1. **Build via `./build-x64.ps1`**, not the manual `cmake` / `msbuild` chain. The plugin vcxproj now refuses to build outside `Release|x64` (debug builds or `Release|Win32` produce a CRT-mismatched DLL that fails to load into `w3wp.exe`).
> 2. **Only IIS config values `0`–`5` and `100`–`117` are valid on this fork.** The "Setup" section below calls `0`–`99` a usable negative range and the table lists `120 121 122` — both overstate what works here. Values `6`–`99` and `118`–`122` make every `Compress` call return `E_INVALIDARG`, and the scheme stops compressing. Keep `dynamicCompressionLevel` / `staticCompressionLevel` within `0`–`5` (negative range, fastest) or `100`–`117` (positive range). See `CLAUDE.md` for the windowLog / chainLog / hashLog rationale.
>
> Full hardening status, deployment runbook, and breaking-change list: see `CLAUDE.md`.

## Build 
```
git clone https://github.com/kimboslice99/zstd-IIS.git
cd zstd-IIS
git submodule init
git submodule update
# x64
cmake -A x64 -S zstd\build\cmake -B zstd\build\cmake\x64
pushd zstd\build\cmake\x64
msbuild zstd.sln -target:libzstd_static:Rebuild /p:Configuration=Release
# x86
popd && pushd zstd\build\cmake\Win32
cmake -A Win32 -S zstd\build\cmake -B zstd\build\cmake\Win32
msbuild zstd.sln -target:libzstd_static:Rebuild /p:Configuration=Release
popd
cd src
msbuild zstdIIS.vcxproj /p:Configuration=Release;Platform=Win32
msbuild zstdIIS.vcxproj /p:Configuration=Release;Platform=x64
```
## Setup
compression levels in zstd can be negative, but we cant specify a negative here, so up to 100 is a negative range and over 100 is a positive range.

| fastest | middle | slowest |
|----------|---------|----------|
| 5 4 3 2 | 1 0 101 | 120 121 122 |

From zstd manual
```
value 0 means default, which is controlled by ZSTD_CLEVEL_DEFAULT.
Default level is ZSTD_CLEVEL_DEFAULT==3
```
```xml
<httpCompression>
    ...
    <scheme name="zstd" dll="%ProgramFiles%\path\to\zstd.dll" dynamicCompressionLevel="104" staticCompressionLevel="107" />
    ...
</httpCompression>
```

Thanks to [@saucecontrol](https://github.com/saucecontrol) for Brotli-IIS being a great starting point at getting this done
