---
tests: vault_hist_cli
---

# Vault history CLI — test-spec

Agnostic cases for `vault_hist_cli`, in strict Arrange / Act / Assert form.
Terms:

- **folder** — a temporary directory the tool operates on; `.hist/` inside
  it is the mirror the library writes.
- **hist <args>** — one invocation of the tool over the folder, with the
  writer name `laptop` unless a case says otherwise and an injected clock;
  its standard output, standard error and exit status are what is asserted.
- **sha(X)** — lowercase-hex sha256 of the exact bytes of `X`.
- History files "arriving through sync" are placed under `.hist/` directly.

## The folder, and what is tracked

### the folder is located by walking up to the nearest .hist/

- **Arrange:** a folder holding `.hist/` and a subdirectory `notes/deep/`
  with no `.hist/` of its own.
- **Act:** run `hist log notes/plan.md` from `notes/deep/`; then run it from
  a directory outside any folder with a `.hist/`.
- **Assert:** the first resolves the folder to the one holding `.hist/` and
  reads `notes/plan.md` relative to it; the second treats the working
  directory itself as the folder.

### tracking honours the extension list, the built-ins and nested ignore files

- **Arrange:** a folder with `a.md`, `b.txt`, `.git/c.md`,
  `.hist-state/x.md`, `drafts/d.md`, `notes/scratch.md`, `notes/keep.md`;
  a root `.histignore` containing `drafts/` and `notes/.histignore`
  containing `scratch.md`.
- **Act:** `hist commit` with the default extension list; then again with
  `--extensions '*'`.
- **Assert:** the first records `a.md` and `notes/keep.md` only; the second
  additionally records `b.txt` — and still nothing under `.git/`,
  `.hist-state/`, `drafts/` or `notes/scratch.md`.

## commit (R19, R2')

### commit with no paths records everything that differs, with one timestamp

- **Arrange:** a folder with `a.md` and `notes/b.md`; the clock at `T`.
- **Act:** `hist commit`; then edit `a.md`, delete `notes/b.md`, advance the
  clock to `T2`, and `hist commit` again.
- **Assert:** the first writes a root snapshot for each file, both named
  with timestamp `T`; the second writes one `patch` for `a.md` and one
  `deleted` marker for `notes/b.md`, both at `T2`. Output names each path as
  recorded, and a third invocation with nothing changed reports every path
  unchanged and writes nothing.

### commit with paths records only those

- **Arrange:** a folder with `a.md` and `b.md`, both edited since their last
  version.
- **Act:** `hist commit a.md`.
- **Assert:** `a.md` gains a version; `b.md` does not. A path outside the
  folder is refused with a usage error.

### a commit after a restore diffs from the restored version

- **Arrange:** `f.md` with versions `A → B`, live `B`.
- **Act:** `hist restore f.md HEAD~1` (live becomes `A`); edit the file to
  `E`; `hist commit f.md`.
- **Assert:** the restore writes no history file; the commit writes exactly
  one `patch` with `prev: <sha(A)>` — not from the stranded leaf `B` — and
  the log with `--all` shows `B` as an archived branch.

## Addressing (R1)

### revisions resolve like git, and ambiguity is an error naming the candidates

- **Arrange:** `f.md` with versions `A → B → C`, live `C`, and a second file
  whose versions include two hashes sharing a five-character prefix.
- **Act:** `hist show f.md <sha(B)>`, `hist show f.md <first 8 of sha(B)>`,
  `hist show f.md HEAD~1`, `hist show f.md @{<date after B, before C>}`;
  then `hist show <second file> <the shared prefix>`.
- **Assert:** the first four print `B`; the fifth exits non-zero and its
  error names both candidate hashes.

## log (R2)

### the log lists the primary line newest first, marks live, and appends branches on request

- **Arrange:** `f.md` with `A → B → C` (writers `laptop`, `phone`,
  `laptop`), a fork `A → X` by a third device `tablet` arriving through
  sync, live `C`.
- **Act:** `hist log f.md`; `hist log --all f.md`; `hist log --author phone
  --all f.md`; `hist log -n 1 f.md`.
- **Assert:** the first shows three lines `C, B, A` with times and writers,
  `C` marked `live`, and no branch; the second adds a branch block headed by
  `X`'s leaf, `divergent`, writer `tablet`; the third lists only `B`; the
  fourth only `C`.

### unsaved live changes are announced, never mistaken for a version

- **Arrange:** `f.md` with `A → B`; the live file edited to `Z` and not
  committed.
- **Act:** `hist log f.md`; `hist show f.md HEAD`.
- **Assert:** the log's first line says the live file has unsaved changes
  after `B`'s hash, and lists `B, A`; `show HEAD` fails saying the same.

## show and restore (R3)

### show prints verified content and reports a broken version

- **Arrange:** `f.md` with `snapshot(A)` and a `patch(A → B)` tampered so
  the result no longer hashes to `sha(B)`; live `B`.
- **Act:** `hist show f.md HEAD~1`; `hist show f.md HEAD`.
- **Assert:** the first prints exactly `A` and exits `0`; the second prints
  nothing on standard output, reports `broken` on standard error, and exits
  non-zero.

### restore writes the addressed version over the live file and records nothing

- **Arrange:** `f.md` with `A → B`, live `B`.
- **Act:** `hist restore f.md HEAD~1`.
- **Assert:** the live file now contains `A`, no temporary file is left
  beside it, no history file was written, and the output names the version
  restored.

## diff and blame (R4, R5)

