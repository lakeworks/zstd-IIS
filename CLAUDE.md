# zstd-IIS — IIS compression scheme plugin (lakeworks fork)

Native IIS module that adds `zstd` (Zstandard) as a compression scheme. Loads into `w3wp.exe`.

## Fork rationale

We forked upstream `kimboslice99/zstd-IIS` to fix the **Chrome 8 MB window-size limit**. The vanilla module produces zstd output with the encoder's default window size, which Chrome rejects with `net::ERR_ZSTD_WINDOW_SIZE_TOO_BIG` for larger files. Our fork caps `windowLog` at 23 (= 8 MB) so Chrome accepts the output.

This is a one-line library configuration change but it's the difference between "works for browsers" and "broken for Chrome users on larger files." The vanilla build is not safe to deploy to browser-facing traffic without this fix.

Full investigation: `D:\CC\docs\iis-compression-and-bunny-zstd.md`.

## Branches

- `main` — tracks upstream `kimboslice99/zstd-IIS` master (clean upstream snapshot)
- `production-hardening` — our fork branch with the windowLog fix + build script + this CLAUDE.md

When pulling upstream, merge into `main` first, then merge `main` into `production-hardening`.

## Upstream

- **Repo**: https://github.com/kimboslice99/zstd-IIS
- **Maintainer**: kimboslice99 (pseudonymous, IIS-focused tool builder)
- **License**: GPL-3.0 (our fork inherits)
- **Library**: Facebook zstd 1.5.7 (git submodule, commit-pinned to `f8745da6`)
- **Lineage**: Forked from saucecontrol/Brotli-IIS as starting point (issue #12, Jan 2024 collaboration).
- **Code review notes**: see top-level docs file (encoder-only, ~80 LoC plugin glue, no I/O/network/registry/subprocess; same surface as Brotli-IIS)

## Local policy

- **No precompiled DLLs from upstream.** Always build from source via `build-x64.ps1`. Upstream binaries are unsigned (verified 2026-04-29) and the 1.5.7.0 release has a supply-chain hygiene gap: the x86 DLL was uploaded 13 months after the original release, built from a different commit than the x64 DLL.
- **AVX2 baseline** in our build. Zstd's matchfinder benefits ~2-5% from AVX2; opt-in at compile time only (not runtime-detected — see facebook/zstd#3335).
- **No AVX-512.** Marginal benefit in encoder paths, server downclock risk under sustained load.

## Local fixes (relative to upstream)

1. **`src/zstd.c`**: added `ZSTD_CCtx_setParameter(cctx, ZSTD_c_windowLog, 23)` to cap zstd window at 8 MB. Required for Chrome compatibility (Kanidm #2593).
2. **Source encoding normalized to UTF-8.** Upstream files were UTF-16LE BOM-encoded. UTF-8 is the conventional encoding for C source and produces clean diffs in Git.
3. **`build-x64.ps1`**: AVX2-enabled build script (no equivalent upstream).
4. **`CLAUDE.md`** (this file).

The plugin's IIS ABI implementation (CreateCompression, DestroyCompression, Compress, Init/DeInit/Reset stubs) is otherwise unchanged from upstream.

## Build

```powershell
.\build-x64.ps1
# Output: out/zstd.dll
```

Prereqs: VS 2022 Build Tools with C++ workload, CMake on PATH (or VS-bundled), Git (for submodule).

The script:
1. Configures libzstd (CMake) for x64 with `/arch:AVX2 /GL` + LTCG linker flags.
2. Builds `libzstd_static` via msbuild.
3. Builds the plugin via msbuild with the same AVX2/LTCG flags.
4. Copies `zstd.dll` to `out/`.

## Deployment

Place at `C:\Program Files\IIS\IIS Compression\zstd.dll` (alongside Microsoft IIS Compression and Brotli-IIS, per upstream issue #1 path convention).

Register the scheme in root `applicationHost.config`.

**Add the scheme to the existing `<httpCompression>` element** — don't paste a fresh `<httpCompression>` wrapper. The element already registers `gzip` / `deflate` and the static/dynamic MIME-type tables; replacing the wrapper wipes them and breaks compression for every site on the server.

The line to add inside `<httpCompression>` is:

```xml
<scheme name="zstd" dll="C:\Program Files\IIS\IIS Compression\zstd.dll"
        dynamicCompressionLevel="104" staticCompressionLevel="107" />
```

**Compression-level encoding (zstd-IIS specific)**: IIS scheme config can't pass negative integers. zstd-IIS encodes the negative range as 0–99 and the positive range as 100+:

| IIS config value | Real zstd level | Meaning |
|---|---|---|
| 5 | -5 | fastest |
| 1 | -1 | very fast |
| 0 / 100 | 0 (= default 3) | balanced |
| 104 | 4 | balanced+ (default for dynamic) |
| 107 | 7 | better compression (default for static) |
| 117 | 17 | hard ceiling — see below |

`104` and `107` mirror the README's "middle" / "slower" suggestion; reasonable starting defaults.

**Hard ceiling at level 17 (= IIS config 117).** zstd levels 18+ have default `chainLog≥28` and `hashLog≥27`, which `ZSTD_estimateCCtxSize_usingCParams` reports as **multi-GB per CCtx**. Our windowLog=23 cap *only* overrides `windowLog`; `chainLog` / `hashLog` remain untouched because `ZSTD_adjustCParams_internal` only downsizes them when `srcSize` is known, and IIS's streaming Compress API never sets a pledged size (`zstd_compress.c:1561-1567`). At level 22 each concurrent request can attempt a ~2.5 GB allocation; the first OOM crashes `w3wp.exe` and takes down every site sharing the application pool. **Do not raise above 117 without first plumbing `ZSTD_c_chainLog` / `ZSTD_c_hashLog` overrides in `src/zstd.c`.**

**Scheme registration is server-wide.** Same as Brotli-IIS — affects all sites with `urlCompression` enabled.

## Verification after deploy

```bash
# Direct origin probe simulating Chrome
curl -sS -I -H "Accept-Encoding: gzip, deflate, br, zstd" https://your-site.example.com/wp-content/themes/oceanwp/assets/js/theme.min.js
# Expect: Content-Encoding: zstd (or br if origin still picks brotli)
```

Then test via Chrome that pages load without `net::ERR_ZSTD_WINDOW_SIZE_TOO_BIG` on large assets.

## Files

- `src/zstd.c` — `Compress`, `CreateCompression`, `DestroyCompression` (with windowLog fix)
- `src/zstd.h` — Init/DeInit/Reset stubs + includes
- `src/zstd.def` — DLL exports
- `src/zstd.rc` — Windows resource (DLL versioning, copyright)
- `src/resource.h` — resource ID constants for `src/zstd.rc`
- `src/zstdIIS.vcxproj` — Visual Studio project file
- `zstd/` — Facebook zstd library submodule (commit-pinned to `f8745da6`)
- `build-x64.ps1` — our build script
- `CLAUDE.md` — this file

## Pushing the fork to GitHub

When ready to publish:

```bash
gh auth switch -u lakeworks
gh repo create lakeworks/zstd-IIS --public --source=. --push
```

The lakeworks account is the right place — same as wk-tools — since this is generic infrastructure tooling that benefits any IIS deployment, not application-specific.
