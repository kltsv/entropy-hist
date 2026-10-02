---
tests: vault_hist
---

# Vault history — test-spec

Agnostic test cases for the `vault_hist` module, in strict Arrange / Act /
Assert form. Terms used below:

- **history** — the module under test (writer + reader), given an injected
  history store (the `.hist/` mirror), an injected clock, and configuration:
  writer name (`laptop` unless a case says otherwise), tracked extensions
  `[.md]`, snapshot-checkpoint interval (set per case). It holds **no state
  between calls**: no baseline, no pending edit, no timer.
- **commit(path, content, t)** / **commit(path, absent, t)** — record this
  state as the next version, at clock time `t` ms. The caller decides when to
  call; the module has no debounce of its own.
- **merge(path, leaf, into, t)** — record that the branch ending at `leaf`
  has been reconciled into the version `into`.
- **sha(X)** — lowercase-hex sha256 of the exact bytes of `X`.
- History files "arriving through sync" simply appear in the store — placed
  there externally, never via a commit.
- **graph(path, live)** — the reader's output for `.hist/<path>/` given the
  **live content's hash**: nodes, edges, roots, the primary line, and
  branches with their kind (`divergent` / `merged` / `archived`).
- **materialize(path, h)** — the reader reconstructs the content whose sha256
  is `h`.
- Where a case names the live file, `graph(path)` is shorthand for
  `graph(path, sha(<that content>))`; the live hash is always an input,
  never something the module infers from timestamps.

## File format and layout (RV5)

### a version file is named 13-digit zero-padded epoch-ms plus its type

- **Arrange:** empty history; the injected clock reads `999999999999` ms
  (12 digits).
- **Act:** `commit("notes/foo.md", "A", 999999999999)`.
- **Assert:** exactly one file exists, at
  `.hist/notes/foo.md/0999999999999.snapshot` — the timestamp is padded to
  13 digits with a leading zero, the extension is one of
  `snapshot | patch | deleted | conflict`, and the file's path became a
  folder under the `.hist/` mirror.

### filenames sort lexicographically in chronological order

- **Arrange:** empty history.
- **Act:** record three flushed versions of `n.md` at clock times
  `999999999999`, `1700000000000`, `1700000100000`.
- **Assert:** sorting the filenames in `.hist/n.md/` lexicographically
  yields them in ascending chronological order — the zero-padding is what
  makes `0999999999999…` sort before `1700000000000…` (unpadded it would
  sort after).

### a snapshot file is headers, a blank line, then the full content

- **Arrange:** empty history.
- **Act:** `commit("notes/foo.md", "A", t)`; read the
  written file raw.
- **Assert:** the file consists of header lines in `key: value` form, one per
  line — among them `version: <sha(A)>` and `writer: laptop` — followed by
  exactly one empty line, followed by the body `A` (the full content, not a
  diff).

### a patch file links prev to version with a forward dmp body

- **Arrange:** history where `notes/foo.md = "A"` is recorded (root snapshot
  present; the live file is `"A"`).
- **Act:** `commit("notes/foo.md", "AB", t)`; read the new
  file raw.
- **Assert:** exactly one new file `<ts>.patch` was written; its headers
  include `version: <sha(AB)>`, `prev: <sha(A)>`, and `writer: laptop`; its
  body is diff-match-patch patch text for the **forward** edit — applying it
  to `"A"` yields `"AB"`.

### version and prev are sha256 of the content bytes as-is

- **Arrange:** empty history.
- **Act:** record `notes/foo.md` with content `"A\n"` (trailing newline).
- **Assert:** the snapshot's `version` header is the lowercase-hex, 64-char
  sha256 of exactly the bytes `A\n` — including the newline, no
  normalization — and differs from `sha("A")`.

### every version file names its writer

- **Arrange:** history configured with writer name `phone`; a scenario that
  produces all four types: create + edit `a.md` (snapshot, patch), delete it
  (deleted), and a losing-binary conflict rescue on `img/x.png` (conflict).
- **Act:** read the headers of every written file.
- **Assert:** each of the four files — snapshot, patch, deleted, conflict —
  carries the header `writer: phone`.

### a taken filename bumps the millisecond until free

- **Arrange:** history for `f.md` whose live state is `"A"`;
  `.hist/f.md/1700000000000.patch` already exists in the store (it arrived
  through sync from another writer).
- **Act:** `commit("f.md", "AB", …)` with the clock reading
  `1700000000000` at flush time.
- **Assert:** the writer's new patch is named `1700000000001.patch` (the
  millisecond value bumped until free); the pre-existing file is untouched;
  both files coexist — names must be unique, nothing more, and identity
  stays in the hash headers.

### the mirror never tracks itself

- **Arrange:** empty history.
- **Act:** `commit(".hist/notes/foo.md/0000000000001.snapshot",
  "version: x\n\nA", t)`.
