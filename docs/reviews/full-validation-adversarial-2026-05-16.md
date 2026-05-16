---
status: findings
arc: full-validation
gate: 1-adversarial
repo: zstd-IIS
critical: 0
operational: 4
polish: 5
---

# zstd-IIS — full-repo adversarial validation (gate 1/4)

**Phase 1 classification.** Fork of a native IIS compression-scheme plugin
(`lakeworks/zstd-IIS`, branch `production-hardening`, base `9d1e28d` → HEAD,
~40 commits). The DLL loads into `w3wp.exe` and is reachable by every HTTP
request to any site on the host with `urlCompression` enabled. Blast radius is
**process-wide on shared infrastructure**: a crash, OOM, or wire-corruption in
this code takes down every co-tenant site sharing the app pool, or serves
corrupt response bodies. Probe classes exercised: external-API contract (zstd C
API + IIS scheme ABI), integer-overflow/UB, error-path/resource-state,
build-script correctness, supply-chain (submodule pin), docs-drift.

**Host profile.** Production WordPress origin behind IIS on Windows Server.
Encoder-only plugin, ~80 LoC of glue; no I/O / network / registry / subprocess.
Read-only review — code was not built or run.

## Summary (top-3)

1. **[O1] The memory-hazard rationale that the entire level-17 ceiling rests on
   is factually wrong.** Both `src/zstd.c:74-85` and `CLAUDE.md:103` claim zstd
   levels 18+ have "default `chainLog≥28` and `hashLog≥27`" and that a level-22
   request "can attempt a ~2.5 GB allocation". The actual zstd 1.5.7 cParams
   table (`zstd/lib/compress/clevels.h`) tops out at `chainLog=27, hashLog=25`
   at level 22 — nothing reaches 28/27. The ceiling itself is defensible, but it
   is justified by fabricated numbers, and a future maintainer who checks the
   table will (correctly) conclude the doc is wrong and may then mistrust or
   relax the ceiling.

2. **[O1] `comp_lev` translation has an undocumented dead/contradictory band and
   a level-0 collision.** IIS config values `1..5` map to zstd `-1..-5`;
   `6..99` map to zstd `-6..-99`, all of which are rejected by the `comp_lev <
   -5` guard — so `Compress` returns `E_INVALIDARG` and the scheme silently
   stops compressing for any config value in `6..99`. Values `0` and `100` both
   map to zstd level 0. Neither the README level table nor `CLAUDE.md` tells an
   operator that `6..99` is a hard-fail band.

3. **[O1] Untracked build scratch inside the `zstd` submodule + a `.gitignore`
   that does not cover it.** `zstd/build/cmake/x64/` is present and untracked;
   `build-x64.ps1` writes there and `git status` reports the submodule as dirty
   (`?? zstd`). The repo `.gitignore` cannot reach inside a submodule, so every
   build leaves the submodule in a modified state, which masks a genuinely
   drifted submodule pin during review.

---

## Critical

None. The hardening pass is substantively correct: the windowLog=23 cap is set
as an explicit cParams override in `CreateCompression` and survives every
mid-stream `compressionLevel` change (verified against
`ZSTD_getCParamsFromCCtxParams` → `ZSTD_overrideCParams` in
`zstd/lib/compress/zstd_compress.c:1637`). NULL-guards, the INT_MIN negation
guard, the negative-LONG buffer rejection, the LONG_MAX truncation guard, and
the post-error `ZSTD_CCtx_reset` are all present and ordered correctly (guards
fire before the `size_t` cast). The `ZSTD_e_continue`/`ZSTD_e_end` direction is
correct and matches the Brotli-IIS reference — note this *fixes* an upstream bug
in `9d1e28d` which had the directive inverted.

## Operational

### [O1] Level-ceiling memory rationale cites numbers that do not exist in zstd 1.5.7

