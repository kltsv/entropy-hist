---
name: vault_hist
description: Per-file edit history as ordinary files in a mirrored .hist/ folder — forward diff-match-patch patches from full snapshots, versions named and linked by content sha256 into a graph, five immutable file types (snapshot, patch, deleted, conflict, merged), recorded through one explicit stateless commit verb (timing belongs to the caller), a primary line defined by the live content rather than by clocks, branches identified by leaf hash and settled by merge markers rather than by multi-parent records, and a reader that reconstructs any version with per-step hash verification.
status: draft
---

# Vault history

## Purpose

The owner wants to view and restore past versions of a note and recover
deleted files, capturing **every** edit no matter which client made it (R12,
G6). This module is that history: how versions are recorded, how they are
stored, how any past version is reconstructed, and how history behaves across
deletion, recreation, rename, and conflict.

History is **ordinary files** in a mirrored `.hist/` folder inside the
vault. Those files ride the *same* sync and the *same* encryption as
everything else, so history is synchronized end-to-end and the server never
sees it in plaintext (R13, RV8). It is deliberately not git (N4, C5).

Two properties carry the whole design (RV5, RV6):

1. **Every writer records only its own local edits.** The daemon records
   everything edited on its machine by any tool; the Flutter app records its
   own saves. Changes that *arrive through sync* are never recorded by the
   receiver — the source already recorded them. There is no single writer and
   no coordination (RV6).
2. **History files are append-only and immutable, linked by content hashes,
   not time.** Each version file names the states it connects by sha256 of
   content. A reader on any device rebuilds the same graph from whatever
   files have arrived, in any order, under any clock skew — pieces from
   different devices slot together by construction, and history files can
   never conflict in sync (RV5).

This module is the algorithm and layout — pure, framework-agnostic. Shells
feed it path-state changes and give it storage; the desktop daemon and the
Flutter app both embed it (RV6).

## Inputs

- **An explicit commit**, the module's only write verb:
  - `commit(path, content | absent, writer, previous?, previousHash?)` —
    record this state as the next version of `path`. **When** to call it is
    the caller's decision, never this module's: the daemon coalesces raw
    filesystem events and calls once per settled edit (`vault_daemon`).
    `previous` is the prior content when the caller can produce it;
    `previousHash` names the prior state when the caller knows only *which*
    version was live (the daemon's replication checkpoint, the CLI's note of
    what it last recorded) and the module reconstructs its bytes from the
    graph. What the caller offers wins over what the graph would guess; the
    graph supplies the base only when the caller offers nothing.
  - `merge(path, branchLeaf, into, writer)` — record that a divergent line
    has been reconciled (see *Merge*).
- **An injected history store**: list the header lines of every version file
  under `.hist/<path>/`, read one file, write one new file. The daemon
  backs it with the real mirror folder; the app with its sandbox storage.
- **The live content's hash** when a graph is requested — which lineage is
  *primary* is a fact about the file, not about this module (see *Reader
  rules*).
- **A clock** (injected for testability) and **configuration**: the tracked
  extension list (default `.md`) and the snapshot-checkpoint interval (a few
  hundred patches).

**This module holds no per-path state between calls.** There is no baseline
to persist, no pending edit, no timer: each commit recovers what it needs
from the folder it is about to write into, falling back to what the caller
hands it. Statelessness is what makes an explicit commit verb worth having —
two processes, a restart mid-edit, or a replayed call cannot desynchronize
anything, because there is nothing to desynchronize.

## Outputs

- **New immutable version files** in `.hist/<path>/` — one small file per
  recorded version; existing files are never modified, moved, or deleted
  (RV5).