- **Assert:** nothing is recorded — no `.hist/.hist/…` folder ever
  appears; paths under the mirror root are excluded from tracking (no
  history-of-history), even though the shell syncs them like any other files
  (RV8).

### history files are never modified, moved, or deleted

- **Arrange:** empty history.
- **Act:** run a full lifecycle on `f.md`: create `"A"`, edit to `"B"`,
  restore `"A"`, delete, recreate as `"C"` (each step flushed); after every
  step, capture the byte content of every file in `.hist/f.md/`.
- **Assert:** every file, once written, is byte-identical in all later
  captures; no file is ever renamed or removed — the store only ever gains
  files.

## Commit — stateless, and it records what it is handed (D7, RV5)

### with no base bytes available, the commit is a root snapshot

- **Arrange:** a file `pre.md` that predates history; `.hist/pre.md/` is
  empty and the caller **cannot** produce the previous bytes.
- **Act:** `commit("pre.md", "new", t)`.
- **Assert:** exactly one file: a root `snapshot` of `"new"`. No patch is
  invented from a base whose bytes are unknown — a diff against a guessed
  base reconstructs to garbage, and silent wrongness is forbidden.

### the module keeps no state between commits

- **Arrange:** history with `notes/foo.md = "A"` recorded.
- **Act:** commit `"AB"`; then **discard the module instance entirely** and
  build a fresh one over the same store; then commit `"ABC"`.
- **Assert:** the second instance writes `patch` with `prev: <sha(AB)>` — it
  derived the base from the folder, having never seen the first commit. No
  baseline was persisted anywhere, and no configuration carried it over.

### committing the same state twice records nothing the second time

- **Arrange:** empty history.
- **Act:** `commit("notes/foo.md", "A", t)` twice.
- **Assert:** exactly one snapshot exists. A replayed commit is harmless —
  the second call derives base `sha(A)` and sees `b` equal to it.

### unchanged content records nothing

- **Arrange:** history with `notes/foo.md = "A"` recorded.
- **Act:** `commit("notes/foo.md", "A", …)` (the file was re-saved with
  identical bytes).
- **Assert:** no new file is written — `b` hashed equal to the derived base.

### raw editor events are the caller's problem, not this module's

- **Arrange:** history with `notes/foo.md = "A"` recorded.
- **Act:** commit `absent`, then commit `"AB"` — i.e. a caller that forwarded
  a delete-then-write save verbatim instead of coalescing it.
- **Assert:** the module records exactly what it was told: a `deleted` marker
  **and** a new root snapshot of `"AB"` — two lives, not one edit. This is
  the documented consequence of the caller skipping its coalescing duty
  (`vault_daemon` owns the timing); the module invents no window of its
  own to paper over it.

### rollback to a known version records nothing and strands a branch

- **Arrange:** history for `f.md` containing `snapshot(A)` and
  `patch(A → B)`; live file `"B"`.
- **Act:** `commit("f.md", "A", t)` (the owner restored version `A`); then
  `commit("f.md", "E", t')` with the live file now `"E"`.
- **Assert:** the restore itself writes **no** file — `sha(A)` already exists
  in the folder. The subsequent edit writes exactly one `patch` with
  `prev: <sha(A)>`, `version: <sha(E)>` (no anchor snapshot — `sha(A)` is
  present). The edge set is `{A→B, A→E}` — no edge ever points backward, no
  cycle enters the graph — and `graph("f.md", sha(E))` reports `B` as an
  **archived** branch: a single writer, a real branch, nothing to merge.

### a caller that names the previous version's hash gets it reconstructed as the base