- **Probe**: external-API contract / docs-drift.
- **Failure mode**: `src/zstd.c:74-85` and `CLAUDE.md:103` state that levels 18+
  have "default `chainLog≥28` and `hashLog≥27`" and that level 22 attempts
  "~2.5 GB". The pinned submodule's actual table
  (`zstd/lib/compress/clevels.h`, "default" row) is: level 17 → `C=23,H=22`;
  level 18 → `C=23,H=22`; level 22 → `C=27,H=25`. The matchState tables are
  `(1<<chainLog)*4 + (1<<hashLog)*4` bytes, so level 22 is roughly
  `512 MiB + 128 MiB` ≈ 0.7 GiB of match tables (plus opt-parser space and the
  windowLog-capped 8 MiB window) — a real hazard, but well under half the
  claimed 2.5 GB, and the cited `chainLog≥28`/`hashLog≥27` values are simply
  wrong. A maintainer auditing the ceiling against the table will find the
  justification false and may relax or remove the guard.
- **How to reproduce**: `sed -n '/ZSTD_defaultCParameters/,/^};/p'
  zstd/lib/compress/clevels.h` — read the W,C,H columns for levels 17–22; none
  reach C=28 or H=27.
- **Fix shape**: Replace the fabricated specifics in both the code comment and
  `CLAUDE.md` with the real numbers (e.g. "level 22 default `chainLog=27,
  hashLog=25` → roughly 0.7 GiB of match-state tables per concurrent CCtx;
  level 17 is `chainLog=23, hashLog=22` → ~48 MiB"). Keep the ceiling; fix only
  the rationale so it stays auditable. Optionally state the level-17 figure
  explicitly so the chosen ceiling is self-justifying.

### [O1] `comp_lev` translation: IIS config band `6..99` is a silent hard-fail, undocumented

- **Probe**: external-API contract / interface-bug.
- **Failure mode**: `src/zstd.c:66` —
  `comp_lev = compression_level > 99 ? compression_level - 100 : -compression_level`.
  For IIS config `6..99`, `comp_lev` is `-6..-99`, which the bounds check at
  `src/zstd.c:86` (`comp_lev < -5`) rejects with `E_INVALIDARG`. Per
  `CLAUDE.md:105` the scheme then "stops compressing entirely" and IIS surfaces
  the error to the pipeline. So any operator who sets `dynamicCompressionLevel`
  to a value in `6..99` — a plausible typo or a misread of "0–99 is the negative
  range" — gets a non-compressing scheme on the first request. The README level
  table (`README.md:33-35`) only shows `5 4 3 2 1`; it never says `6..99` is
  invalid. `CLAUDE.md:90-99` documents the encoding but the table jumps from
  `5` straight to `0/100` with no note that `6..99` is a dead band.
- **How to reproduce**: trace `compression_level = 50` →
  `comp_lev = -50` → `comp_lev < -5` true → `return E_INVALIDARG`.
- **Fix shape**: Either (a) document the dead band explicitly in both the README
  table and `CLAUDE.md` ("IIS config 6–99 is rejected — the usable negative
  range is 1–5 only"), or (b) clamp instead of rejecting for the negative range
  (less surprising, but changes semantics — decide deliberately). At minimum the
  docs must not present `0..99` as a uniformly valid "negative range" when
  `6..99` hard-fails. Also note the `0`/`100` collision (both → level 0) in the
  table footnote so it is not read as a bug.

### [O1] `zstd` submodule left dirty by every build; `.gitignore` cannot cover it

- **Probe**: build-script correctness / supply-chain.
- **Failure mode**: `git status` reports `?? zstd` because
  `zstd/build/cmake/x64/` exists as untracked content inside the submodule
  working tree. `build-x64.ps1:32,83` creates and populates that directory on
  every run. A submodule's dirty state cannot be silenced by the superproject
  `.gitignore` (the submodule has its own ignore rules). Consequence: a reviewer
  running `git status` on the superproject sees the submodule as modified on
  every build and learns to ignore that signal — which masks the case that
  actually matters, a genuinely drifted submodule gitlink SHA (the only real
  pin per `CLAUDE.md:54`). It also risks `git submodule foreach` / cleanup
  scripts deleting build output unexpectedly.
- **How to reproduce**: `cd zstd && git status --short` → `?? build/cmake/x64/`.
- **Fix shape**: Build out-of-tree — point `build-x64.ps1`'s `$libBuildDir` at a
  superproject-level path under `out/` (already gitignored) instead of inside
  the submodule, e.g. `out/zstd-build/cmake/x64`. The plugin vcxproj's
  hard-coded link path (`..\zstd\build\cmake\$(Platform)\lib\Release`,
  `src/zstdIIS.vcxproj:107`) would then also need to be parameterised or the
  static lib copied to the expected location. Alternatively add
  `build/` to `zstd/.git/info/exclude` as a documented host-setup step — but
  the out-of-tree build is the clean fix and keeps the submodule pristine for
  pin auditing.

### [O1] `resource.h` is referenced by the build but absent from the repo

- **Probe**: build-script correctness.
- **Failure mode**: `src/zstdIIS.vcxproj:115` declares
  `<ClInclude Include="resource.h" />` and `CLAUDE.md:125` lists
  `src/resource.h` as a project file ("resource ID constants for `src/zstd.rc`").
  The file does **not exist** in `src/` and is **not tracked** (`git ls-files
  src/` returns only `zstd.c/.def/.h/.rc/.vcxproj`). `src/zstd.rc` includes
  `winres.h` (SDK header) and defines no custom resource IDs, so the build
  currently succeeds — `ClInclude` only adds a header to the project's file
  list and IDE intellisense, it does not force a compile. But the vcxproj entry
  plus the `CLAUDE.md` claim assert a file that is not there: a clean clone
  contradicts its own manifest, and any future `.rc` edit that adds a
  `#include "resource.h"` will fail the resource compile with no obvious cause.
- **How to reproduce**: `git ls-files src/` vs `grep resource.h
  src/zstdIIS.vcxproj CLAUDE.md`.
- **Fix shape**: Decide and make consistent — either commit a minimal
  `src/resource.h` (if `zstd.rc` is meant to use custom IDs), or delete the
  `<ClInclude Include="resource.h" />` line from the vcxproj and the
  `src/resource.h` bullet from `CLAUDE.md:125`. The `.rc` as written needs no
  `resource.h`, so removal is the lower-risk path.

## Polish

### [P1] `CLAUDE.md:121` "Files" section claims `windowLog fix` lives in `Compress`

`CLAUDE.md:121` reads "`src/zstd.c` — `Compress`, `CreateCompression`,
`DestroyCompression` (with windowLog fix)". The windowLog cap was deliberately
moved out of `Compress` into `CreateCompression` (commit `1057b34`); the
parenthetical's placement implies the fix is still in the hot path. Move
"(with windowLog fix)" to sit beside `CreateCompression`.

### [P1] `src/zstd.rc` is still UTF-16LE — encoding-normalization claim remains partially overstated

`CLAUDE.md:52` says "Source encoding normalized to UTF-8. Upstream files were
UTF-16LE BOM-encoded." Commit `ee070ea` converted `zstd.rc` to UTF-8 per its
subject, but the working-tree file's first bytes were not re-verified in this
pass against the claim — and the prior `/simplify` quality finding Q-2 flagged
exactly this. Confirm `zstd.rc` is actually UTF-8 (no `FF FE` BOM) or scope the
claim to `.c/.h` only. (`zstd.rc` carries no non-ASCII except the `©` in the
copyright string, so an accidental mojibake there is the only real risk.)

### [P1] `.editorconfig` declares `indent_style = tab`; `src/zstd.c` is space-indented throughout

`.editorconfig` at repo root sets `indent_style = tab` but the entire hardened
`src/zstd.c` uses four-space indentation. Either the file or the `.editorconfig`
should be brought into agreement so an editor honouring `.editorconfig` does not
reintroduce tabs on the next edit. No runtime impact.

### [P1] `ResetCompression` correctness depends on an undocumented IIS assumption

`src/zstd.h:23` — `ResetCompression` is a no-op stub returning `S_OK`, with the
comment "required for IIS 7.0 (only) but never actually called". If a future
IIS version *did* call it, the no-op leaves the CCtx mid-frame: a subsequent
`Compress` would continue an already-started stream rather than starting fresh,
producing a corrupt response body. The stub is correct *only* under the
"never called" assumption. Low likelihood, but a one-line
`ZSTD_CCtx_reset(context, ZSTD_reset_session_only)` (with a NULL-guard) would
make the export self-consistent regardless. Currently no `Compress`/`Reset`
ordering invariant is enforced in code.

### [P1] `zstd.rc` version strings (`1.5.7.0`, copyright "2024 kimboslice99") not fork-stamped

`src/zstd.rc` still carries upstream's `FILEVERSION 1,5,7,0`,
`LegalCopyright "Copyright © 2024 kimboslice99"`, and `OriginalFilename
zstd.dll`. The fork has a substantial hardening delta but the built DLL's
file-properties version is indistinguishable from an upstream build. For a
DLL deployed into `w3wp.exe` on a production host, an operator inspecting
`zstd.dll` properties cannot tell a hardened fork build from a vanilla upstream
one. Consider a fork-distinct version/product string (GPL-3.0 requires
preserving the upstream copyright notice, so *add* a fork line, do not replace).

---

## Items checked and cleared

- windowLog=23 cap enforced on every encoder path: it is set once in
  `CreateCompression` as an explicit `cParams` override; `ResetCompression` is a
  no-op so cannot lose it; mid-stream `compressionLevel` changes go through
  `ZSTD_overrideCParams` which re-applies the explicit windowLog. Verified
  against `zstd/lib/compress/zstd_compress.c:1637-1650`.
- `ZSTD_e_continue`/`ZSTD_e_end` direction is correct (non-empty input →
  continue, empty → end) and matches the Brotli-IIS reference; this *corrects*
  an inverted directive in upstream base `9d1e28d`.
- S_OK/S_FALSE return logic (`input_buffer_size || bytes_left ? S_OK :
  S_FALSE`) is correct for the IIS feed/flush loop, including the
  output-buffer-full-mid-stream and multi-call-final-flush cases.
- INT_MIN UB guard: `compression_level < 0` rejected before the unary negation
  at `src/zstd.c:65-66` — correct, rules out `-INT_MIN`.
- Negative-LONG buffer rejection and the NULL-pointer guards fire before the
  `size_t` casts (`src/zstd.c:55-57` precede line 100).
- LONG_MAX truncation guard (`src/zstd.c:119`) fires before the `(LONG)` casts
  and resets the CCtx on the error path.
- `ZSTD_CCtx_setParameter` return values are checked in both `CreateCompression`
  and `Compress`.
- Post-error `ZSTD_CCtx_reset(..., ZSTD_reset_session_only)` on
  `ZSTD_compressStream2` failure leaves the context in a known state.
- `build-x64.ps1`: VS-17-2022 generator pin, `vswhere -products *`, `/MT`
  inline in `CMAKE_C_FLAGS_RELEASE`, disabled unused zstd targets, fail-fast
  `EnsureRelease64` target, post-build `dumpbin /exports` ABI verification —
  all present and correct. `/DNDEBUG` is preserved in `$compileFlags`.
- `.gitmodules` `branch = release` removed; submodule gitlink pinned to
  `f8745da6` (zstd v1.5.7) — the real pin. Doc (`CLAUDE.md:54`) correctly
  explains the `--remote` nuance.
