---
tests: vault_folder
---

# Vault folder — test-spec

Agnostic cases for `vault_folder`, in strict Arrange / Act / Assert form. The
watcher and the clock are injected, so raw events and quiet periods are driven
directly rather than waited for. Terms:

- **service** — the module under test, over a temp folder, with an injected
  watcher, an injected clock, a coalescing interval, and an exclusion list.
- **event(path)** — a raw filesystem event handed to the watcher, as an editor
  would produce.
- **settle** — advance the clock past the coalescing interval and let the
  service emit.
- **states** — everything the service has emitted, in order, each carrying
  `path`, content-or-absent, `hash` and `origin`.

## One owner, one watcher (R4)

### a module never needs its own watcher or its own hashing

- **Arrange:** a service with two subscribers.
- **Act:** change a file; `settle`.
- **Assert:** **one** watcher exists over the folder, both subscribers receive
  the same state object, and its `hash` is the sha256 of the content — computed
  once, not per subscriber.

### a path outside the vault root is refused, not clamped

- **Arrange:** a service over a vault root.
- **Act:** ask it to materialize a path that escapes the root (`../elsewhere`).
- **Assert:** the request is refused with a clear error and **nothing is
  written** anywhere — the escape is not silently rewritten into a path inside
  the root.

## Raw events become settled states (D7)

### an autosave burst is one state

- **Arrange:** a service with a coalescing interval.
- **Act:** three events for one path inside the interval — the last content
  differing from the first — then `settle`.
- **Assert:** exactly **one** state is emitted, carrying the final content.
  Intermediate contents never appear.

### delete-then-create inside the window is one edit, not a life ending

- **Arrange:** a file with known content.
- **Act:** an event where the file is absent, then one where it exists with new
  content, both inside the interval; `settle`.
- **Assert:** one state is emitted, with the new content and **not** absent.
  No "deleted" state is ever emitted for that burst.

### a path that stays quiet emits nothing

- **Arrange:** a file whose content is re-saved byte-identically.
- **Act:** an event for it; `settle`.
- **Assert:** no state is emitted — the hash matches what the service last saw,
  so there is nothing to report.

## Attribution (R5)

### a materialization is attributed to the module that asked

- **Arrange:** a service and a subscriber.
- **Act:** a module named `sync` materializes a path; `settle`.
- **Assert:** the emitted state's origin is `materialized` naming `sync`, its
  content is what was written, and the bytes are on disk **before** the state
  is emitted.

### an edit by anything else is local

- **Arrange:** the same service.
- **Act:** an editor changes a file; `settle`.
- **Assert:** the state's origin is `local`, and it names no module.

### attribution survives a coalesced burst and a slow watcher

- **Arrange:** a module materializes a path; the watcher delivers its event
  late, after other events for the same path.
- **Act:** `settle`.
- **Assert:** the state whose content matches what was written is still
  attributed to the module that wrote it — matching is **by path and content
  hash**, so timing never turns a materialization into a phantom local edit.

### a module can act on the distinction without naming another module

- **Arrange:** a subscriber that records `local` states and ignores
  `materialized` ones — with **no** other module present.
- **Act:** materialize one path, edit another; `settle`.
- **Assert:** it records only the edited path. The subscriber's code references
  no module name, and the case passes with the other module absent entirely
  (R2).

## Ordering

### a local edit racing a write is emitted before the write

- **Arrange:** a file with a pending local edit not yet settled.
- **Act:** a module materializes the same path.
- **Assert:** the `local` state is emitted **first**, then the
  `materialized` one — so a subscriber recording versions records the edit from
  the state it was really made on.

## The service's own record (R6)

### change detection works with no module enabled, and across restarts

- **Arrange:** a service with **no** subscribers; a file is edited and settles.
- **Act:** stop the service, start a new one over the same folder and state,
  attach a subscriber, and run a scan.
- **Assert:** the already-seen edit is **not** re-emitted as new, while a file
  changed while the service was down **is**. Nothing about this depends on any
  module's state.

### enabling a module later does not need a special catch-up

- **Arrange:** a service running with one subscriber; edits happen.
- **Act:** attach a second subscriber and ask the service for the folder's
  current truth.
- **Assert:** the new subscriber can obtain every path's current state and hash
  from the scan, without the first subscriber being disturbed and without
  re-emitting history to it.

## A full pass (R6)

### an unchanged file is not read or hashed

- **Arrange:** a service that has already seen a set of files, and a counter of
  how often content is hashed.
- **Act:** run a full pass with nothing modified.
- **Assert:** no state is emitted and **nothing was hashed** — size and mtime
  alone settled it. Touching one file's modification time without changing its
  bytes costs exactly **one** hash, emits nothing, and does not cost a second
  hash on the pass after that.

### one unreadable file costs its own state, not the pass

