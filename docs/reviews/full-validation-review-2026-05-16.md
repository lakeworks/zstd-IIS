---
status: findings
arc: full-validation
gate: 4-review
repo: zstd-IIS
critical: 0
operational: 1
polish: 2
---

# zstd-IIS — full-validation gate-4 /review (final coherence)

**Pass type.** Gate 4/4 — final coherence review, NOT a fresh adversarial or
simplify pass. Scope: follow-up commits `ad2c83f..HEAD` (13 commits) on
`production-hardening`, plus the arc's review docs
(`docs/reviews/full-validation-{adversarial,codex,simplify-*,followups}`).
Looking for doc-vs-code drift, finding-close mismatches, tracker-vs-commit gaps,
internal contradictions, build-script path integrity. Code was not built.

**Verdict.** The arc is substantively coherent. Numbers are correct and
cross-consistent, the build-script path change resolves correctly, gate-1/2
findings are mostly closed by the commits that claim them. One real
finding-close gap: a gate-1 codex finding (`Preserve legacy positive level
values`) is neither addressed by a commit nor recorded in the deferred-items
doc — the followups doc's blanket claim that all codex C/O findings were
"addressed this session" is inaccurate for that finding. Two Polish items on
residual doc-vs-code wording.

---

## Critical

None.

## Operational

### [O1] Gate-1 codex finding "Preserve legacy positive level values" is unaddressed and unrecorded — followups doc overstates closure

`docs/reviews/full-validation-followups-2026-05-16.md:10-13` states: *"Gate-1
(adversarial + codex) Critical/Operational findings were all addressed in
`adversarial follow-up:` / `codex follow-up:` commits this session."* The
gate-1 docs commit `237a246` describes codex as `0C/2O/1P`.

The codex review (`docs/reviews/full-validation-codex-2026-05-16:8-9`) carries
the finding **"Preserve legacy positive level values"** — `src/zstd.c:66`. Its
claim: upstream's README documented positive levels via config values like
`30`/`35` (e.g. the upstream table's `120 121 122` plus other positive entries),
and the `>99 ? -100 : -level` remap turns a legacy config value such as `30` /
`35` into zstd `-30` / `-35`, which the `comp_lev < -5` guard rejects — a silent
hard-fail on upgrade. Codex asked to either alias the old range or document the
full breaking-migration range.

Cross-checking the commit set and the deferred-items doc:

- **No commit addresses it.** `git log ad2c83f..HEAD` has one `codex follow-up:`
  commit (`607f3fc`, EnablePREfast) — that closes the third codex item only.
  The other codex O-class item (`Avoid forcing 8 MiB windows`) is correctly
  deferred as the `windowLog cap-not-override` entry in the followups doc.
- **The deferred-items doc does not mention it.** The three `[-]` entries are
  windowLog-cap, ResetCompression no-op, zstd.rc fork-stamp. The legacy-positive
  finding appears nowhere.

So the finding is in a closure limbo: not fixed, not deferred-with-trigger, and
the followups doc affirmatively claims it *was* addressed. This is exactly the
finding-close mismatch gate-4 exists to catch.

Note on severity: codex's inline tag is `[P2]` (codex's own 4-level scale) while
its YAML footer reports `O=2`. The arc treated the *footer* count as canonical
(`237a246`: "0C/2O/1P"). Under that mapping the finding is Operational and MUST
be addressed or deferred-with-trigger in-session per the cadence §"Review
findings discipline" — it cannot simply be silently dropped. Under the inline
`[P2]` reading it is Polish and may defer to a tracker entry. **Either reading
requires an artefact the arc does not have.** The merits also favour at least
documenting it: the existing "Invalid IIS-config bands" note in `CLAUDE.md`
already calls out the `6`–`99` dead band but says nothing about the `118`+
positive-range config values an upstream user may already have set for genuine
*positive* levels — and the README's own "Setup" table still lists
`120 121 122`, so an upstream user mapping "I want a slow level" to `120` is the
precise scenario codex flagged.

**Fix shape.** Lowest-cost correct close: add the legacy-positive case to the
deferred-items doc as a fourth `[-]` entry with a trigger-to-build (it overlaps
the `windowLog-cap` arc's "decide negative-range clamp-vs-reject semantics"
question — natural to fold there), OR — since the docs already enumerate the
`118`–`122` rejection — add one sentence to the followups doc's "items checked
and cleared" section explaining the finding is *substantively already covered*
by the `118`–`122` band documentation (config `120/121/122` for "slow positive
levels" falls in the documented hard-fail band, so a careful upgrader is already
warned). The blanket "all addressed" sentence at line 10-13 must be corrected
either way: replace with the accurate split (addressed / deferred-with-trigger /
covered-by-bands-doc).

## Polish