- **Arrange:** `f.md` forks at `A`: `A → C` (live, this writer) and `A → D`
  (another writer's open line) — two lines open, so the graph alone cannot
  name a base; the caller has no previous bytes but knows the live version
  was `C`.
- **Act:** `commit("f.md", "E", t)` with `previousHash = sha(C)`.
- **Assert:** exactly one `patch` with `prev: <sha(C)>`, `version: <sha(E)>`
  is written — the base's bytes were reconstructed from the graph. Naming a
  hash the folder does not hold yields no base: the same commit with an
  unknown `previousHash` records `E` as a root snapshot.

### a leaf settled by a merged marker no longer counts as an open line

- **Arrange:** `plan.md` forked at `A` into `A → C` (live) and `A → D`; the
  owner reconciled them into `E` (`patch(C → E)` plus `merged: sha(D)`,
  `into: sha(E)`).
- **Act:** a fresh module instance with no `previous` commits `"F"`.
- **Assert:** the graph supplied the base: exactly one `patch` with
  `prev: <sha(E)>` is written. `D` is settled, so only one line is open —
  without the marker the two open leaves would have left the commit no base.

## Writer — anchors and lifecycle (RV5, RV6)

### the first version of a new file is a root snapshot

- **Arrange:** empty history.
- **Act:** `commit("notes/foo.md", "A", t)` (file created).
- **Assert:** exactly one file, `<ts>.snapshot`, with `version: <sha(A)>` and
  body `"A"` — a root; no patch is written and no `prev` header exists.

### an edit on a recorded state writes a single patch

- **Arrange:** history with `snapshot(A)` for `notes/foo.md`; live
  `sha(A)`.
- **Act:** `commit("notes/foo.md", "AB", t)`.
- **Assert:** exactly one new file, a `patch` `A → AB`; no additional
  snapshot — the anchor rule does not fire because `sha(A)` is already in
  the folder.

### a file that predates history is anchored by its first edit

- **Arrange:** a file `pre.md = "old"` exists in the vault and
  `.hist/pre.md/` does not exist (the file predates history). The caller can
  still produce the previous bytes `"old"` (the daemon materializes the
  revision its cursor points at) and offers them with the commit.
- **Act:** `commit("pre.md", "new", t)` with previous `"old"` — the first
  edit since. Nothing was committed for the file before this.
- **Assert:** the first encounter writes nothing. The first real edit fires
  the **anchor rule** — `sha(old)` is absent from the folder — so exactly
  two files are written, in order: `snapshot` with `version: <sha(old)>` and
  body `"old"`, then `patch` with `prev: <sha(old)>`,
  `version: <sha(new)>`. The pre-history content is preserved whole.

### a new writer whose history has not arrived anchors with its own snapshot

- **Arrange:** a second device (writer `phone`): sync delivered `f.md = "A"`
  and the file is live on disk, but `.hist/f.md/` is empty — the history
  files from the first device have not arrived yet.
- **Act:** `commit("f.md", "B", t)`. Later, the first
  device's files arrive through sync: its own `snapshot` with
  `version: <sha(A)>` appears in the folder.
- **Assert:** the commit writes `snapshot(A)` then `patch(A → B)`, both with
  `writer: phone` — the anchor rule covers a writer that cannot see history
  yet. After the late files arrive, the folder holds two snapshot files
  declaring the same `version: <sha(A)>`; `graph("f.md", sha(B))` shows a **single**
  root node `sha(A)` — redundant snapshots dedup by version.

### deletion writes a mandatory deleted marker and preserves the folder (R15)

- **Arrange:** history for `todo.md` with `snapshot(X)` and `patch(X → X2)`;
  the live file is `X2`.
- **Act:** `commit("todo.md", absent, t)`.
- **Assert:** exactly one new file, `<ts>.deleted`, with headers
  `prev: <sha(X2)>` and `writer: laptop` and **no body** — the marker tells
  the reader when this life ended and which leaf was live. The folder
  `.hist/todo.md/` and every earlier file in it are kept intact, so the
  file is recoverable after deletion.

### recreation with an unknown hash starts a new root

- **Arrange:** history for `todo.md` ending in a `deleted` marker with
  `prev: <sha(X)>`; the path has no live lineage.
- **Act:** `commit("todo.md", "Y", t)` where `sha(Y)` appears nowhere in
  the folder.
- **Assert:** exactly one new file, `snapshot` with `version: <sha(Y)>` — a
  **new root** in the same folder. No patch links `X` (or `X2`) to `Y`: a
  diff across unrelated content would be snapshot-sized anyway and
  semantically a lie.

### recreation with a known hash is a restore and records nothing

- **Arrange:** history for `todo.md` containing `snapshot(X)` and a `deleted`
  marker with `prev: <sha(X)>`; no live lineage.
- **Act:** `commit("todo.md", "X", t)` (the owner restored the deleted
  file from history).
- **Assert:** no new file is written — `sha(X)` already exists in the
  folder; the live lineage is `sha(X)` again.

### a local edit racing an arrival is committed from the base it was made on

- **Arrange:** history for `f.md` with `snapshot(A)` recorded; live file
  `"A"`.
- **Act:** the caller commits the local save `"B"` **before** applying the
  arriving winner `"C"` — the ordering `vault_daemon` guarantees — and
  the arrival itself is never committed.
- **Assert:** exactly one new file is written: `patch` with
  `prev: <sha(A)>`, `version: <sha(B)>` — recorded from the base it was
  actually made on. Nothing records `"C"`: its own writer already did, and a
  second edge for one edit would attribute it to the wrong device. With `C`
  live, `graph("f.md", sha(C))` shows `B` as a **divergent** branch.

### an arrival is never committed, and the next local edit anchors on it

- **Arrange:** history for `f.md` with `snapshot(A)` recorded; the winner
  `"C"` has been materialized on disk and, as always, not committed.
- **Act:** commit the next local edit `"D"` made on top of `C`.
- **Assert:** `sha(C)` is absent from the folder, so the anchor rule writes
  `snapshot(C)` then `patch(C → D)` — the edit diffs from `C`, not from `A`,
  without the module having been told anything about the arrival.

### a long patch chain gets a snapshot checkpoint

- **Arrange:** history configured with snapshot-checkpoint interval 3 (the
  interval is configurable; the default is a few hundred). `f.md` is
  recorded as `snapshot(v0)` and then three commits producing
  `patch(v0→v1)`, `patch(v1→v2)`, `patch(v2→v3)`.
- **Act:** one more commit, `v3 → v4`.
- **Assert:** the new version is recorded as `<ts>.snapshot` with
  `version: <sha(v4)>` and the **full content** of `v4` as body — not a
  patch. It is the same ordinary snapshot type, no new mechanism;
  `materialize("f.md", sha(v4))` reads it directly instead of replaying four
  patches.

### an untracked extension is never versioned

- **Arrange:** empty history; tracked extensions at the default `[.md]`.
- **Act:** `commit("img/logo.png", <some bytes>, t)`; edit
  and delete it likewise.
- **Assert:** `.hist/img/logo.png/` is never created and no file of any
  type is written — binaries get no diffs; their only possible history
  appearance is a `conflict` rescue copy.

### the wildcard tracks any text file, and still never a binary

- **Arrange:** history configured with the tracked list `['*']`.
- **Act:** commit a `.json`, a `.txt`, a file with **no extension**, and a
  file whose bytes are not valid UTF-8.
- **Assert:** the first three are versioned exactly like a `.md` would be —
  snapshot then patches. The fourth records **nothing**: content is the real
  filter, and `*` only stops the *name* being a second one.

### invalid UTF-8 is never versioned

- **Arrange:** empty history.
- **Act:** `commit("notes/x.md", <bytes that are not valid UTF-8>, t)`.
- **Assert:** nothing is recorded despite the tracked `.md` extension —
  content must be valid UTF-8 for `snapshot` / `patch`; a file that is not
  valid UTF-8 is binary.

## Rename (RV7)

### a detected rename writes linked markers and moves no folder

- **Arrange:** history for `doc/a.md` with recorded versions ending at
  content `X` (live).
- **Act:** the shell reports a detected rename `doc/a.md → doc/b.md`
  (detected by content hash within its debounce window).
- **Assert:** `.hist/doc/a.md/` gains a `deleted` marker with
  `prev: <sha(X)>` and `renamed_to: doc/b.md` (no body);
  `.hist/doc/b.md/` gains a `snapshot` with `version: <sha(X)>`, body
  `X`, and `renamed_from: doc/a.md`. The old folder still exists with every
  prior file intact — **no folder is moved**, because a moved folder would
  resurrect from other replicas.

### an unrecognized rename degrades to delete plus create (R16)

- **Arrange:** history for `doc/a.md` with recorded versions ending at `X`.
- **Act:** the shell does not recognize the rename and reports
  `commit("doc/a.md", absent, t)` and `commit("doc/c.md", "X", t)`.
- **Assert:** `.hist/doc/a.md/` gains a plain `deleted` marker with
  `prev: <sha(X)>` and **no** `renamed_to`; `.hist/doc/c.md/` starts with
  a root `snapshot(X)` with **no** `renamed_from`. The old history stays
  intact under the old name, merely without the link — nothing is lost.

## Conflict losers (RV9)

### a losing binary is rescued whole into a conflict file

- **Arrange:** history with writer name `laptop`; sync resolves a conflict on
  `img/logo.png` by LWW and the local binary version (bytes `LB`) loses.
- **Act:** the shell reports the losing binary for rescue at clock time `t`.
- **Assert:** exactly one file `.hist/img/logo.png/<ts>.conflict` is
  written, with headers `version: <sha(LB)>` and `writer: laptop`, a blank
  line, and the **full losing bytes** `LB` as body — otherwise the losing
  binary would be gone forever. The winning bytes are not recorded (binaries
  get no other history).

### a losing text version records nothing at the receiver

- **Arrange:** history for `f.md`: the local edit `A → B` was already flushed
  as `patch(A → B)`; a remote winner `C` then resolves the conflict via LWW.
- **Act:** the winner `"C"` is materialized on disk and, as always, not committed.
- **Assert:** no `conflict` file and no other new file is written for the
  text loser — its author already recorded it, and it surfaces as a
  dead-end branch in the graph on every device. Only binaries are rescued.

## Multi-writer (RV6)

### two writers recording the same version dedup in the reader

- **Arrange:** `.hist/f.md/` contains, arrived from two devices that
  independently made the identical edit: `snapshot(A)` from writer `laptop`,
  `snapshot(A)` from writer `phone` (same `version: <sha(A)>`, different
  filenames), and two `patch` files both declaring `prev: <sha(A)>`,
  `version: <sha(B)>`. Live file is `"B"`.
- **Act:** `graph("f.md")`.
- **Assert:** the graph has exactly nodes `{sha(A), sha(B)}`, one root
  `sha(A)` (snapshots dedup by `version`), and one edge `A → B` (edges dedup
  by `(prev, version)`); the primary line is `A → B`. Duplicate recordings are
  harmless by construction.

### an offline device's late files connect by hash

- **Arrange:** `.hist/plan.md/` holds `snapshot(A)` and `patch(A → D)`
  (the phone's edit, already synced). The laptop was offline and recorded
  `patch(A → B)` and `patch(B → C)` locally.
- **Act:** the laptop's two files arrive through sync (they appear in the
  folder); `graph("plan.md")` with live content `"D"` (the LWW winner).
- **Assert:** the graph now has root `A` and edges `{A→B, B→C, A→D}` — a
  fork at `A`; every pre-existing file is unchanged (no history file ever
  conflicts in sync); the primary line is `A → D` and `B → C` is a visible
  branch. The late pieces slotted in purely by hash linkage.

### clock skew reorders filenames but not the graph

- **Arrange:** `.hist/f.md/` contains `0000000001000.snapshot`
  (`version: sha(A)`), `0000000003000.patch` (`prev: sha(A)`,
  `version: sha(B)`), and — written by a device with a skewed clock —
  `0000000002000.patch` (`prev: sha(B)`, `version: sha(C)`), whose filename
  sorts **before** its parent edge's. Live file is `"C"`.
- **Act:** `graph("f.md")` and `materialize("f.md", sha(C))`.
- **Assert:** the primary line is `A → B → C`, following the hash headers, not
  the filename order; materialization yields exactly `"C"`. Timestamps are
  for humans and sorting only — identity and linkage are the hashes.

## Reader (RV5)

### the reader builds a deduped graph of nodes, edges, and roots

- **Arrange:** a hand-assembled `.hist/f.md/` containing: two `snapshot`
  files with `version: sha(A)`; `patch(A → B)` twice (identical `prev` /
  `version`, different filenames); `patch(B → C)`; and a `deleted` marker
  with `prev: <sha(C)>`.
- **Act:** `graph("f.md")` (live file absent).
- **Assert:** nodes are exactly `{sha(A), sha(B), sha(C)}`; roots exactly
  `{sha(A)}` (deduped by `version`); edges exactly `{A→B, B→C}` (deduped by
  `(prev, version)`); the deleted marker contributes no node or edge — it
  marks where the life ended.

### the primary line runs from a root to the live hash

- **Arrange:** `.hist/f.md/` with root `snapshot(A)`, edges
  `patch(A → B)`, `patch(B → C)`, and a fork `patch(A → X)`. Live file is
  `"C"`.
- **Act:** `graph("f.md")`.
- **Assert:** the primary line is the path `A → B → C` (root to the live file's
  current hash); `X` is unreachable from the primary line and reported as a
  branch.

### a conflict loser is a dead-end branch

- **Arrange:** `.hist/f.md/` with `snapshot(A)`, `patch(A → B)` (the local
  edit that lost LWW), and `patch(A → C)` (the winner, recorded at its
  source). Live file is `"C"`.
- **Act:** `graph("f.md")`.
- **Assert:** the primary line is `A → C`; node `B` is a branch — the losing
  version remains visible on every device without any conflict file having
  been written for it.

### a past life is a branch delimited by its deleted marker and date

- **Arrange:** `.hist/todo.md/` with, in name order: `snapshot(X)`,
  `patch(X → X2)`, a `deleted` marker at timestamp `T` with
  `prev: <sha(X2)>`, then `snapshot(Y)` (the new root). Live file is `"Y"`.
- **Act:** `graph("todo.md")`.
- **Assert:** the primary line is the new life rooted at `Y`; the old life
  `X → X2` is a branch that ends at the deleted marker and is shown with the
  marker's date `T` — the reader can tell when that life ended.

### a rollback strands a branch

- **Arrange:** `.hist/f.md/` with `snapshot(A)`, `patch(A → B)`,
  `patch(B → C)`; the owner then restored `A` (nothing recorded) and edited
  onward, adding `patch(A → E)`. Live file is `"E"`.
- **Act:** `graph("f.md")`.
- **Assert:** the primary line is `A → E`; the abandoned states `B → C` are a
  branch. No file in the folder points backward — "current" moved via the
  live file's pointer, not via an edge.

### materialization starts at the nearest snapshot ancestor

- **Arrange:** `.hist/f.md/` with `snapshot(A)`, `patch(A → B)`,
  `patch(B → C)`, a checkpoint `snapshot(C)`, and `patch(C → D)`. The body
  of `patch(A → B)` is corrupted.
- **Act:** `materialize("f.md", sha(D))` and `materialize("f.md", sha(B))`.
- **Assert:** `D` reconstructs correctly — the reader starts at its nearest
  snapshot ancestor `snapshot(C)` and applies one verified patch step, never
  touching the corrupted early patch. `B`, whose only route runs through the
  corrupted patch, is flagged **broken**.

### every reconstruction step is hash-verified; corruption flags broken

- **Arrange:** `.hist/f.md/` with `snapshot(A)` and `patch(A → B)` whose
  body was tampered with so that dmp still applies it without error but the
  result's sha256 no longer equals the declared `version` (fuzzy application
  produces garbage silently).
