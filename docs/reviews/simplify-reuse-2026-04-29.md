# zstd-IIS — /simplify (reuse lens) — 2026-04-29

> Captured by parent (agent ran in read-only Explore mode and couldn't write the file directly).
> Findings span both forks — the brief asked for cross-fork reuse comparison.

## Summary

Five consolidation opportunities, all incremental improvements rather than blocking issues. Several have caveats the agent didn't surface (Brotli-IIS is currently source-mod-free; the master doc is in a private repo and can't be referenced from public-fork CLAUDE.md files); parent will weigh those during gate-2 integration.

## Findings

### R-1 — IIS scheme stub functions replicated identically across both forks

**Files**:
- `D:\CC\zstd-IIS\src\zstd.h` lines 18-25
- `D:\CC\Brotli-IIS\src\brotli.h` lines 18-25 (identical)

**Observation**: Three IIS-scheme stub exports (InitCompression, DeInitCompression, ResetCompression) are copy-pasted identically. These are part of the IIS ABI contract (required but unused by the compression libraries), not library-specific code.

**Recommendation**: Extract these to a shared header and `#include` from both project header files.

**Priority**: P1

**Parent caveat**: Brotli-IIS currently has zero source modifications (per its CLAUDE.md "Local policy"). Adding a shared header is a source mod. Either (a) accept the mod and update CLAUDE.md, or (b) keep the duplication for upstream-cleanliness. Decision pending gate-2 synthesis.

---

### R-2 — Function header comments are identically phrased; belong in shared documentation

**Files**:
- `D:\CC\zstd-IIS\src\zstd.c` lines 6, 33, 39
- `D:\CC\Brotli-IIS\src\brotli.c` lines 6, 14, 21

**Observation**: Three function comments describing the IIS contract are copy-pasted. These describe IIS spec, not library-specific behavior.

**Recommendation**: Document once in master doc, reference from `.c` files.

**Priority**: P2

**Parent caveat**: Inline comments are MORE useful than a doc reference for someone reading the source. Master doc is private, so an external reader of a public fork can't follow the reference. Likely reject.

---

### R-3 — Pragma warning suppression pattern repeated in both .h files

**Files**:
- `D:\CC\zstd-IIS\src\zstd.h` line 12
- `D:\CC\Brotli-IIS\src\brotli.h` line 12

**Observation**: Both files use global `#pragma warning (disable: 4100)`. Gate-1 review flagged this as overly broad in zstd-IIS (POL-5). Same pattern in Brotli-IIS.

**Recommendation**: Replace with `UNREFERENCED_PARAMETER(context)` at the specific unused parameter sites; remove the global pragma.

**Priority**: P1

**Parent caveat**: Real polish improvement. zstd-IIS can land it freely. Brotli-IIS source-mod policy applies — could land or skip per the same trade-off as R-1.

---

### R-4 — "Local policy" documentation duplicated across CLAUDE.md files

**Files**:
- `D:\CC\zstd-IIS\CLAUDE.md` "Local policy" section
- `D:\CC\Brotli-IIS\CLAUDE.md` "Local policy" section
- `D:\CC\docs\iis-compression-and-bunny-zstd.md`

**Observation**: Both project CLAUDE.md files repeat the supply-chain rationale, AVX2 baseline framing, and hardware support matrix.

**Recommendation**: Move shared rationale to master doc; reference from each fork's CLAUDE.md.

**Priority**: P1

**Parent caveat**: **Reject as written.** Master doc lives in a private downstream-tracking repo; public-fork CLAUDE.md cannot reference a private repo. The right form is each public-fork CLAUDE.md being self-contained. Some duplication is acceptable for that. Could trim verbatim copy if both files diverge in non-meaningful ways, but moving to a private master doc is wrong.

---

### R-5 — Build script vswhere/dumpbin lookup pattern is reusable

**Files**:
- `D:\CC\zstd-IIS\build-x64.ps1` lines 25-31, 92-101

**Observation**: vswhere + dumpbin discovery is reusable across PowerShell build scripts.

**Recommendation**: Extract to shared module.

**Priority**: P2

**Parent caveat**: Brotli-IIS uses vcpkg, not the same MSVC tool discovery. The two scripts have genuinely different shapes. Premature abstraction. Skip.
