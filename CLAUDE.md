# zstd-IIS — IIS compression scheme plugin (lakeworks fork)

Native IIS module that adds `zstd` (Zstandard) as a compression scheme. Loads into `w3wp.exe`.

## Fork rationale

We forked upstream `kimboslice99/zstd-IIS` to fix the **Chrome 8 MB window-size limit**. The vanilla module produces zstd output with the encoder's default window size, which Chrome rejects with `net::ERR_ZSTD_WINDOW_SIZE_TOO_BIG` for larger files. Our fork caps `windowLog` at 23 (= 8 MB) so Chrome accepts the output.

This is a one-line library configuration change but it's the difference between "works for browsers" and "broken for Chrome users on larger files." The vanilla build is not safe to deploy to browser-facing traffic without this fix.

Full investigation: `./docs/iis-compression-and-bunny-zstd.md`.

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
- **AVX2 baseline** in our build. **Note: we have not benchmarked the actual perf impact on our workload.** Zstd's row-based matchfinder is the part most likely to benefit from AVX2; how much depends on the level + input shape. Public benchmarks circulating on the zstd issue tracker (facebook/zstd#3335) suggest a few percent at default levels, but those aren't measurements on our workload (HTTP responses out of a WordPress origin) and the zstd issue itself argues for *runtime* dispatch precisely because compile-time AVX2 is hard to evaluate generically. We keep `/arch:AVX2` because all deployment targets are post-2017 silicon — but the overlay is worth dropping if a benchmark on representative response bodies doesn't show a non-trivial gain.
- **No AVX-512.** Marginal benefit in encoder paths, server downclock risk under sustained load.

## Local fixes (relative to upstream)

Source changes in `src/zstd.c` and `src/zstd.h`, each on a separate single-issue commit suitable for upstream cherry-pick:

1. `windowLog` cap at 23 (8 MiB) in `CreateCompression` — Chrome compatibility (`net::ERR_ZSTD_WINDOW_SIZE_TOO_BIG`, Kanidm #2593).
2. Compression-level upper ceiling at 17 in `Compress` — zstd levels 18+ scale `chainLog` / `hashLog` up to a ~0.6 GiB match-state working set per CCtx at level 22, which the streaming Compress API can't downsize (chainLog/hashLog stay uncapped). See the "Compression-level encoding" table below.
3. NULL-guards on context + buffer-pointer parameters in `Compress`.
4. NULL-guard on the context out-pointer in `CreateCompression`.
5. `ZSTD_CCtx_setParameter` return-value checks in both `CreateCompression` and `Compress`.
6. Negative `LONG` buffer-size rejection (would otherwise size_t-cast to ~16 EB and walk out-of-bounds).
7. INT_MIN UB guard on the IIS-config-to-zstd-level translation.
8. CCtx reset on `ZSTD_compressStream2` error so a reused context can't leak state between responses.
9. LONG_MAX truncation guard on `*input_used` / `*output_used` writes.
10. Scoped `UNREFERENCED_PARAMETER` instead of global `#pragma warning (disable: 4100)`.

Other local additions:

11. **Source encoding normalized to UTF-8.** Upstream files were UTF-16LE BOM-encoded. UTF-8 is the conventional encoding for C source and produces clean diffs in Git.
12. **`src/zstdIIS.vcxproj`**: `/arch:AVX2` baked into Release|x64 ClCompile.AdditionalOptions; static MultiThreaded CRT; `RunCodeAnalysis=false`; `<Target>` that fails the build if `Configuration|Platform != Release|x64`.
13. **`.gitmodules`**: removed the `branch = release` line. The recorded gitlink SHA (`f8745da6`) is what actually pins the submodule — Git always honours it on `git submodule update`. Removing `branch = release` does NOT prevent `git submodule update --remote` from advancing the submodule (with no `branch` line, `--remote` follows the remote's default HEAD instead). The change clears a misleading "follow this branch" hint that conflicted with our commit-pin policy; the only real protection against `--remote` advancing the submodule is to not run `--remote`. Documented update procedure: `cd zstd && git fetch && git checkout <verified-tag>` followed by `git add zstd && git commit` from the repo root.
14. **`build-x64.ps1`**: AVX2-enabled build script with disabled-target list (no zstd CLI / shared lib / decompression / legacy decoders / dictBuilder / threading / tests built), `/t:Rebuild` on plugin step, and post-build `dumpbin /exports` verify against the IIS ABI.
15. **`CLAUDE.md`** (this file).

The IIS ABI surface (`InitCompression`, `DeInitCompression`, `CreateCompression`, `ResetCompression`, `Compress`, `DestroyCompression`) and the `.def` exports are otherwise unchanged from upstream.

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

**Hard ceiling at level 17 (= IIS config 117).** zstd's higher levels scale `chainLog` / `hashLog` up steeply. Per the zstd 1.5.7 default cParams table (`zstd/lib/compress/clevels.h`), level 17 is `chainLog=23` / `hashLog=22` and level 22 (max) is `chainLog=27` / `hashLog=25`. The match-state tables alone cost `(1<<chainLog)*4 + (1<<hashLog)*4` bytes — roughly **48 MiB at level 17 but ~0.6 GiB at level 22**, and the `btultra2` optimal parser at levels 19+ adds more working set on top. Our windowLog=23 cap *only* overrides `windowLog`; `chainLog` / `hashLog` remain untouched because `ZSTD_adjustCParams_internal` only downsizes them when `srcSize` is known, and IIS's streaming Compress API never sets a pledged size. A handful of concurrent high-level requests can exhaust `w3wp.exe`'s address space; the first OOM crashes the process and takes down every site sharing the application pool. **Do not raise above 117 without first plumbing `ZSTD_c_chainLog` / `ZSTD_c_hashLog` overrides in `src/zstd.c`.**

**Breaking change vs. upstream**: the upstream `kimboslice99/zstd-IIS` README documents `120`, `121`, `122` as valid "slowest" values. With this fork's hard ceiling, those configs cause every `Compress` call to return `E_INVALIDARG` and the affected scheme stops compressing entirely. If you're upgrading from upstream and your `applicationHost.config` has any `dynamicCompressionLevel` or `staticCompressionLevel` between 118 and 122, lower it to 117 *before* deploying the new DLL. The failure is loud (no compression, no graceful fallback to identity for that scheme — IIS surfaces the E_INVALIDARG to the response pipeline) so you'll see it on the first request, but it's still a config gotcha worth catching pre-deploy.

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
