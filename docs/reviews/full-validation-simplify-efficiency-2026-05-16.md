---
status: clean
arc: full-validation
gate: 2-simplify
lens: efficiency
repo: zstd-IIS
critical: 0
operational: 0
polish: 0
---

# zstd-IIS full-validation — gate-2 /simplify, efficiency lens

Scope: gate-1 follow-up commits `ad2c83f..HEAD` on `production-hardening`.
Touched files: `src/zstd.c`, `CLAUDE.md`, `README.md`, `build-x64.ps1`,
`src/zstdIIS.vcxproj`, `.editorconfig`.

## Result: clean — no efficiency findings

The diff is entirely polish: documentation rewrites (CLAUDE.md / README.md
level-band corrections), a factual rewrite of the level-17-ceiling C comment,
a whitespace tab→4-space reindent of `CreateCompression`, two vcxproj flag
edits (`EnablePREfast=false`, link path), one build-script path change, and an
`.editorconfig` `indent_style` flip. None of this is runtime code on a hot
path, so genuine runtime-efficiency findings were not expected.

The one place an efficiency regression could plausibly hide — the out-of-tree
build change in `build-x64.ps1` — was examined directly:

- **`$libBuildDir` path change** (`build-x64.ps1:35`, `zstd/build/cmake/x64`
  → `out/zstd-build/x64`) is a clean substitution. No extra work added: the
  `Remove-Item -Recurse -Force` + `New-Item` of `$libBuildDir` at lines 85-86
  is unchanged behaviour, just rebased onto the new path. Its stale-cache
  rationale (lines 79-84) still applies — CMake refuses to overwrite a cache
  from a different generator/flag set, so the wipe is load-bearing, not a
  redundant directory recreate.
- **No redundant path computation introduced.** `$zstdLib` is still used for
  the submodule presence check (`build-x64.ps1:39`) and the cmake `-S` source
  dir (line 107); it was not orphaned by the change. `$libBuildDir` and
  `$outDir` are created once each (lines 86 and 145) at distinct points — no
  double-create. `out/zstd-build` nesting under `$outDir` does not require a
  separate parent-dir create because `New-Item -Force` creates intermediate
  directories.
- **`out/` is gitignored** (`.gitignore:2`), so the build-script comment's
  claim that the new path lives "under the gitignored out/" is accurate — the
  change does what it says with no wasted I/O outside that tree.

The `EnablePREfast=false` vcxproj edit (`src/zstdIIS.vcxproj:76`) is, if
anything, a build-time *improvement* (drops an ineffective `/analyze` pass) —
that was a gate-1 codex finding, already addressed in commit `607f3fc`, and is
out of scope to re-litigate. Noted only to confirm it introduces no waste.

Nothing in the changed build flow became wasteful. Status: clean.