- **Arrange:** a folder with a healthy file and one that cannot be read.
- **Act:** run a full pass.
- **Assert:** the healthy file's state is reported; the unreadable one is
  reported as a **failure**, not thrown. The pass completes. The failing path
  is absent from the record, so a later pass — once the file is readable —
  reports it as an ordinary change.

### everything that changed arrives in one batch

- **Arrange:** a settled folder.
- **Act:** delete one file and create another with the same content, then run
  one full pass.
- **Assert:** both states come back from that single pass — the disappearance
  and the appearance together — so a consumer can recognise the pair. Neither
  is withheld for a later pass.

## Large content stays on disk

### a file above the inline limit reports its hash, not its bytes

- **Arrange:** a service with an inline limit, and a file larger than it.
- **Act:** settle the file.
- **Assert:** the state is **not absent**, carries the sha256 of the whole
  file, and carries **no content**. The service can still hand the bytes to a
  module that asks for them, and the whole-content hashing seam was never fed
  the large file.

## The record can be corrected (R6)

### a state a consumer could not apply is reported again

- **Arrange:** a file the service has settled and reported.
- **Act:** the consumer fails to apply it and asks the service to forget the
  path; run a full pass.
- **Assert:** the state is reported again, as new. The same holds for a
  deletion: after restoring what preceded it, the next pass reports the path
  gone again. Nothing is lost with the event that carried it.

## Exclusions belong to the folder (R7)

### an excluded path is invisible and unwritable

- **Arrange:** a service whose exclusions cover a path.
- **Act:** change that path; then ask a module to materialize it.
- **Assert:** no state is emitted for it, a scan never reports it, and the
  materialize request is refused — a module cannot reach an excluded path, so
  it needs no exclusion logic of its own.

### a path that becomes excluded is not a deletion, and un-excluding re-admits it

- **Arrange:** a service that has settled a file, with the vault's rules
  changed to exclude it.
- **Act:** run a full pass; then drop the rule and run another.
- **Assert:** the first pass reports **nothing** for that path — it is
  excluded, not deleted, and no state ever says otherwise. The second reports
  it as **new**, whatever it now contains, so nothing that happened while it
  was excluded is missed.

### the working-state folder is excluded built-in

- **Arrange:** a service with **no** configured exclusions.
- **Act:** write `.hist-state/merge/plan.md.draft`; send its event; run a full
  pass; then ask a module to materialize a path under `.hist-state/`.
- **Assert:** no state is ever emitted for the path, a scan never reports it,
  and the materialize request is refused — nothing under `.hist-state/` can
  reach a module or be written through the service, whatever the configured
  rules say.

## Ignore files nest

### a nested ignore file anchors to its own directory

- **Arrange:** a vault with `notes/.syncignore` containing `/drafts/` and
  `*.tmp`, plus the files `notes/drafts/a.md`, `drafts/b.md`,
  `notes/deep/x.tmp`, `x.tmp` and `notes/keep.md`.
- **Act:** run a full pass.
- **Assert:** `notes/drafts/a.md` and `notes/deep/x.tmp` are excluded;
  `drafts/b.md` and `x.tmp` are **not** — the anchored pattern binds to
  `notes/`, and the basename pattern reaches only beneath it. `notes/keep.md`
  and the ignore file itself are reported.

### nesting is additive, and negation stays inert

- **Arrange:** a root `.syncignore` containing `secret` (a basename, so it
  reaches any depth), and `sub/.syncignore` containing `!secret` and
  `local.md`; files `sub/secret/x.md`, `secret/y.md`, `sub/local.md`,
  `other/local.md`.
- **Act:** run a full pass.
- **Assert:** `sub/secret/x.md`, `secret/y.md` and `sub/local.md` are excluded;
  `other/local.md` is reported. The nested negation changes nothing — a path
  is excluded if any applicable file excludes it.

### a nested ignore file that changes applies on the next pass

- **Arrange:** a service that has settled `sub/scratch.md`.
- **Act:** create `sub/.syncignore` containing `scratch.md` and run a full
  pass; then delete the ignore file and run another.
- **Assert:** the first pass reports nothing for `sub/scratch.md` (excluded,
  not deleted); the second reports it as new — the same behaviour the root
  file has.

## Writes (R4)

### a materialization is atomic and carries its modification time

- **Arrange:** a service.
- **Act:** materialize a path with a given logical modification time.
- **Assert:** the file exists with exactly those bytes and that mtime, and no
  temporary file is left beside it. A reader never observes a partial file.

### a removal goes to the trash, never to destruction

- **Arrange:** a file with content.
- **Act:** a module removes it through the service.
- **Assert:** the file is gone from the vault and **recoverable** from the
  system trash; the emitted state is absent and attributed to the module.

### parent directories are created, and empty ones are left alone

- **Arrange:** a service.
- **Act:** materialize `a/b/c.md`, then remove it.
- **Assert:** the write created `a/b/`; after the removal those directories
  **still exist** — removing a directory another device may be about to fill is
  not the service's call.