- **Act:** `materialize("f.md", sha(B))` and `materialize("f.md", sha(A))`.
- **Assert:** version `B` is flagged **broken** and its wrong bytes are never
  returned as content — sha256 is verified against the declared `version`
  after **every** patch step, and silent wrongness is forbidden. Version `A`
  (the intact snapshot) still materializes as `"A"`.

### a live hash absent from the graph reads as unsaved changes

- **Arrange:** `.hist/f.md/` with `snapshot(A)` and `patch(A → B)`; the
  live file contains `"Z"`, whose hash matches no node (an edit still inside
  the debounce window).
- **Act:** `graph("f.md")`.
- **Assert:** the graph's nodes are still exactly `{sha(A), sha(B)}`, and the
  live state is reported as **"unsaved changes after version `B`"** — not as
  a node, not as an error.

### rename links make old history reachable from the new name (S6)

- **Arrange:** after a detected rename `doc/a.md → doc/b.md`:
  `.hist/doc/a.md/` ends with a `deleted` marker carrying
  `renamed_to: doc/b.md`; `.hist/doc/b.md/` starts with a `snapshot`
  carrying `renamed_from: doc/a.md`.
- **Act:** `graph("doc/b.md")`.
- **Assert:** the graph exposes the `renamed_from` display link to
  `doc/a.md`, through which the versions recorded under the old name are
  reachable; the old folder's marker carries the forward `renamed_to` link.
  The links are display-level — no folder was merged or moved.