### [P1] `CLAUDE.md:90` and `:103` desync the usable negative range vs the `6`–`99` band wording

`CLAUDE.md:90` (intro line): *"Only `0`–`5` and `100`–`117` are actually
valid."* `CLAUDE.md:104` (bands block): *"The usable negative range is `0`–`5`
only."* These agree on the negative-range endpoint. But the gate-2 reuse lens
([P1] in `full-validation-simplify-reuse-2026-05-16.md:103-109`) flagged the
`0`/`100` overlap as a phrasing trap and recommended tightening line 104. The
followups doc (`:97-105`) records a *different* gate-2 reuse item
(ceiling-number duplication) as "no action by design" but does **not** record
whether the reuse lens's negative-range phrasing sub-point was actioned. The
commit `28edf09` folded the duplicated *118-122 upgrade instruction* (the other
half of that same reuse [P1]) but left the `0`/`100` phrasing untouched.

This is not a contradiction — both lines say `0`–`5` — and it is genuinely
Polish. But it is a gate-2 finding sub-point that neither landed nor got a
recorded skip reason. Either tighten line 104 to match the reuse-lens
suggestion ("`0`–`5`, with `0` also reachable via the positive-range `100`") or
note in the followups doc that the `0`/`100`-phrasing sub-point is
no-action-by-design alongside the ceiling-number entry. Trivially-fixable;
single-line.

### [P2] README "Setup" table still lists `120 121 122` with no inline correction

`README.md:35` — the upstream "Setup" level table row reads
`| 5 4 3 2 | 1 0 101 | 120 121 122 |`. The lakeworks fork note at the top of the
README (`README.md:7`) correctly states `120 121 122` are rejected and the table
"overstates what works here." So the README is *internally consistent* (the
fork note explicitly corrects the table) and this is deliberately the
upstream-parity reference block — the gate-2 quality lens already cleared the
analogous "Build" block as by-design (`full-validation-simplify-quality-...:Notes`).

Flagged only because a reader skipping the fork note and going straight to the
table gets the wrong values. The fork note already does the work; an inline
table annotation (e.g. a `†` footnote on `120 121 122` → "rejected on the
lakeworks fork — see note above") would make the table self-correcting without
disturbing upstream parity. No-action is also defensible here — recording it as
"checked, by-design" in a tracker is sufficient. Lowest-priority item in this
pass.

---

## Items checked and found coherent

- **Level-17 ceiling numbers — `src/zstd.c` ↔ `CLAUDE.md` ↔ pinned
  `clevels.h`.** `zstd/lib/compress/clevels.h` `ZSTD_defaultCParameters`
  "default" table (`srcSize > 256 KB` row — the row a streaming response with no
  pledged size selects): level 17 = `{ 23, 23, 22, ... }` (windowLog=23,
  chainLog=23, hashLog=22); level 22 = `{ 27, 27, 25, ... }` (chainLog=27,
  hashLog=25). `src/zstd.c:76-77` states "level 17 is chainLog=23, hashLog=22;
  level 22 (max) is chainLog=27, hashLog=25" — exact match. `CLAUDE.md:115`
  states the identical figures. Match-state arithmetic verified:
  `(1<<23)*4 + (1<<22)*4` = 50,331,648 B = exactly 48.0 MiB;
  `(1<<27)*4 + (1<<25)*4` = 671,088,640 B = 0.625 GiB ≈ "~0.6 GiB". Both
  documents' "~48 MiB" / "~0.6 GiB" figures are accurate and mutually
  consistent. The fabricated gate-1 numbers (`chainLog≥28`/`hashLog≥27`/
  "~2.5 GB") are fully gone from both files (commits `802e931`, `4aefab7`).
  Submodule pinned to `f8745da6` = zstd v1.5.7 — the version the docs cite.

- **Invalid-bands documentation traces to code.** `CLAUDE.md:103-111` "Invalid
  IIS-config bands" — `6`–`99` dead band, `118`–`122` over-ceiling band,
  `0`/`100`→level-0 overlap — all trace correctly to `src/zstd.c:65-66` (the
  `>99 ? -100 : -level` remap) and `:91` (`comp_lev < -5 || comp_lev > 17`).
  README fork note (`README.md:7`) agrees with the CLAUDE.md prose and defers to
  it for rationale — no contradiction.

- **Build-script out-of-tree path ↔ vcxproj link path agreement.**
  `build-x64.ps1:35` sets `$libBuildDir = <repoRoot>/out/zstd-build/x64`; the
  cmake `-B $libBuildDir` (`:109`) plus the VS-2022 generator place
  `libzstd_static.lib` at `lib/Release` under it →
  `./zstd-IIS/out/zstd-build/x64/lib/Release`. The vcxproj Release `<Link>`
  `AdditionalLibraryDirectories` is `..\out\zstd-build\$(Platform)\lib\Release`
  (`src/zstdIIS.vcxproj:110`); resolved relative to `src/` with `$(Platform)`=x64
  → `./zstd-IIS/out/zstd-build/x64/lib/Release` — **identical location**
  (verified by path resolution). The Debug `<Link>` block was repointed in
  lockstep to `..\out\zstd-build\$(Platform)\lib\Debug` (commit `4efcb2b`) — no
  half-applied state. `build-x64.ps1` parses clean
  (`[Parser]::ParseFile`, 0 errors). Build NOT run, per scope.

- **`resource.h` removal is complete.** `<ClInclude Include="resource.h" />`
  dropped from `src/zstdIIS.vcxproj` (commit `57da2f3`); the
  `src/resource.h` bullet dropped from `CLAUDE.md` "Files" list; no `resource.h`
  reference remains anywhere under `src/` (`zstd.rc` includes `winres.h`, an SDK
  header, and defines no custom IDs). vcxproj manifest and CLAUDE.md now agree —
  closes gate-1 [O1].

- **windowLog-fix attribution.** `CLAUDE.md` "Files" list now reads
  `Compress, CreateCompression (with windowLog fix), DestroyCompression` — the
  parenthetical sits beside `CreateCompression`, matching `src/zstd.c:22` where
  the cap is set. Closes gate-1 [P1] (commit `7d09ff3`). The numbered "Local
  fixes" item #1 also correctly attributes the cap to `CreateCompression`.

- **`EnablePREfast` ↔ `RunCodeAnalysis` consistency.**
  `src/zstdIIS.vcxproj:49` `RunCodeAnalysis=false`; `:76` `EnablePREfast=false`
  with an explanatory comment. The two analysis settings now agree — closes the
  gate-1 codex finding (commit `607f3fc`).

- **`.editorconfig` ↔ source indentation.** `.editorconfig` now declares
  `indent_style = space`; `src/zstd.c` `CreateCompression` was reindented to
  4-space (commit `670e77a`) so the whole file is space-indented. Editor and
  source agree — closes gate-1 [P1].

- **CLAUDE.md "Local fixes" item #2 wording.** `CLAUDE.md:40` now reads "zstd
  levels 18+ scale chainLog/hashLog up steeply; by level 22 (max) the match-state
  working set reaches ~0.6 GiB" — the gate-2 quality-lens [P1] (misreadable as
  level-18 already at 0.6 GiB) is fixed (commit `efec78d`). Distinct from the
  detailed block at `CLAUDE.md:115`; both now consistent.