- **A version graph** per path, on request: nodes (version hashes), edges
  (patches), roots (snapshots), the **primary line** (root → the live
  content's hash), and **branches** — each identified by its **leaf hash**,
  classified as *divergent*, *archived* or *merged*, and labelled with the
  writers that contributed to it.
- **Reconstructed content** of any version, verified step by step; a version
  whose reconstruction fails verification is flagged **broken**, never shown
  silently wrong (RV5).

## Behavior

### Storage layout (R13, RV5)

- The mirror is `.hist/` at the vault root; the history of file `P` lives
  under `.hist/P/` (the file's path becomes a folder). The mirror is
  invisible to Obsidian's indexing (dot-folder).
- `.hist/` itself is **excluded from history tracking** (no
  history-of-history) but **included in sync** — the shells replicate it like
  any other files (RV8).
- A version file is named `<utc-epoch-ms>.<type>` where the timestamp is
  **13 digits, zero-padded**, so lexicographic order equals chronology, and
  `<type>` is one of `snapshot | patch | deleted | conflict | merged`. The timestamp is
  for humans and sorting only — **identity and linkage are the hashes in the
  headers** (RV5). If the name a writer wants is already taken, it bumps the
  millisecond value until free; names must be unique, nothing more.
- File structure: header lines `key: value`, one per line, then an empty
  line, then the body. Because the header ends at the first blank line, a
  reader that needs only headers — every graph, every traversal — reads a
  **prefix** of each file, never the whole: a snapshot is a whole note, and
  a count over the vault must stay cheap enough to ask for (R18).

| type | header keys | body |
|---|---|---|
| `snapshot` | `version`, `writer`, optional `renamed_from` | the full content |
| `patch` | `version`, `prev`, `writer` | forward dmp patch text `prev → version` |
| `deleted` | `prev`, `writer`, optional `renamed_to` | none |
| `conflict` | `version`, `writer` | full content of a losing **binary** version |
| `merged` | `merged`, `into`, `writer` | none |

- `version` / `prev` are lowercase-hex sha256 of the **content bytes as-is**
  (no newline normalization). Content must be valid UTF-8 for `snapshot` /
  `patch`; a file that is not valid UTF-8 is binary and is not versioned
  (RV5).
- Patches are produced as `diff_main` + `diff_cleanupEfficiency` +
  `patch_make` with default settings, serialized with `patch_toText` — the
  interoperable diff-match-patch text format shared by the Dart writer and
  any JS reader; interop is pinned by tests (C5, RV5).

### What gets history

Only files whose extension is in the tracked list (default: `.md`) and whose
content is valid UTF-8. Binaries get no diffs — they are write-once; their
only history appearance is a `conflict` rescue copy (RV9). Paths excluded
from sync by the shell are excluded from tracking too.

The list also accepts **`*`**, meaning *any* file whose content is text. That
is not a loophole: content is already the real filter — a file that is not
valid UTF-8 is never versioned whatever it is called — so `*` simply stops the
name being a second, weaker filter. Enumerating extensions can never be
complete (`.txt`, `.json`, `.yaml`, `.csv`, `.toml`, `.svg`, …), and a vault
whose owner wants history for everything textual should not have to predict
what they will one day store. Extensionless files are tracked under `*` too,
and only then — a name with no dot matches no extension.

### Commit rules (RV5, RV6)

`commit(path, b, writer)` is one act with no memory. Nothing is remembered
between calls; the base `a` is **recovered, not stored**:

- from the **caller**, first, when it offers the previous content — the
  daemon can, by materializing the revision its reconciliation cursor points
  at — or when it names the previous version's **hash**, which the module
  reconstructs from the graph exactly as any reader would (a hash the folder
  does not hold is no base at all). The caller's word wins over the graph's
  guess: after a rollback the graph's one open leaf is the abandoned state,
  and only the caller knows the edit was made on the restored one;
- from the **graph**, otherwise, whenever the previous state is already a
  version in the folder — the normal steady state, since the previous state
  was itself committed. Its content is reconstructed the same way any
  version is. The graph can only answer when exactly **one line is open** —
  one recorded version with no outgoing edge, no `deleted` marker and no
  `merged` marker naming it; where several lines are open (a divergent
  branch, a rollback that stranded a leaf) the caller must say which one it
  edited, because guessing by filename would let a skewed clock pick the
  base;
- and when neither is available (a file that predates history, a writer whose
  history has not arrived), there is no base to diff from, so `b` is recorded
  as a **root snapshot**. A patch needs the base's *bytes*, not just its
  hash; inventing one would produce a diff that reconstructs to garbage.

A commit whose `b` equals the recovered base records nothing, so calling
twice costs nothing.

**Timing is the caller's contract, not this module's** (D7). Editors save by
writing a temporary file and renaming it, or by deleting and recreating; a
caller that forwards those raw events verbatim would record a `deleted`
marker and a new root for every ordinary save. The daemon therefore coalesces
events into one settled state per edit before committing — that is where the
idle window lives (`vault_daemon`). This module records exactly what it
is handed, which is why it can be stateless.

- **Recording** compares the derived base `a` → the committed state `b`:
  - `a → b`, same hash — record nothing (dedup).
  - `a → b`, and `b`'s hash **already exists in the folder** — record
    nothing. This is a rollback/restore to a known version: writing an edge
    would point backward and create a cycle. The graph is a set of *states*
    and recorded edits between them; "current" is the live file's pointer,
    not an edge (RV5).
  - `a → b`, otherwise — **the anchor rule**: if `a`'s hash is not present in
    the folder but its bytes are known, first write `snapshot(a)`; then write
    `patch(a → b)`. This covers the first-ever version, files that existed
    before history did, and a new writer whose history hasn't arrived yet.
    Redundant snapshots of one version are content-identical; the reader
    dedups. With no base bytes at all, `b` is a root snapshot instead.
  - `absent → w` (file appeared): if `w`'s hash exists in the folder — record
    nothing (a restore); otherwise write `snapshot(w)` as a **new root** in
    the same folder. A recreation after deletion is a new life: a diff across
    unrelated content is snapshot-sized anyway and semantically a lie (RV5).
  - `a → absent` (file gone): write `deleted` with `prev = a`'s hash. The
    marker is required — it tells the reader when a life ended and which leaf
    was live. The history folder itself is **preserved** for recovery (R15).
- **A change that arrived through sync is never committed.** It was recorded
  at its source, and re-recording it here would mint a second edge for one
  edit and attribute it to the wrong writer. The caller commits **local edits
  only**, and a local edit that raced an incoming one is committed **before**
  the arrival is applied, so it records from the base it was actually made on
  (RV6) — ordering the caller controls precisely because the timing is its
  job.
- **The writer is required.** Every file records the non-empty `writer` that
  produced it, so every edit is attributable. The name identifies the device
  and must be stable; it is **not** the identity of a lineage (see *Reader
  rules*), so renaming a writer never reshapes the graph.
- **Snapshot checkpoints**: when the patch chain from the nearest snapshot
  ancestor grows past the checkpoint interval (hundreds), the writer records
  the next version as a `snapshot` instead of a `patch` — same file type, no
  new mechanism; it just shortens reconstruction (RV5).

### Rename (RV7)

History folders **never move** — append-only applies to folders too, because
a moved folder would resurrect from other replicas and mutate synced files.
On a rename detected by the shell (`vault_daemon` detects it by content
hash while coalescing events):

- into `.hist/old/`: a `deleted` marker with `prev = <hash>` and
  `renamed_to: new`;
- into `.hist/new/`: a `snapshot` with `version = <hash>` and
  `renamed_from: old`.

A rename the shell does not recognize degrades to plain delete + create —
the old history stays intact under the old name, merely without the link
(R16).

### Conflict losers (RV9)

When sync resolves a conflict (LWW winner), the **losing text version needs
nothing**: its author already recorded it — on every device it appears as a
dead-end branch in the graph. Only a losing **binary** is rescued: the shell
writes a `conflict` file with the full bytes (otherwise the losing binary
would be gone forever). The receiver never records text losers (RV6, RV9).

### Reader rules (RV5)

1. Read the headers of every file in `.hist/<path>/`; build the graph:
   nodes = version hashes, edges = patches (`prev → version`), roots =
   snapshots. Dedup edges by `(prev, version)` and snapshots by `version`.
2. The **primary line** is the path from a root to the hash of the content
   that is **live** — the winner the sync layer chose for this file
   (`vault_sync`). It is never derived from timestamps: names sort for humans,
   but "clock skew reorders filenames, not the graph", so a device with a
   wrong clock must never be able to take the primary line, and a late-arriving
   offline device must never move it retroactively. Tying it to the live
   content also keeps **one** answer to "what is real": the file on disk and
   its history always name the same lineage.
3. Everything not on the primary line is a **branch**, identified by its
   **leaf hash** — never by the writer that produced it, so renaming a writer
   never reshapes the graph. Each branch is one of three kinds, and the
   distinction is what a surface needs to avoid nagging about settled things:
   - **divergent** — it forks from a shared ancestor and its leaf is neither
     merged nor ended by a `deleted` marker. Another writer's line, still
     open; this is the only kind that can be merged.
   - **merged** — a `merged` marker names its leaf (see *Merge*). It stays in
     the history exactly as it was, but it is settled: a surface lists it and
     stops asking for it.
   - **archived** — a previous life (its leaf ends in a `deleted` marker) or a
     line the owner abandoned by rolling back. Nothing to merge: these are the
     owner's own discarded states, not somebody else's work. **A single writer
     can produce these** — rollback and delete-then-recreate both do — so
     "only one writer" never means "no branches".

   Whose line it is, is read from its **edits**: the writers of a line are
   the writers of the patches along it — including the patch that forks it
   off — and a snapshot's writer counts only for a line that is nothing but
   that snapshot. A snapshot may be an **anchor**, written by a device that
   merely held the state when it made its first edit; an anchor says "I saw
   this", not "I made this", and two devices anchoring the same base must
   not make each other's edits look like the owner's own. A branch whose edit
   writers all appear among the primary line's edit writers is archived; one
   carrying a writer the primary line lacks is somebody else's, still open.
   This is why writer names must be stable and unique per device.
4. **Reconstruction** of a version: start at its nearest snapshot ancestor,
   apply patches along the chain, and **verify sha256 against the declared
   `version` after every step**. On mismatch the version is flagged broken —
   dmp applies patches fuzzily and produces garbage without error on a wrong
   base; silent wrongness is forbidden (RV5).
5. A live file whose hash is not yet in the graph is "unsaved changes after
   version X" — an edit the caller has not committed yet.
6. `renamed_from` / `renamed_to` are display links: history under the old
   name is reachable from the new (S6).

### The read surface: addressing, log, show

The graph answers "when"; the surface below answers "which", "what changed"
and "what did it look like then", over the storage exactly as it is — nothing
here writes, and nothing here caches inside the vault.

- **Addressing (R1).** A version is addressable by its full hash; by an
  **unambiguous short prefix** — an ambiguous one is an error that names the
  candidates, never a guess, and a prefix shorter than four characters is
  refused; by `HEAD`, the live content's version — an error when the live
  file is unrecorded ("unsaved changes after X") or absent, because there is
  no live version to name; by `HEAD~n`, `n` steps back along the primary
  line, an error past its root; and by date, `@{<instant>}`, the primary-line
  version live at that instant — the latest whose recorded time is not after
  it (a date alone means the start of that day, local time). The date form
  is the one address that rests on the recording devices' clocks, which are
  not authoritative, and the surface says so where it documents it.
- **Log (R2).** For one file: the primary line, newest first — each entry
  naming the version, its writers and its time, and marking the live one.
  Ordering along the line comes from the graph and is exact. With **all**
  lines requested, every branch follows, identified by its leaf, labelled
  with its kind and the writers that contributed. A file with no live
  version (deleted, or unrecorded on disk) has no primary line, so every line
  is listed as a branch and the log says why. Entries can be filtered by
  time, by writer and by count.
- **Show (R3).** The content of any addressable version, reconstructed with
  the per-step verification above; a version that fails verification is
  reported **broken**, and its bytes are never shown.
- **Diff (R4).** The difference between any two addressable versions as a
  **unified diff** — line-based, with context, `---`/`+++` headers and
  `@@` hunks. It is a rendering over two reconstructed, verified contents,
  never a replay of the stored patches: the storage holds character-level
  dmp patches whose application is fuzzy, and a diff across a snapshot
  checkpoint has no single stored patch to show. A side that cannot be
  verified makes the whole diff **broken** rather than diffing garbage.
- **Blame (R5).** Each line of an addressable version attributed to the
  version that introduced it and to that version's writer — by replaying
  the chain from the root to the version, reconstructing every step
  verified, and carrying each surviving line's attribution forward through
  a line diff of each step. A line the version itself introduced is
  attributed to it. This is the first thing that makes the writer header
  pay for itself.

### Merge (RV6)

Two writers diverge; later the owner reconciles them. What must survive is
that the divergent line is **settled** — still there, no longer asking to be
dealt with. That is recorded as a **marker, not as topology**:

- The reconciled content is committed as an **ordinary version on the primary
  line** — one parent, one edge, exactly like any other edit. Reconstruction
  is unchanged: still a single chain from the nearest snapshot with a hash
  check after every step.
- A `merged` file records `merged: <branch leaf hash>` and `into: <the
  resulting version's hash>`. It writes nothing over the branch and removes
  nothing: the branch stays byte-for-byte as it was, reachable and readable.
- **No record ever has two parents.** The single-edge invariant is what keeps
  reconstruction a chain and keeps history files conflict-free in sync; a
  merge changes neither. The marker carries what a merge commit would have
  carried — the second lineage — as a fact instead of an edge, which is more
  than a squashed merge preserves.

Rules the reconciliation itself must respect:

- **Merging is per file.** There is no vault-wide merge act; a surface
  reporting "five branches to deal with" is reporting five files whose writer
  lines diverged.
- **A branch is merged if _any_ marker names its leaf**, whoever wrote it.
  Two devices reconciling the same branch concurrently produce two markers and
  two candidate contents; sync picks one content by its usual rule, both
  markers survive, and the branch is settled once. Re-merging an already
  merged branch is a no-op, so a surface can never loop on it.
- **Lines with no common ancestor cannot be merged line-by-line.** Separate
  lives, and a writer that anchored its own snapshot before another's history
  arrived, are unrelated roots. The surface offers choosing one side whole;
  it never pretends a three-way merge happened without a base.
- Merging is **only** offered for *divergent* branches. Archived ones are the
  owner's own discarded states — there is nothing there to reconcile.

### The reconciliation inputs: the fork point, and `diff3` (R9', R9'', R10)

By the time a divergence is visible, sync has already converged: the live
file on every device is the LWW winner, and the divergence survives only in
the graph. A surface therefore rescues content out of history back into the
one live reality, and this module supplies the two inputs it needs:

- **The fork point** of a branch: the nearest ancestor of its leaf that lies
  on the primary line, found by following `prev` links back from the leaf.
  A branch with no such ancestor — a separate life, or a line anchored
  before another's history arrived — has none, and the surface may then
  only offer a side whole; it never pretends a three-way merge happened
  without a base.
- **A three-way merge, `diff3`**, of exact inputs: the common ancestor `A`
  (the fork point), the live content `L` and the branch leaf `B`, all
  reconstructed and verified. It is line-based: where one side alone
  changed a region of `A`, that side's lines are taken; where both changed
  it identically, either; where both changed the same or touching lines
  differently, the output carries an **explicit conflict region** —
  `<<<<<<<` the live lines, `|||||||` the ancestor's, `=======`, the
  branch's, `>>>>>>>` — for the owner to resolve. It never guesses, and it
  never applies the stored character-level patches: their application is
  fuzzy and returns plausible garbage without error, which this module
  forbids.
- **The divergence count** (R16, R18) is **derived**, never stored: how
  many *files* — not branches (R13) — have at least one divergent line,
  computed from each path's graph against its live content. Nothing new is
  written to know it; what it costs is the header traversal above, which is
  why headers are read as prefixes. A host that observes history writes —
  its own commits, and files arriving through sync, which is how a
  divergence appears in the first place — can keep the count incrementally
  and recount in full only on a periodic pass.
- **Settling** is what the surface then records with the verbs above: the
  composed content as an ordinary single-parent version based on `L`, and
  a `merged` marker naming `B` and the result. Taking a side whole needs no
  new version: taking the branch is a restore of `B` (already recorded, so
  the live pointer moves) plus a marker naming the line that *was* live;
  keeping the live side is the marker alone, naming `B` and `L`. In every
  form the marker names **the leaf that is not live** and **the version
  that is**.

### Multi-writer correctness (RV6)

Because every version file is immutable and uniquely named, and because the
graph links by content hashes, any interleaving works: two writers recording
the same version produce content-identical duplicates (deduped by the
reader); a device long offline contributes its files late and they connect by
hash; clock skew reorders filenames but not the graph. History files are
conflict-free in sync **by construction** (RV5).

## Non-goals

- **Not sync, not crypto.** History files replicate as ordinary encrypted
  documents; this module never replicates or encrypts anything (RV1).
- **No rename detection** — the shell detects; this module records the
  markers (RV7).
- **No history for binaries** beyond `conflict` rescue copies (dmp is
  text-only).
- **No git, no server-side history, no plaintext server-side** (N4, C5).
- **No multi-parent records.** A reconciliation is recorded as an ordinary
  single-parent version plus a `merged` marker — one history file is one
  edge, always. Reconstruction stays a chain and history files stay
  conflict-free in sync because of it (RV5).
- **No named branches, no tags, no commit messages.** A lineage is identified
  by its leaf hash and attributed to its writer; nothing here is named by
  hand, so nothing can be renamed, collide, or need reconciling of its own.
- **No timing policy.** No debounce, no idle window, no timers: *when* to
  record is the caller's decision (`vault_daemon`), and this module
  records exactly what it is handed (D7).
- **No mutation, ever**: no compaction that rewrites, no pruning, no folder
  moves (RV5, RV7).
- **Not a UI.** Viewing/restoring is a client concern: the standalone
  history CLI (`vault_hist_cli`), the daemon's `hist` verbs over the vaults
  it serves, a future Obsidian viewer. This module supplies the addressing,
  the log entries and the reconstruction they render.

## Examples

### Two edits, then read an old version (RV5)

`notes/foo.md` is created as `"A"`; the daemon commits once the edit has
settled, and the anchor rule applies — no live lineage, unknown hash → writes
`0000000000001.snapshot` (`version: sha(A)`). Editing to `"AB"` writes
`0000000000002.patch` (`version: sha(AB)`, `prev: sha(A)`, body
`patch(A→AB)`). Reconstructing `sha(A)`: it is a snapshot — read directly;
reconstructing `sha(AB)`: apply the patch to `"A"`, verify sha256 — match.

### Offline catch-up: pieces connect by hash (RV6)

Laptop (offline) edits `plan.md`: A→B→C, recording two patches. Meanwhile the
phone edits the same file A→D and its patch has already synced everywhere.
When the laptop reconnects, its files arrive; every reader now sees roots and
edges `{A→B, B→C, A→D}` — a fork at A, no conflicts among history files, and
whichever content won the note's LWW determines the primary line; the other
is a **divergent** branch, open until someone reconciles it. Had the laptop's
clock been days off, nothing would change: the primary line follows the live
content, not the filenames.

### Rollback records nothing (RV5)

The owner restores `"A"` over a file whose graph already contains `sha(A)`.
The commit sees the hash already in the folder → no file written. The next
real edit `A→E` diffs from `A`. No cycle ever enters the graph — and `B`, `C`
beyond the fork become an **archived** branch: one writer, a real branch,
nothing to merge.

### Delete, then recreate = new root (RV5)

`todo.md` (`X`) is deleted → `…deleted` with `prev: sha(X)`; the folder
stays. Weeks later a new `todo.md` (`Y`) appears; `sha(Y)` is unknown →
`snapshot(Y)` starts a **new root** in the same folder. The reader shows the
old life (ending at the marker, with its date) as an **archived** branch and
the new life as the primary line. Nothing here asks to be merged.

### Raced local edit records from the right base (RV6)

The app saved `"B"` over `"A"`, and a remote winner `"C"` arrived before the
edit had settled. The caller commits `"B"` **before** applying `"C"`, so it
records `patch(A→B)` — the base it was really made on — and the arrival is
never committed at all. The local edit survives as a divergent branch even
though `"C"` now owns the live file.

### A divergent branch is settled without a merge node (RV6)

`plan.md` forks at `A`: the phone's line ends at `D`, the laptop's `C` won and
is live. The owner reconciles them into `"E"`. Two files are written: an
ordinary `patch(C→E)` on the primary line — one parent, like any edit — and a
`merged` marker naming `merged: sha(D)`, `into: sha(E)`. `D`'s line is
untouched and still readable, but it is no longer open: a surface lists it as
settled and stops asking. Reconstruction of `E` is still one chain from the
nearest snapshot, hash-checked at every step.

### A losing binary is rescued (RV9)

`img/logo.png` conflicts; the remote version wins LWW. The shell writes
`.hist/img/logo.png/<ts>.conflict` with the losing bytes. A losing *text*
version gets no such file — its author's patch is already in the folder and
shows as a branch.