## Addressing, log, show (R1–R3)

### a version is addressable by hash, prefix, HEAD, HEAD~n and date

- **Arrange:** `.hist/f.md/` with `snapshot(A)` at time `1000`,
  `patch(A → B)` at `2000`, `patch(B → C)` at `3000`; live file `"C"`.
- **Act:** resolve `sha(B)`, the first eight characters of `sha(B)`, `HEAD`,
  `HEAD~1`, `HEAD~2`, and `@{<the instant 2500 ms>}` against `graph("f.md")`.
- **Assert:** they resolve to `sha(B)`, `sha(B)`, `sha(C)`, `sha(B)`,
  `sha(A)` and `sha(B)` respectively — the date form picks the primary-line
  version live at that instant.

### an ambiguous prefix is an error naming the candidates, never a guess

- **Arrange:** a graph holding two versions whose hashes share their first
  five characters.
- **Act:** resolve that five-character prefix; then a prefix of three
  characters; then `HEAD~9` on a three-version line; then a prefix matching
  nothing.
- **Assert:** each is an error: the first names **both** candidate hashes;
  the second is refused as too short; the third says the line has only
  three versions; the fourth says no version matches. None returns a hash.

### HEAD is an error when there is no live version

- **Arrange:** `.hist/f.md/` with `snapshot(A)` and `patch(A → B)`; the live
  file contains `"Z"`, unrecorded.
