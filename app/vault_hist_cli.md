---
name: vault_hist_cli
description: The standalone history command line — a local git-lite for notes over a bare folder, with no daemon, server, credentials or registration — that records a folder's history on command and reads it back (commit, log, show, restore, diff, blame, status), and settles a divergent line deliberately (merge — take a side, or a diff3 draft kept in .hist-state/ and resumed), through the vault_hist library alone.
status: draft
---

# Vault history CLI

## Purpose

`vault_hist` records a great deal and, until now, showed almost none of it.
This module is the **command line over the history library alone**: it
operates on a *folder*, needs no daemon, no server, no credentials, no
passphrase and no registration, and gives a person everything they can learn
about a folder's history and everything they can do about a divergence —
"what changed", "who wrote this", "what did this look like then", and "the
other laptop was offline for a month" (history-surface G1–G5).

It is deliberately **shaped like git**, because the model already is: nodes
are content-addressed states, edges are forward diffs, records are immutable,
and a lineage is a leaf hash. An owner who knows `git log` and `git show`
should not have to learn a private vocabulary. And it says plainly, in its own
output and help, where the model is **not** git (R14) — so a git-shaped
surface never implies git-shaped guarantees it cannot make.

**Two entry points, one library.** This standalone tool (`hist`) and the
daemon's `hist` verbs over the vaults it serves (`vault_daemon`) are the
same code over the same library; the daemon's is a superset only in what it
can reach (its vault registry, its settings), never a second implementation.

## Inputs

- **A folder.** Given explicitly, or located by walking up from the working
  directory to the nearest directory holding a `.hist/` mirror — the same
  way git finds a repository — and the working directory itself when none
  does.
- **A writer name**, stable and unique per device (C5): given explicitly, or
  from the environment, or the machine's hostname. It stamps every version
  this tool records.
- **The tracked extension list** (`vault_hist`; default `.md`, `*` for any
  text file) and the folder's **ignore files** — `.syncignore` and
  `.histignore`, at any depth, through the shared exclusion engine
  (`vault_folder`), plus the built-in exclusions `.hist/`, `.hist-state/`,
  `.git/`, `.trash/` and `.DS_Store`.
- **A working-state directory** for this machine and this folder —
  `.hist-state/` beside `.hist/` by default, movable with `--state-dir` for
  a folder that sits inside somebody else's sync (Dropbox, iCloud) where our
  built-in exclusion cannot apply.
- **Verbs and their arguments**, described below; a revision wherever one
  is expected is a git-style address (`vault_hist` R1).

## Outputs

- **History files** under `.hist/`, through the library's ordinary
  `commit` and `merge` — the only writes into the mirror, and the same
  stateless calls the daemon makes, so the two cannot disagree (R19).
- **Text on standard output**: logs, reconstructed content, diffs, blame,
  status. Content is emitted byte-for-byte; everything else is for a person.
- **The live file**, when `restore` or a finished `merge` brings a version
  back into the one live reality.
- **This machine's working state** under `.hist-state/`: an unfinished
  merge draft (R15), and a per-path note of the last version this machine
  recorded or restored — the tool's equivalent of the daemon's checkpoint,
  consulted only when several lines are open and the graph alone cannot name
  the base. It is a cache, never a source of truth: losing it costs nothing.
- **Exit status**: `0` on success; `1` when something was wrong with the
  history or the request (a broken version, an ambiguous or unknown
  revision, no history, an unresolved merge); `64` for a usage error.

## Behavior

### The folder, and what is tracked

- Every verb resolves the folder first. Paths are given relative to it
  (`notes/plan.md`) and printed the same way. A path outside the folder is
  refused.
- A path is **tracked** when the library would version it — its extension is
  in the list, or the list is `*` — and no built-in exclusion, `.syncignore`
  or `.histignore` at any applicable depth excludes it. Content decides in
  the end: a file that is not valid UTF-8 is never versioned, whatever it is
  called.

### `commit [<path>…]` — recording is explicit, and it is one verb (R19)

