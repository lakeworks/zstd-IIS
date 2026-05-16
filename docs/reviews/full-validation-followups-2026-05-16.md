---
status: deferred-items
arc: full-validation
repo: zstd-IIS
date: 2026-05-16
---

# zstd-IIS full-validation — deferred gate-1 items

Gate-1 (adversarial + codex) Critical/Operational findings were all addressed
in `adversarial follow-up:` / `codex follow-up:` commits this session. The
items below are deferred with a stated cost and a trigger-to-build, per the
cadence §"Review findings discipline".

## [-] windowLog is an unconditional override, not a level-aware cap

**Source:** gate-1 codex (`full-validation-codex-2026-05-16`, Operational —
"Avoid forcing 8 MiB windows for all levels").

`CreateCompression` sets `ZSTD_c_windowLog = 23` unconditionally. For every
accepted level below 17 the level's *default* windowLog is smaller — per the
zstd 1.5.7 default cParams table (`zstd/lib/compress/clevels.h`), levels 1–8
default to windowLog 19–22 (≤ 4 MiB), and only level 17 reaches 23 (8 MiB).
The production config (IIS 104/107 = zstd 4/7) has default windowLog 21
(2 MiB); the override forces an 8 MiB window buffer per concurrent CCtx — a
~4× window-memory regression for the recommended deployment.

**Why deferred (concrete cost).** The genuine fix is a *cap*: query
`ZSTD_getCParams(level, 0, 0).windowLog` and set `min(default, 23)`. But the
level is known only in `Compress`, not `CreateCompression`; windowLog must be
set before streaming starts and is not in zstd's update-authorized list, so it
cannot change after the first `Compress` call. A correct cap therefore needs
either (a) a context-wrapper struct tracking first-call state so windowLog can
be set level-aware on the first `Compress` call, or (b) the deliberately-
ignored-error pattern. Both change what the opaque `context` pointer is (a
cascading edit across `CreateCompression` / `Compress` / `DestroyCompression`)
and change the wire output — smaller window in the frame header for sub-17
levels. That is a Critical-class change to a production-deployed `w3wp.exe`
DLL and warrants its own arc with a dedicated adversarial pass on streaming-
state correctness (mid-stream level changes, first-call detection, the
ignored-error question). Landing it as a gate-1 follow-up commit would be the
"bandaid when rework is needed" anti-pattern.

The windowLog=23 override also pins the window against upstream cParams-table
drift (if a future zstd bumped level-17's default windowLog past 23, Chrome
compat would break silently) — the cap fix must preserve that property.

**Trigger-to-build:** open a dedicated `windowlog-cap` arc when the bench's
build-matrix run produces per-level concurrency-memory data, or sooner if
co-tenant `w3wp` memory pressure is observed in production.

## [-] ResetCompression is a no-op stub

**Source:** gate-1 adversarial (Polish).

`src/zstd.h` `ResetCompression` returns `S_OK` without resetting the CCtx —
correct only under the "IIS 7.0 requires the export but never calls it"
assumption. A one-line `ZSTD_CCtx_reset(context, ZSTD_reset_session_only)`
(NULL-guarded) would make the export self-consistent regardless.

**Why deferred:** adds semantics to an ABI export; low-risk but best landed
with the windowLog arc (same files, same re-test surface) rather than as an
isolated Polish commit.

**Trigger-to-build:** fold into the `windowlog-cap` arc.

## [-] zstd.rc not fork-stamped

**Source:** gate-1 adversarial (Polish).

`src/zstd.rc` still carries upstream `FILEVERSION 1,5,7,0`, `LegalCopyright
"Copyright © 2024 kimboslice99"`, `OriginalFilename zstd.dll`. A hardened-fork
build is indistinguishable from a vanilla upstream build in the DLL's
file-properties. GPL-3.0 requires preserving the upstream copyright notice, so
the fix *adds* a fork line — it does not replace.

**Why deferred:** needs a versioning decision (the fork's own version string).

**Trigger-to-build:** address as part of the "Pushing the fork to GitHub"
step in `CLAUDE.md`.

## Items checked and cleared (no action)

- **`src/zstd.rc` encoding** (adversarial Polish). Verified UTF-8: the file's
  first bytes are `#include "winres.h"` (ASCII), no `FF FE` BOM. The
  `CLAUDE.md` "Source encoding normalized to UTF-8" claim holds for `zstd.rc`.

## Gate-2 /simplify + gate-3 record

Gate-2 (/simplify, 3 lenses) returned 0 Critical / 0 Operational; 8 Polish
total (reuse 3, quality 2, efficiency clean). Four trivially-fixable items
were addressed as `simplify follow-up:` commits — build-x64.ps1 `/arch:AVX2`
computed once, the CLAUDE.md 118–122 upgrade-instruction de-duplicated, the
CLAUDE.md item-2 level-22 phrasing clarified, the vcxproj Debug link path
pointed out-of-tree. One Polish item is deferred:

- **[-] Level-17 ceiling numbers duplicated `src/zstd.c` ↔ `CLAUDE.md`.**
  Gate-2 reuse lens recommends trimming `CLAUDE.md`'s "Hard ceiling" paragraph
  to defer the `chainLog`/`hashLog` derivation to the `src/zstd.c` comment
  (which must stay self-contained as a cherry-pick target). **No action,
  by design:** `CLAUDE.md`'s "Hard ceiling" section is operator-facing and the
  numeric rationale belongs inline there — an operator reading it should not
  have to open C source. The two copies were set consistent by gate-1 commit
  `802e931`; they are not drift-prone in a harmful way (both cite the pinned
  zstd 1.5.7 `clevels.h`). Re-evaluate only if the zstd submodule is bumped.

Gate-3 self-audit:

- `multi-vantage-required: no` — the arc touched a C-comment rewrite, a
  whitespace reindent, docs, a build script and a vcxproj flag; no
  service-identity / kernel / FSCTL / ABI-surface change (§Delegation
  triggers a–g all negative). The `src/zstd.c` edits are comment + whitespace
  only — the compression ABI code is unchanged.
- `skip-mini-adversarial: gate-2 fixes are docs + a build-script local
  consolidation + a 1-line vcxproj path — no import-time call site, no
  guard/refusal/validator reshape, no cross-file flatten.`
- INTROSPEC: no mental-model shift warranting an entry.
- Rule sync: no `§NN` spec rules in this fork; none cited or changed.