- **Act:** resolve `HEAD`; then resolve `HEAD` with the live file absent.
- **Assert:** both are errors — the first says the live file has unsaved
  changes after `sha(B)`, the second that there is no live version. `sha(B)`
  by prefix still resolves.

### the log lists the primary line newest first and marks the live entry

- **Arrange:** `.hist/f.md/` with `snapshot(A)` (writer `laptop`, time
  `1000`), `patch(A → B)` (`phone`, `2000`), `patch(B → C)` (`laptop`,
  `3000`); a fork `patch(A → X)` by a third device, `tablet`, at `2500`;
  live file `"C"`.
- **Act:** `log("f.md")`; then `log("f.md", all)`; then the latter filtered
  by writer `phone`, and by a count of one.
- **Assert:** the first lists exactly `C, B, A` in that order, each with its
  writer and time, `C` marked live, and no branch. The second appends one
  branch identified by leaf `sha(X)`, kind **divergent** (a writer the
  primary line does not have), writers `tablet`, containing `X`. The
  writer filter yields `B` alone; the count yields `C` alone.

### a file with no live version lists every line as a branch

- **Arrange:** `.hist/todo.md/` with `snapshot(X)`, `patch(X → X2)` and a
  `deleted` marker naming `X2`; no live file.
- **Act:** `log("todo.md")`.
- **Assert:** there is no primary line; the log lists the `X → X2` line as
  an **archived** branch ending at the marker's date, and states that the
  file has no live version.

