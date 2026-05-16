---
status: findings
arc: full-validation
gate: 2-simplify
lens: reuse
repo: zstd-IIS
critical: 0
operational: 0
polish: 3
---

# zstd-IIS — gate-2 /simplify, reuse lens (full-validation)

**Scope.** Gate-1 follow-up commits `ad2c83f..HEAD` on `production-hardening`
(8 commits, 6 source/doc files: `src/zstd.c`, `CLAUDE.md`, `README.md`,
`build-x64.ps1`, `src/zstdIIS.vcxproj`, `.editorconfig`). Reuse lens only:
duplicated prose that drifted or could drift, the same numbers/facts stated in
multiple places, repeated build-script logic, copy-pasted comment blocks. This
is polish on a base whose Critical/Operational findings were already fixed in
this commit range — no behaviour change, no gate-1 re-litigation.

**Upstream-tracking constraint applied.** This is a fork that explicitly
minimises divergence (`CLAUDE.md:18`: merge upstream into `main`, then into
`production-hardening`; each source change is "suitable for upstream
cherry-pick"). Every consolidation idea below is weighed against
upstream-merge-cleanliness — and in the only place where extracting a "helper"
would matter, the recommendation is **do not consolidate**.

## Verdict

The diff is **substantively reuse-clean**. The level-encoding rationale that the
diff touched in three places (`src/zstd.c`, `CLAUDE.md`, `README.md`) is, after
this commit range, **mutually consistent** — the gate-1 follow-up that replaced
the fabricated `chainLog≥28`/`hashLog≥27` / "~2.5 GB" numbers updated all three
copies in lockstep (`802e931`, `4aefab7`). No drifted duplicate was found. The
findings below are all Polish: facts that are *correct today* but live in 2–4
unsynchronised locations and will drift on the next edit.

## Critical

None.

## Operational

None.

## Polish

### [P1] The level-17 ceiling rationale is duplicated near-verbatim across `src/zstd.c` and `CLAUDE.md` — three copies of the same hardware numbers

The same fact set — "level 17 is `chainLog=23`/`hashLog=22`, level 22 is
`chainLog=27`/`hashLog=25`, match-state cost `(1<<chainLog)*4 + (1<<hashLog)*4`
≈ 48 MiB / 0.6 GiB, `btultra2` adds more, windowLog cap doesn't downsize
chainLog/hashLog because IIS sets no pledged size" — now appears in full at:

- `src/zstd.c:74-90` (the `Compress` bound-check comment)
- `CLAUDE.md:111` ("Hard ceiling at level 17" paragraph)
- and in condensed form at `CLAUDE.md:40` ("~0.6 GiB match-state working set per
  CCtx at level 22").

This is *consistent right now* — the gate-1 follow-up `802e931` correctly
updated all three. But it is three copies of the same 1.5.7-cParams-table
numbers (`chainLog=27`, `hashLog=25`, 0.6 GiB) plus the same mechanism prose.
When zstd's `clevels.h` table changes on the next submodule bump, or a
maintainer revisits the figures, all three must move together; `src/zstd.c:87`
even instructs the reader that "the code enforces this so the doc's 'hard
ceiling at 117' claim in CLAUDE.md cannot drift" — yet the *rationale* (not the
ceiling value) is exactly what is duplicated and can drift.

- **File:line**: `src/zstd.c:74-90`, `CLAUDE.md:40`, `CLAUDE.md:111`.
- **Fix shape — and the explicit recommendation NOT to extract**: do **not**
  collapse the `src/zstd.c` comment into a doc pointer. `src/zstd.c` is a
  cherry-pick target for upstream (`CLAUDE.md:37`); a self-contained comment
  that explains *why this fork rejects >17* is exactly what upstream needs to
  evaluate the patch, and a "see CLAUDE.md" pointer in the source would be a
  dead link upstream. Keep the source comment authoritative and complete.
  Instead, **trim `CLAUDE.md:111` to defer to the source**: replace the
  re-derivation of the hardware numbers with one line — "Rationale (cParams
  table, match-state cost arithmetic): see the `Compress` bound-check comment in
  `src/zstd.c`." The operator-facing facts CLAUDE.md must keep are the IIS-config
  consequences (117 = ceiling, 118–122 rejected, upgrade audit), not the
  zstd-internal `chainLog`/`hashLog` derivation. That removes the C-source ↔
  CLAUDE.md duplication while keeping the cherry-pickable comment intact and the
  doc pointer valid *within the fork* (where CLAUDE.md ships). Net: one
  authoritative copy of the numbers, in the file that must carry them anyway.

### [P1] Three documents independently restate the "invalid bands" fact set; README and CLAUDE.md phrase the usable negative range differently

The dead-band / invalid-config facts are stated in full in three places after
this diff:

- `CLAUDE.md:103-109` ("Invalid IIS-config bands" — `6`–`99` rejected, `118`–`122`
  rejected, `0`/`100` collision, upgrade-audit instruction)
- `CLAUDE.md:113` ("Breaking change vs. upstream" — `118`–`122` / `120 121 122`
  again, with its own upgrade-audit instruction)
- `README.md:7` (fork note — `6`–`99` and `118`–`122` rejected, usable range
  `0`–`5` / `100`–`117`)
