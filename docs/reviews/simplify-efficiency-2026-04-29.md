# zstd-IIS — /simplify (efficiency lens) — 2026-04-29

## Summary

The codebase is exceptionally lean for its scope. Gate-1 fixed the critical inefficiencies (disabled unused CMake targets, moved windowLog parameter to CreateCompression, capped compression level to avoid multi-GB allocations). The current state has no build-time waste, minimal per-request cost, and tight memory bounds. The only findings are minor: one inaccurate documentation phrase and a discussion of the compressionLevel parameter pattern.

## Findings

### E-1 — Minor inaccuracy in CLAUDE.md file list description

**Files**: `CLAUDE.md:107`

**Observation**: Line 107 says "Facebook zstd library submodule (pinned to release branch)" but the `.gitmodules` file no longer declares `branch = release` (it was removed per CRIT-4 in gate-1). The submodule is pinned by commit SHA only (`f8745da6`), not by a floating branch reference. The phrase suggests a softer pin than actually exists, which could mislead a reader about the reproducibility guarantee.

**Recommendation**: Change line 107 to: `zstd/` — Facebook zstd library submodule (commit-pinned to `f8745da6`, v1.5.7).

**Priority**: P2 (documentation accuracy; no code impact)

---

### E-2 — `ZSTD_CCtx_setParameter(compressionLevel)` called once per Compress invocation

**Files**: `src/zstd.c:78`

**Observation**: The `Compress` function calls `ZSTD_CCtx_setParameter(cctx, ZSTD_c_compressionLevel, comp_lev)` on every invocation. This is per-chunk (typically 1–10 calls per response). The setParameter operation is "update-authorized" per zstd's design, so it is *allowed* mid-stream, and the IIS ABI contract passes the compression_level parameter to every Compress call, implying the caller *might* vary it. The cost is minimal (~1 CPU cycle per chunk for the parameter validation inside zstd), and the placement honors the ABI's flexibility. No action required.

**Recommendation**: This is correct by contract. No change needed. The comment at line 75–77 correctly explains the reasoning.

**Priority**: P3 (not an efficiency concern; documented as intentional)

---

## Items that are NOT findings (already addressed in gate-1)

For the parent's efficiency sanity:

- **Build time**: CMake configure disables all unused targets (PROGRAMS, SHARED, DECOMPRESSION, LEGACY_SUPPORT, DICTBUILDER, MULTITHREAD, TESTS). ✓ (OP-3)
- **Binary size**: No dead code pulled in from zstd. LTCG enabled on both libzstd_static link and plugin link. ✓ (OP-3, OP-6)
- **Runtime hot path**: `ZSTD_CCtx_setParameter(windowLog, 23)` moved to `CreateCompression` (not in per-chunk loop). ✓ (OP-1)
- **Per-request memory**: windowLog=23 cap is in place and verified early (CreateCompression). Compression level ceiling at 17 documented in CLAUDE.md to prevent multi-GB allocations. ✓ (CRIT-3 mitigation)
- **Build verification**: Post-build export check added; DLL must have all six IIS-ABI exports before script succeeds. ✓ (OP-10)
- **CMake targets disabled**: No unused executables, shared libs, decompression, legacy decoders, dictbuilder, or multithread code are built. ✓ (OP-3)
- **Linker flags**: `/GL` (Whole Program Optimization) passed to both libzstd_static and plugin link; `/LTCG` (LinkTimeCodeGeneration) passed via msbuild properties. ✓

---

## Conclusion

The zstd-IIS module is production-ready from an efficiency perspective. The ~100 LoC of plugin code has negligible CPU/memory cost per request. The supporting infrastructure (build script, CMake config, vcxproj) is optimized correctly. No further efficiency work is needed.