### show reconstructs the addressed version or reports it broken

- **Arrange:** `.hist/f.md/` with `snapshot(A)` and `patch(A → B)` whose
  body was tampered so the result no longer hashes to `sha(B)`; live `"B"`.
- **Act:** `show("f.md", "HEAD~1")` and `show("f.md", "HEAD")`.
- **Assert:** the first yields exactly `"A"`; the second reports version
  `sha(B)` **broken** and yields no bytes.

## Diff and blame (R4, R5)

### a diff is a unified rendering over verified content, correct across a checkpoint

- **Arrange:** `.hist/f.md/` with `snapshot(A)`, a `patch(A → B)` whose body
  is corrupted, a checkpoint `snapshot(B)`, and `patch(B → C)`, where
  `A = "one\ntwo\n"`, `B = "one\ntwo\nthree\n"`, `C = "uno\ntwo\nthree\n"`;
  live `C`.
- **Act:** `diff("f.md", sha(B), sha(C))`; `diff("f.md", sha(A), sha(C))`;
  `diff("f.md", sha(C), sha(C))`.
- **Assert:** the first is a unified diff with `---`/`+++` headers naming
  the two versions, one hunk removing `one` and adding `uno`, with `two`
  and `three` as context — `B` reconstructed from the checkpoint, untouched
  by the corrupted patch. The second (`A` is itself a snapshot, so it
  reconstructs) shows `-one`, `+uno` and `+three`. The third is empty:
  identical content yields no hunks. A version that cannot be verified
  makes the diff broken rather than diffing garbage.

### blame attributes every line to the version and writer that introduced it

- **Arrange:** `f.md` recorded as `"one\ntwo\n"` (version `V1`, writer
  `laptop`), then `"one\ntwo\nthree\n"` (`V2`, `phone`), then
  `"uno\ntwo\nthree\n"` (`V3`, `laptop`); live `V3`.
- **Act:** `blame("f.md", sha(V3))`; then `blame("f.md", sha(V2))`.
- **Assert:** the first yields three lines: `uno` → `V3`/`laptop`, `two` →
  `V1`/`laptop`, `three` → `V2`/`phone`. The second yields `one` → `V1`,
  `two` → `V1`, `three` → `V2` — attribution is carried forward through
  every step of the chain, and a version's own new lines are its own.

## Noticing a divergence (R16, R18)

### listing headers reads a prefix of each file, never the whole

- **Arrange:** a real history folder holding a `snapshot` whose body is
  two megabytes, and a `patch`.
- **Act:** list the folder's headers.
- **Assert:** both headers parse with their `version`, `prev` and `writer`
  intact, and the bytes read from the large file are a small prefix — a few
  kilobytes at most — not its whole body.

### the divergence count is a count of files, derived from the graphs

- **Arrange:** `a.md` with two divergent branches, `b.md` with one archived
  branch, `c.md` with one merged branch, `d.md` with no branches, and
  `e.md` with one divergent branch; live content for each.
- **Act:** ask for the divergent paths across all five.
- **Assert:** exactly `a.md` and `e.md` — two files, not three branches;
  nothing was written anywhere to answer.

## Reconciliation inputs: fork point and diff3 (R9', R9'', R10)

### the fork point is the branch's nearest ancestor on the primary line

- **Arrange:** `plan.md` with `snapshot(A)`, `patch(A → B)`, `patch(B → C)`
  (live `C`), and another writer's `patch(B → D)`, `patch(D → D2)`; plus a
  separate life `snapshot(Q)` with no link to `A`.
- **Act:** ask for the fork point of the branch ending at `D2`, and of the
  branch ending at `Q`.
- **Assert:** the first is `sha(B)`; the second is **none** — unrelated
  roots have no common ancestor, so only side-choosing can be offered.

### diff3 takes each side's untouched-by-the-other change and flags the overlap

- **Arrange:** `A = "one\ntwo\nthree\n"`, live
  `L = "one\ntwo changed here\nthree\n"`, branch
  `B = "one\ntwo changed there\nthree\nfour\n"`; and a second triple where
  `L2 = "ONE\ntwo\nthree\n"` and `B2 = "one\ntwo\nthree\nfour\n"`.
- **Act:** `diff3(A, L, B)`; `diff3(A, L2, B2)`; `diff3(A, L, L)`.
- **Assert:** the first yields `four` appended cleanly and **one** conflict
  region around the second line, showing the live line, the ancestor's line
  and the branch's line between explicit markers; its conflict count is
  one. The second yields `"ONE\ntwo\nthree\nfour\n"` with no region — each
  side changed what the other left alone. The third yields `L` with no
  region: identical changes are one change.

## Merge: settled without a merge node (RV6)

