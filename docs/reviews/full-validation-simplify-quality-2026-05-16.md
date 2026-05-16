---
status: findings
arc: full-validation
gate: 2-simplify
lens: quality
repo: zstd-IIS
critical: 0
operational: 0
polish: 2
---

# zstd-IIS — gate-2 /simplify, quality lens

Scope: gate-1 follow-up commits `ad2c83f..HEAD` on `production-hardening`.
Touched files: `src/zstd.c`, `CLAUDE.md`, `README.md`, `build-x64.ps1`,
`src/zstdIIS.vcxproj`, `.editorconfig`. Polish-only pass on a base whose
Critical/Operational findings were already closed at gate 1.

## Verified clean

The substance of the follow-up commits checks out:

- **Level-17 ceiling comment numbers** (`src/zstd.c:74-90`, `CLAUDE.md:111`).
  Cross-checked against the pinned `zstd/lib/compress/clevels.h`
  `ZSTD_defaultCParameters` "default" table (the `srcSize > 256 KB` row, the
  one a streaming response with no pledged size selects): level 17 is
  `W=23, C=23, H=22`; level 22 is `W=27, C=27, H=25`. Both the code comment
  and the CLAUDE.md prose now state `chainLog=23/hashLog=22` for L17 and
  `chainLog=27/hashLog=25` for L22 — matches the table exactly. The
  match-state arithmetic also checks out: `(1<<23)*4 + (1<<22)*4` = 50,331,648
  B ≈ 48 MiB (L17), `(1<<27)*4 + (1<<25)*4` = 671,088,640 B ≈ 0.64 GiB (L22).
  The "~48 MiB" / "~0.6 GiB" figures are accurate. The fabricated
  `chainLog≥28 / hashLog≥27 / ~2.5 GB` numbers the gate-1 adversarial flagged
  are fully gone from both files. Code comment and doc are internally
  consistent with each other.

- **`CreateCompression` reindent** (`src/zstd.c:7-31`). Diff confirms the
  change is whitespace-only: every line in the block changed only its leading
  tab→4-space indentation; no token, identifier, literal, or comment text
  differs. `.editorconfig` flipped `indent_style = tab` → `space` to match —
  the editorconfig and the source now agree, and the gate-1 adversarial [P1]
  on that mismatch is closed.

- **`build-x64.ps1` out-of-tree-build comments** (`build-x64.ps1:32-35`,
  `82-84`). `$libBuildDir` is now `out/zstd-build/x64` (under the gitignored
  `out/`). The vcxproj Release link path (`src/zstdIIS.vcxproj:110`) is
  `..\out\zstd-build\$(Platform)\lib\Release`; `$(Platform)` resolves to `x64`
  for the only buildable configuration, so the script comment's literal
  `..\out\zstd-build\x64\lib\Release` describes the resolved path correctly.
  The rationale ("a dirty submodule masks a genuinely drifted gitlink SHA at
  review") is accurate.

- **CLAUDE.md invalid-band guidance** (`CLAUDE.md:103-109`) and the README
  fork note (`README.md:7`). The `6`–`99` dead band, the `118`–`122`
  over-ceiling band, and the `0`/`100`→level-0 overlap all trace correctly to
  `src/zstd.c:65-66,91`. The README note and CLAUDE.md prose agree with each
  other (README defers to CLAUDE.md for the rationale; no contradiction).

## Polish

### [P1] Debug-config link path in vcxproj still points inside the submodule

`src/zstdIIS.vcxproj:95` — the `Condition="'$(Configuration)'=='Debug'"`
`ItemDefinitionGroup` still has
`<AdditionalLibraryDirectories>..\zstd\build\cmake\$(Platform)\lib\Debug;...`.
The follow-up commit `5dcafa4` updated only the Release block (line 110) to
the new `..\out\zstd-build\...` location. The Debug path is dead — the
project's `EnsureRelease64` `<Target>` fails any build that is not
`Release|x64` — so this is not a build defect. But it leaves the vcxproj
self-inconsistent: a reader comparing the two `<Link>` blocks sees the
in-tree `zstd\build\cmake` path the rest of this commit set deliberately
retired, and the gate-1 [O1] rationale ("never leave scratch inside the
submodule") reads as only half-applied. Fix shape: either update line 95 to
`..\out\zstd-build\$(Platform)\lib\Debug` for parity, or drop the entire
Debug `ItemDefinitionGroup` since the build target makes Debug unreachable
anyway (the cleaner option — removes a stanza that can only mislead).

### [P1] CLAUDE.md "Local fixes" item 2 still phrases the ceiling rationale loosely

`CLAUDE.md:40` (the numbered "Local fixes" list) describes fix #2 as
"zstd levels 18+ scale `chainLog` / `hashLog` up to a ~0.6 GiB match-state
working set per CCtx at level 22". The "0.6 GiB" figure is correct, but the
phrasing "levels 18+ scale ... up to ... at level 22" is slightly muddled —
it reads as if level 18 already carries the 0.6 GiB cost, when 0.6 GiB is the
level-22 figure and level 18 is still `C=23, H=22` (the same ~48 MiB as the
level-17 ceiling). The detailed block at `CLAUDE.md:111` gets this right
(distinguishes L17 ~48 MiB from L22 ~0.6 GiB); the one-line summary at line 40
loses that distinction. Fix shape: tighten to e.g. "zstd levels 18+ raise
`chainLog` / `hashLog`, reaching a ~0.6 GiB match-state working set per CCtx
at level 22" — drops the false implication that 18 is already at 0.6 GiB.
No behaviour or correctness impact; the ceiling at 17 is unaffected.

## Notes (no action)

- The README "Build" block (`README.md:11-29`) still contains the upstream
  manual `cmake ... -B zstd\build\cmake\x64` instructions, which now diverge
  from the out-of-tree `build-x64.ps1` path. This is *by design* — the
  lakeworks fork note at the top of the README (`README.md:6`) explicitly
  redirects fork users to `./build-x64.ps1` and away from the manual chain,
  and the manual block is retained as the upstream-parity reference. Not a
  contradiction to fix; flagged only so a later reviewer does not re-raise it.