- Records the current state of the named paths, or — with none named — of
  **everything that differs from the graph**: every tracked file on disk
  whose content is not its recorded live version, and every path that has
  history but no file on disk (a deletion). A path whose live content is
  already recorded prints as unchanged and writes nothing.
- **One invocation, one timestamp.** Every version written by one `commit`
  carries the same time, so "same writer, same time" identifies exactly one
  invocation — the grouping the folder-wide log offers (R2') is a fact, not
  a heuristic.
- There is **no staging and no message** (history-surface non-goals): the
  daemon writes most of a vault's history automatically and can invent no
  message, and a version is always a whole file, so nothing could be
  partially staged.
- The base of each version is the library's to recover; the tool offers what
  it knows — the version it last recorded or restored for the path, from
  `.hist-state/` — so a commit after a `restore` diffs from the restored
  version rather than from a stranded leaf, and a divergent line does not
  leave the next commit without a base. When several lines are open and the
  tool knows nothing, the library records a root snapshot and the tool says
  so, naming `merge` as the way to settle the lines first.

### Addressing (R1)

A revision is a full hash, an unambiguous short prefix (an ambiguous one is
an error naming the candidates; fewer than four characters is refused),
`HEAD` (the live content's version), `HEAD~n`, or `@{<date-or-instant>}`
(the primary-line version live then — a date alone is the start of that day,
local time). Where a verb takes a revision and none is given, it is `HEAD`.

### `log [<path>…] [--all] [--since <date>] [--author <writer>] [-n <count>] [--group]`

- **One path:** the primary line, newest first, one line per version — a
  short hash, the time, the writer(s), and `live` on the live entry. Along
  the line the order is the graph's and is exact. `--all` appends every
  branch, headed by its leaf, its kind (`divergent` / `merged` /
  `archived`), its writers and — where the graph supplies it — the version
  it forked from.
- **A live file whose content is unrecorded** is announced first — "unsaved
  changes after `<hash>`" — so nothing in the surface leaves the owner
  unsure whether what they read is the live content.
- **Several paths:** each file's log in turn.
- **No path — the folder-wide log (R6):** one timeline merging every
  tracked file's primary-line versions (every branch too with `--all`),
  newest first, every entry naming its path and writer. It is **explicitly
  approximate and says so** in its first line:
  within one file the order is exact, but ordering *between* files rests on
  the recording devices' clocks, which are not authoritative; it is never
  presented as atomic commits, because there are none. `--group` folds
  versions with the same writer and the same time into one block — exactly
  the versions one `commit` invocation wrote (R2'), never a window. Grouping
  is off by default and never merges what was not written together; the
  daemon's versions, each stamped when its edit was offered, stay separate.
- `--since`, `--author` and `-n` filter every form.

### `show <path> [<rev>]` (R3)

Prints the addressed version's content byte-for-byte, reconstructed with the
library's per-step verification. A version that fails verification is
reported **broken** on standard error with a non-zero status, and nothing of
it is printed — never silently wrong (C4).

### `restore <path> <rev>`

Writes the addressed version over the live file, atomically, and notes it as
the path's last known version. It records nothing in history — a restore to
a known version is a pointer move, not an edge (`vault_hist`); the next
`commit` after an edit diffs from the restored version. On a synced vault the
daemon sees the write as an ordinary local edit and carries it along.

### `diff <path> [<rev>] [<rev>]` (R4)

A unified diff between two addressed versions — the first against `HEAD`
when one is given, `HEAD~1` against `HEAD` when none is. Both sides are
reconstructed and verified first; the diff is a rendering over verified
content, never a replay of stored patches, and is therefore correct across a
snapshot checkpoint.

### `blame <path> [<rev>]` (R5)

Each line of the addressed version attributed to the version that
introduced it and that version's writer, by replaying the chain from the
root to the version and carrying attribution forward through every step.

### `merge` — reconciling a divergent line (R8–R13)

Only **divergent** branches are offered (R8): `log --all` and `status` list
archived and merged ones, but `merge` refuses them, saying why. By the time
a divergence is visible sync has already converged (R9'): the surface is not
settling two live files, it is bringing content out of history back into the
one live reality. Three ways, all per file (R13):

- `merge <path> <branch> --take branch` — the branch's leaf becomes the
  live version: written over the live file as a restore (it is already
  recorded, so the pointer moves and no edge is written), and a `merged`
  marker names the line that *was* live and the leaf now live (R11). The
  roles swap: the branch's line is now the primary line and the former one
  is settled.
- `merge <path> <branch> --take live` — leave mine as it is (R17): only the
  marker is written, naming the branch and the current live version. The
  branch is settled without a byte changing; because the marker is a
  recorded file it propagates, so every device stops counting it.
- `merge <path> <branch>` — the three-way merge (R9''). The graph supplies
  the fork point, so the inputs are exact: the common ancestor, the live
  content and the branch leaf. The result is a `diff3` composition with
  **explicit conflict regions** where both sides touched the same lines — it
  never guesses, which is the whole reason it is `diff3` rather than an
  application of stored patches. The composition is written as a **draft**
  into `.hist-state/`, its path is printed, and the tool stops: the owner
  edits the draft in any editor, then `merge <path> --continue` reads it
  back, refuses it while any conflict region remains, writes it over the
  live file, commits it from the live version, and records the marker;
  `merge <path> --abort` discards the draft. An unfinished draft is listed
  by `status`, so it cannot be silently forgotten (R15).
- **No common ancestor means side-choosing only** (R10): separate lives, or
  a line anchored before another's history arrived, have no fork point, so
  the three-way form is refused with the two `--take` forms named.
- A branch some marker already names is settled (R12): `merge` reports it
  as such and writes nothing — a surface can never loop on it.

### `status`

For the folder: how many **files** have a divergent line (R13, R16) and
which, each with its branches; unfinished merge drafts; and files whose live
content is unrecorded. It is the CLI's own reading of the divergence count
the daemon carries in its status (R16), derived from the graphs, nothing
stored.

### Where it is not git, it says so (R14)

The help text and the surfaces concerned state, in plain words: that the
folder-wide log is approximate between files; that there are no named
branches and no messages, and why; that a reconciliation is a marker beside
an ordinary version, not a two-parent record; and that a date address rests
on device clocks. Silence here is what would make a git-shaped surface
mislead.

## Non-goals

- **No index, no staging, no message, no cross-file commit object, no named
  branches, no tags, no `rebase`, `amend`, `gc` or `prune`** — every one
  follows from a storage invariant (history-surface non-goals): the folder
  is append-only and conflict-free by construction, and a mutable pointer or
  a rewrite would reintroduce exactly what the design removed.
- **Not a daemon, not sync, not crypto.** It never watches, never uploads,
  never decrypts. On a synced vault it writes ordinary files and the daemon
  carries them.
- **Not rendering.** Plain text only; a history view in the app, a viewer in
  Obsidian, a side-by-side merge are a later, separate effort.
- **Not the merge algorithm's home.** `diff3`, the fork point, addressing
  and the log entries live in `vault_hist`; this module renders them.

## Examples

### Recording and reading a bare folder

In a folder with no daemon anywhere: `hist commit` records every tracked
file as a root snapshot with one timestamp. After editing `notes/plan.md`,
`hist commit notes/plan.md` writes one patch; `hist log notes/plan.md` lists
two entries, the newer marked `live`; `hist show notes/plan.md HEAD~1` prints
the first content; `hist diff notes/plan.md` shows the edit as a unified
diff.

### A divergence, settled

`notes/plan.md` forks at `A`: the live line is `A → C`, and the other
laptop's `A → D` arrived through sync. `hist status` reports one file with a
divergent line; `hist log --all notes/plan.md` shows the branch with its
writer and the fork point `A`. `hist merge notes/plan.md D` writes a draft
combining both edits, with a conflict region where they overlapped, and
prints its path under `.hist-state/`. The owner resolves the region and runs
`hist merge notes/plan.md --continue`: the result is written over the live
file, committed as `C → E`, and a `merged` marker names `D` and `E`. On every
device the branch now lists as merged, and the count drops to zero.

### Leaving mine as it is

The same fork, but the owner wants none of `D`. `hist merge notes/plan.md D
--take live` writes only the marker; the live file is untouched and the
branch stops asking on every device.