- **Deferred-items doc — the three recorded `[-]` items.** windowLog
  cap-not-override, ResetCompression no-op, zstd.rc fork-stamp — each has a
  stated concrete cost and a trigger-to-build (windowLog-cap arc on bench
  build-matrix data / co-tenant memory pressure; ResetCompression folds into
  that arc; zstd.rc fork-stamp on the GitHub-push step). Deferral rationale is
  sound (each is genuinely a separate-arc change). Gate-2 ceiling-number
  duplication recorded no-action-by-design with a defensible rationale
  (operator-facing doc must carry the numbers inline). The gap is the *fourth*
  codex finding — see [O1].

- **Commit-message claims vs code.** Each `adversarial follow-up:` /
  `codex follow-up:` / `simplify follow-up:` commit cites a specific gate-1/2
  finding; spot-checked `4aefab7`, `5dcafa4`, `57da2f3`, `607f3fc`, `670e77a`,
  `7d09ff3`, `4efcb2b`, `59b639f`, `28edf09`, `efec78d` — each commit's diff
  matches its subject and the cited finding. One-issue-per-commit discipline
  holds. No commit message makes a claim the code/docs contradict.

- **Working-tree state.** `git status` reports `?? zstd` (submodule dirty).
  This is *pre-existing build scratch* from a build run under the OLD in-tree
  `$libBuildDir` path — the out-of-tree fix (`5dcafa4`) is committed, so a fresh
  build would no longer dirty the submodule. Not a finding against this arc;
  noted so a later reviewer does not mistake it for unfinished work. A one-time
  `git -C zstd clean -fdx` clears the legacy scratch.

## Recommendation

Close [O1] before declaring chain-green: it is a one-paragraph edit to
`full-validation-followups-2026-05-16.md` (correct the "all addressed" sentence
+ add the legacy-positive finding as either a deferred `[-]` entry with trigger
or a "checked/covered-by-bands-doc" cleared item). [P1] and [P2] are
trivially-fixable Polish — fold the [P1] one-line CLAUDE.md tightening in with
the [O1] doc edit if convenient; [P2] may defer to a tracker note. No code
change required by this gate — all findings are doc/record coherence.