### diff renders a unified diff over verified content, across a checkpoint

- **Arrange:** `f.md` with `A → B → C` where `C` is a snapshot checkpoint
  and `patch(A → B)` is corrupted; live `C`.
- **Act:** `hist diff f.md HEAD~1 HEAD` where `HEAD~1` reconstructs from the
  checkpoint; then `hist diff f.md` (defaults).
- **Assert:** the diff is in unified form with `---`/`+++` headers naming
  the path and the two hashes and hunks marking removed and added lines; the
  default form equals `HEAD~1 HEAD`. A side that cannot be verified makes
  the whole command fail as broken rather than diffing garbage.

### blame attributes each line to the version and writer that introduced it

- **Arrange:** `f.md` recorded as `"one\ntwo\n"` by `laptop`, then
  `"one\ntwo\nthree\n"` by `phone`, then `"uno\ntwo\nthree\n"` by `laptop`;
  live the last.
- **Act:** `hist blame f.md`.
- **Assert:** three output lines: `uno` attributed to the third version and
  `laptop`, `two` to the first version and `laptop`, `three` to the second
  version and `phone` — each carrying the short hash, the writer and the
  line.

## merge (R8–R13, R15, R17)

### take the branch whole restores its leaf as the live version and settles the former line

- **Arrange:** `plan.md` forked at `A`: `A → C` (live, `laptop`) and `A → D`
  (`phone`, arrived through sync).
- **Act:** `hist merge plan.md <prefix of sha(D)> --take branch`.
- **Assert:** the live file contains `D`; exactly **one** history file was
  written — a `merged` marker naming `merged: <sha(C)>` (the line that was
  live) and `into: <sha(D)>` — because `D` is already recorded and the live
  pointer simply moves, as a restore does; `D`'s line is now the primary
  line, the former line lists as merged, and `hist status` reports no
  divergence.

### take the live side writes only a marker and changes no content

- **Arrange:** the same fork.
- **Act:** `hist merge plan.md D --take live`.
- **Assert:** exactly one file was written, a `merged` marker with
  `merged: <sha(D)>`, `into: <sha(C)>`; the live file is untouched; the
  branch lists as merged; the divergence count is zero.

### the three-way merge writes a draft with explicit conflict regions, resumable

- **Arrange:** `plan.md` with base `A = "one\ntwo\nthree\n"`, live
  `C = "one\ntwo changed here\nthree\n"` and branch
  `D = "one\ntwo changed there\nthree\nfour\n"`.
- **Act:** `hist merge plan.md D`; then `hist merge plan.md --continue`
  without touching the draft; then resolve the region in the draft and
  `hist merge plan.md --continue` again.
- **Assert:** the first prints the draft's path under `.hist-state/`, writes
  nothing to history and leaves the live file untouched; the draft contains
  `four` merged cleanly and one conflict region marking the live and branch
  versions of the second line; the second invocation refuses while a region
  remains and names it; the third writes the resolved content over the live
  file, commits it as a `patch` from `sha(C)`, records the marker naming
  `sha(D)`, and removes the draft. `hist status` lists the unfinished draft
  between the first and third steps.

### no common ancestor means side-choosing only

- **Arrange:** `f.md` with two unrelated roots: the live line rooted at `P`
  and another writer's line rooted at `Q`.
- **Act:** `hist merge f.md Q`.
- **Assert:** the command is refused, stating that the lines share no
  ancestor and naming `--take live` and `--take branch` as the ways to
  settle it; nothing is written.

### merge refuses archived branches and is a no-op on settled ones

- **Arrange:** `f.md` with an archived branch (a rollback) and a branch
  already named by a `merged` marker.
- **Act:** `hist merge f.md <archived leaf> --take branch`; `hist merge f.md
  <merged leaf> --take live`.
- **Assert:** the first is refused, saying the line is the owner's own
  discarded state with nothing to reconcile; the second reports the branch
  already settled and writes nothing.

### --abort discards the draft

- **Arrange:** a folder with a draft written by `hist merge`.
- **Act:** `hist merge plan.md --abort`; `hist status`.
- **Assert:** the draft is gone, nothing was written to history or the live
  file, and status no longer lists an unfinished merge.

## status and the folder-wide log (R6, R16)

### status counts files with a divergent line, not branches

- **Arrange:** `a.md` with two divergent branches, `b.md` with one archived
  branch, `c.md` with one merged branch, `d.md` with no branches.
- **Act:** `hist status`.
- **Assert:** it reports **one** file with a divergent line — `a.md`, listing
  both branches — and names no other file as needing attention.

### the folder-wide log merges every file's versions and says it is approximate

- **Arrange:** `a.md` and `b.md` recorded by one `hist commit` (two versions,
  one timestamp `T`, writer `laptop`), and `a.md` edited later by `phone`
  through files arriving via sync at `T2`.
- **Act:** `hist log`; `hist log --group`.
- **Assert:** the first line of both states that ordering between files is
  approximate and rests on device clocks; the entries list `a.md@T2` first,
  then the two `T` versions, each naming its path and writer; with
  `--group` the two `T` versions by `laptop` form one block and the `phone`
  version stays alone — grouping is by writer and identical time, never a
  window.

## Honesty (R14)

### the help says where the model is not git

- **Arrange:** nothing.
- **Act:** `hist --help`.
- **Assert:** the text states that the folder-wide log is approximate
  between files, that there are no named branches and no messages, that a
  reconciliation is a marker beside an ordinary version rather than a
  two-parent record, and that a date address rests on device clocks.
