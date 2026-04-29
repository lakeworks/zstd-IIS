# zstd-IIS — /simplify (quality lens) — 2026-04-29

## Summary

Post-hardening code quality is strong: comments explain WHY (especially around memory hazards and IIS ABI contracts), error handling is consistent, naming is clear. Gate 1's operational/critical fixes have landed cleanly. The findings below are minor: inconsistent indentation in source, an outdated doc claim about encoding scope, and one misleading comment placement.

## Findings

### Q-1 — Mixed tabs and spaces in src/zstd.c
**Files**: `src/zstd.c:68-69`  
**Observation**: Lines 68-69 use tab indentation (`\t`) while surrounding code (lines 51-67, 70-79) use four-space indentation. The `.editorconfig` at the root declares `indent_style = tab`, but the fork has applied space indentation throughout the file as the working convention. The two tabs stand out as inconsistent.  
**Recommendation**: Normalize lines 68-69 to four-space indentation to match the rest of the file. If a full file normalization is desired (spaces → tabs per `.editorconfig`), that's a separate mechanical pass; for now, preserve the working convention.  
**Priority**: P2

### Q-2 — CLAUDE.md claims UTF-8 encoding normalization for source, but .rc remains UTF-16LE
**Files**: `CLAUDE.md:38` ("Source encoding normalized to UTF-8"), `src/zstd.rc`  
**Observation**: The "Local fixes" section states "Source encoding normalized to UTF-8. Upstream files were UTF-16LE BOM-encoded." However, `src/zstd.rc` is still UTF-16LE BOM-encoded (verified: first two bytes are FF FE). The claim should be scoped to C source files only, or the .rc should be converted. The file currently reads as an overstatement of the scope of the normalization.  
**Recommendation**: Either (a) narrow the claim to "C source files (.c, .h) normalized to UTF-8; .rc retains UTF-16LE for RC.exe compatibility", or (b) convert zstd.rc to UTF-8 and verify RC.exe compiles it (may need `/c 65001` flag). Option (a) is lower-risk for near-term.  
**Priority**: P1

### Q-3 — CLAUDE.md "Files" section missing resource.h entry
**Files**: `CLAUDE.md:101-109` (Files section)  
**Observation**: The Files section lists `src/zstd.c`, `src/zstd.h`, `src/zstd.def`, `src/zstdIIS.vcxproj`, `zstd/`, `build-x64.ps1`, and `CLAUDE.md`. It does not mention `src/resource.h`, which is referenced in the vcxproj and compiled as part of the DLL. This is not a critical omission (resource.h is a standard Windows SDK header), but it breaks the list's completeness claim.  
**Recommendation**: Either add `src/resource.h` to the list (with a note that it is a standard Windows SDK header), or note that the list covers only locally-developed files. The current state leaves a reader wondering if resource.h is accidentally included.  
**Priority**: P2

### Q-4 — Comment placement breaks logical grouping in Compress function
**Files**: `src/zstd.c:68-69`  
**Observation**: The comment `// ZSTD_minCLevel = -131072` and its GitHub issue link appear *after* the `comp_lev` translation (line 66) and *before* the bounds check (line 70). The comment is explaining the lower bound of the bounds check, but it's separated from the check by a blank line. Readers scanning the code flow may miss the connection. The comment was likely inherited from upstream or an earlier refactor and was not relocated during gate 1's hardening.  
**Recommendation**: Move lines 68-69 immediately before line 70 (the bounds-check `if`), so the comment precedes the check it documents. This improves logical flow and makes the rationale clear at the point of enforcement.  
**Priority**: P2

### Q-5 — Misleading CLAUDE.md reference to submodule "branch = release"
**Files**: `CLAUDE.md:107` ("pinned to release branch")  
**Observation**: The Files section describes `zstd/` as "Facebook zstd library submodule (pinned to release branch)". However, commit `dcca65f` ("fix: remove `branch = release` to harden submodule pin") removed the `branch = release` line from `.gitmodules` to prevent `git submodule update --remote` from bypassing the commit pin. The doc now contradicts the actual state: the submodule is pinned to a commit, not a branch. This is confusing for someone reading the doc and then looking at `.gitmodules`.  
**Recommendation**: Update to "pinned to commit `f8745da6` (zstd 1.5.7); the `branch` directive was removed to prevent unintended fast-forwards". This aligns with the local policy's "commit-pinned" language and the change from `dcca65f`.  
**Priority**: P1

### Q-6 — S_FALSE return semantics unclear without context
**Files**: `src/zstd.c:111`  
**Observation**: The final line returns `input_buffer_size || bytes_left ? S_OK : S_FALSE`. The comment says "S_OK to continue looping, S_FALSE to stop", but the condition `input_buffer_size || bytes_left` means "more input exists OR the encoder has emitted buffered output". The semantics feel inverted from a reader's perspective: "stop when there's no more input AND no pending bytes" is correct, but the variable names don't scream "keepgoing". This is not a bug (gate 1's adversarial review confirmed it's correct), but it's a readability wart. The comment is good; the code could be clearer.  
**Recommendation**: No code change needed (it's correct). Consider: expand the comment inline to "Return S_OK if more input remains OR compressed output is pending (continue looping). Return S_FALSE when both input and pending output are empty (stop)." This makes the logic more transparent without changing behavior.  
**Priority**: P2

## Items reviewed and cleared

- **Commit messages across production-hardening branch**: Subjects are action-oriented and descriptive (e.g., "build: /t:Rebuild on plugin step", "harden: check ZSTD_CCtx_setParameter return value"), bodies explain the rationale and risk. No cherry-pick ambiguities noted.
- **Naming consistency**: `compression_level` (input), `comp_lev` (translated value), `cctx` (context) are used consistently throughout. The mapping is documented in a comment block (lines 59-66).
- **Comment quality**: WHY-comments dominate; no stale WHAT-comments. Examples: lines 17-21 explain why windowLog must be set early; lines 51-53 justify defensive guards; lines 91-95 explain state-reset semantics. All add value.
- **Error-handling consistency**: All pointer/size guards at function entry; ZSTD_isError() checks on both setParameter calls (lines 23, 79); post-error state reset on compressStream2 failure (line 96). No silent failures.
- **Structure**: CreateCompression is minimal (init cctx, set windowLog, return). Compress has logical flow: guards → level translation → validation → work → error handling → return. No deep nesting or unexpected control flow.
- **CLAUDE.md "Deployment" section**: After commit `68c2abb`, the XML example is now a fragment ("scheme-only") with an explicit warning to add inside the existing `<httpCompression>` element. This matches Brotli-IIS convention and is clear.
- **CLAUDE.md "Compression-level encoding" table**: Row structure is clear; footnote distinguishes 0/100 default behavior. Ceiling (117) is documented with the multi-GB warning (lines 87). No misleading guidance.

## Summary

No critical quality gaps remain. Q-2 and Q-5 are doc inconsistencies that should be fixed before the fork is published (they'll confuse future readers). Q-1 and Q-4 are cosmetic but worth addressing in a tidying pass. Q-3 and Q-6 are minor clarity improvements. The code itself is well-structured, hardened, and readable.