- plus `CLAUDE.md:90` (intro line, "Only `0`–`5` and `100`–`117` are actually
  valid").

Two concrete drift risks already visible:

1. **CLAUDE.md:105 vs CLAUDE.md:90/README.md:7 phrasing mismatch.** Line 105
   says "The usable negative range is `0`–`5` only." Line 90 and README:7 say
   the usable set is "`0`–`5` and `100`–`117`". The `0`/`100` collision
   (line 107) means `0` is *also* reachable as a positive-range value — so
   "negative range is `0`–`5`" is loose: `0` is the boundary both ranges share.
   Minor, but it is exactly the kind of phrasing that a future edit to one line
   will desync from the other.
2. **CLAUDE.md:109 and CLAUDE.md:113 both give an "upgrade your
   applicationHost.config" instruction** for overlapping band sets (109 covers
   `6`–`99` ∪ `118`–`122`; 113 covers `118`–`122` only). A reader gets the
   118–122 migration warning twice, and a future edit to the band numbers must
   touch both.

- **File:line**: `CLAUDE.md:90`, `CLAUDE.md:103-109`, `CLAUDE.md:113`,
  `README.md:7`.
- **Fix shape**: within `CLAUDE.md`, fold the `118`–`122` upgrade instruction so
  it lives once. The "Invalid IIS-config bands" block (103-109) is the natural
  single home for *all* rejected-range facts; the "Breaking change vs. upstream"
  paragraph (113) should keep only what is genuinely upstream-relative (upstream
  README documents `120 121 122` as valid; this fork rejects them) and *point*
  to the bands block for the migration step rather than repeating it. Tighten
  line 105 to "`0`–`5` (and `0` again via the positive-range `100`)" or simply
  "`0`–`5`" consistently with line 90. README↔CLAUDE.md duplication is
  acceptable and arguably required (README is the upstream-facing doc, CLAUDE.md
  the fork-internal one — they have different audiences and the README fork-note
  is deliberately self-contained), so do **not** try to deduplicate across the
  two files; only fix the within-CLAUDE.md double-statement and the 105/90
  phrasing mismatch.

### [P1] `build-x64.ps1` repeats the `/arch:AVX2` decision in three independent expressions

The "is this an AVX2 build?" branch is computed three separate times from
`$Arch`:

- `build-x64.ps1:75` — `$archFlag = if ($Arch -eq 'avx2') { '/arch:AVX2 ' } else { '' }`
- `build-x64.ps1:130` — `$pluginArchProp = if ($Arch -eq 'avx2') { '/arch:AVX2' } else { '' }`
- `build-x64.ps1:78` / `:125` — the `($Arch.ToUpper())` interpolations in the
  `Write-Host` banners (cosmetic, fine).

Lines 75 and 130 encode the *same* policy ("avx2 ⇒ emit `/arch:AVX2`, else
emit nothing") with the only difference being a trailing space (75 has it
because it is concatenated into a flag string; 130 does not because it is a
single `/p:` value). If the arch policy ever gains a third variant or the flag
spelling changes, both sites must change in step, and the trailing-space
asymmetry is a latent copy-paste hazard. This file is fork-only
(`build-x64.ps1` does not exist upstream — `CLAUDE.md:55` lists it as a "local
addition"), so consolidation here carries **zero upstream-merge cost** — unlike
the `src/zstd.c` comment, there is no cherry-pick to protect.

- **File:line**: `build-x64.ps1:75`, `build-x64.ps1:130`.
- **Fix shape**: compute the bare flag once near the top —
  `$archFlag = if ($Arch -eq 'avx2') { '/arch:AVX2' } else { '' }` — and derive
  both consumers from it: the cflags concatenation appends a space at the use
  site (`"... $archFlag /GL ..."` already space-separated, so the trailing-space
  hack disappears), and `$pluginArchProp` becomes just `$archFlag`. This is a
  genuine simplification: one source of truth for the arch decision, no
  duplicated conditional, and it removes the trailing-space inconsistency that
  is itself a bug waiting to happen. Small and self-contained — appropriate for
  a `simplify follow-up:` commit.

## Items checked and found clean

- **Level-encoding table consistency.** `CLAUDE.md:92-99` table, `CLAUDE.md:40`
  summary, `src/zstd.c:59-66` comment and the `README.md:7` fork-note all agree
  on the 0–99 negative / 100+ positive mapping and on the `0`/`100`→level-0
  collision. The gate-1 follow-up updated them together; no stale copy.
- **chainLog/hashLog numbers.** `src/zstd.c:77` and `CLAUDE.md:111` cite
  identical figures (`L17: 23/22`, `L22: 27/25`); `CLAUDE.md:40` and the two
  memory figures (48 MiB / 0.6 GiB) match `src/zstd.c:79`. No drift.
- **`build-x64.ps1` MSVC-discovery logic.** `vswhere` is invoked three times
  (msbuild / dumpbin lines 52-55) but each finds a *different* tool — not
  repeated logic, just three distinct lookups. No consolidation warranted.
- **vcxproj `EnablePREfast` comment** (`src/zstdIIS.vcxproj:73-76`) is a single
  new comment block, not duplicated anywhere. Clean.
- **`.editorconfig` change** is a one-line value flip with no prose. Clean.
- **`src/zstd.c` indentation re-flow** (`670e77a`) is whitespace-only; it
  introduced no duplicated text.
- **Files-list bullet** (`CLAUDE.md:129`, windowLog-fix attribution move) is a
  single corrected line, not a duplicate.