### a merge writes an ordinary edge plus a marker, never a two-parent record

- **Arrange:** `plan.md` forks at `A`: `A → C` (live, primary) and `A → D`
  (another writer's line).
- **Act:** the owner reconciles them into `"E"`: `commit("plan.md", "E", t)`
  with `E` now live, then `merge("plan.md", sha(D), sha(E), t)`.
- **Assert:** exactly two files are written — a `patch` with
  `prev: <sha(C)>`, `version: <sha(E)>` (**one** parent, like any edit) and a
  `merged` file with `merged: <sha(D)>`, `into: <sha(E)>`, `writer`. No
  record anywhere declares two parents. `materialize("plan.md", sha(E))` is
  still a single chain from the nearest snapshot, hash-verified at each step.

### a merged branch stays readable but stops being open

- **Arrange:** the state after the case above.
- **Act:** `graph("plan.md")` with `E` live.
- **Assert:** `D`'s branch is still present with every node and edge intact
  and `materialize("plan.md", sha(D))` still reconstructs it — nothing was
  rewritten or removed. Its kind is **merged**, not divergent, so a surface
  lists it and stops asking for it.

### merging is idempotent whoever recorded it

- **Arrange:** a divergent branch ending at `D`, already merged into `E` by
  the laptop.
- **Act:** the phone, which reconciled concurrently, contributes its own
  `merged` marker naming `merged: <sha(D)>` into its own version `E2`; then
  `graph("plan.md")`.
- **Assert:** the branch is reported **merged once**, not twice, because any
  marker naming its leaf settles it. Both markers survive as files. Recording
  a merge for an already merged branch adds a file at most and never changes
  the branch's kind back — a surface can never loop on it.

### only divergent branches are offered for merging

- **Arrange:** `f.md` with three branches: another writer's open line ending
  at `D`; a previous life ending in a `deleted` marker; a line stranded by a
  rollback.
- **Act:** `graph("f.md")`.
- **Assert:** exactly one branch is **divergent** — `D`. The previous life
  and the rollback-stranded line are **archived**: the owner's own discarded
  states, with nothing to reconcile. A surface asking "what needs attention"
  gets one answer, not three.

### an anchor snapshot does not make another device's line the owner's own

- **Arrange:** `plan.md = A` predates history on every device. `mac` edits
  `A → C`, anchoring `snapshot(A)` under its own name first; `desk` edits
  `A → D`, anchoring `A` too; both files arrive everywhere, and `D` won LWW
  and is live.
- **Act:** `graph("plan.md", sha(D))`; then, on `desk`, restore `A` and
  edit `A → E` with `E` live, and read the graph again.
- **Assert:** node `A` carries both writers (the two anchors dedup into one
  node), yet `C`'s branch is **divergent**, not archived — the writers of a
  line are the writers of its edits, and `mac` edited nothing on the primary
  line. After the rollback, `D`'s line is **archived** (desk's own discarded
  state: its only edit is by desk, which also wrote the primary line's) and
  `C`'s stays divergent.

### the primary line follows the live content, never the clock

- **Arrange:** `plan.md` forks at `A` into `A → B` (recorded by a device
  whose clock is **days ahead**, so its filenames sort last) and `A → C`.
  The live content is `"C"`.
- **Act:** `graph("plan.md")`.
- **Assert:** the primary line is `A → C`. The skewed device's later
  filenames do **not** take the primary line, and a file arriving later still
  does not move it — the live hash decides, so the file on disk and its
  history always name the same lineage.

## Diff-match-patch recipe and interop (C5, RV5)

### the patch body follows the pinned dmp recipe

- **Arrange:** a checked-in fixture: `prev` text, `next` text, and the
  expected patch text produced by `diff_main(prev, next)` →
  `diff_cleanupEfficiency` → `patch_make`, all with default settings,
  serialized with `patch_toText`. History with `prev` recorded for
  `f.md`.
- **Act:** flush the edit `prev → next`; read the patch file's body.
- **Assert:** the body equals the fixture patch text byte-for-byte — the
  interoperable dmp text format, produced by exactly the pinned recipe —
  and applying it to `prev` yields `next`.

### cross-port fixtures pin Dart↔JS interop

- **Arrange:** checked-in cross-port fixtures, each holding: a base text, a
  patch text emitted by the **other** port of diff-match-patch (the JS port
  for the Dart implementation and vice versa), the expected result text, and
  the result's sha256.
- **Act:** apply each fixture's patch to its base text with this
  implementation's reader; also produce this implementation's patch for the
  same edit and compare it with what the other port consumed in its own
  fixture run.
- **Assert:** every fixture patch applies cleanly and the result's sha256
  equals the declared hash — a patch produced by one port applies in the
  other with matching hashes, so history written by the Dart writer is
  readable by a JS reader and vice versa.
