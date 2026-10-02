---
name: vault_folder
description: The single owner of a vault folder — watching, coalescing raw editor events into settled states, hashing, and performing every write into the folder — publishing one attributed stream of settled states (local edit vs materialization by a named module) that every module consumes, so modules compose without knowing about each other.
status: draft
---

# Vault folder

## Purpose

Two capabilities want the same folder: history records what changed, and
replication uploads it and materializes what arrives. Both need to know when a
file has settled, and both must be able to tell *their own* writes from
somebody's edit. That knowledge cannot be duplicated — a second watcher over
one directory reads the first's writes as edits — so it belongs to **one owner**
(`daemon-modules` R4).

This module is that owner. It watches the folder, folds raw editor events into
**settled states**, hashes them, performs every write, and publishes one stream
of states each **attributed**: a *local* edit, or a *materialization* a named
module asked for.

That single stream is what lets modules be independent. A module subscribes,
acts on `local` or ignores `materialized` — or the reverse — without ever
naming another module (`daemon-modules` R2, R5). Adding a third module later
is one more subscriber.

## Inputs

- **The vault root**, and the **exclusions** that apply to it — a configured
  list, plus the vault's own ignore files, which the service reads from the
  tree at any depth (see *Ignore files nest*). Both are properties of the
  folder, not of any module (R7).
- **Filesystem events**, from an injected watcher — production watches the real
  tree; tests feed events directly.
- **Write requests** from modules: `materialize(path, bytes, mtime, by)` and
  `remove(path, by)`, where `by` names the requesting module.
- **A clock and a coalescing interval** — how long a path must be quiet before
  its state is settled.
- **An inline limit** — the size above which a state reports its hash and
  leaves the bytes on disk, so nothing is carried through memory whole.
- **Its own persisted record** of what it last saw per path (R6).

## Outputs

- **A stream of settled states**: `{path, content | absent, hash, origin,
  previous hash}`, where `origin` is `local` or `materialized(by: <module>)`.
  Content above the inline limit is not carried; the state still carries its
  hash. The **previous hash** is what the service had for the path before
  this state — nothing for a new file — so an absent state names the hash
  that was there and a present one says whether it is new or changed: a
  consumer can pair a rename without keeping a record of its own (R6).
- **The folder's current truth on demand**: a full pass reporting everything
  that changed, a scan of every path's hash, and the state of one path — what
  a module needs at startup, after a fault, or when it must know whether a
  path changed under it, without walking the tree itself.
- **The writes themselves**, performed atomically, with deletions going to the
  system trash rather than being destroyed.

## Behavior

### One owner, one watcher (R4)

- Exactly one watcher and one periodic rescan cover the folder however many
  modules are enabled. Modules never open a watcher and never write into the
  vault; a module that did would see the other's writes as edits and the two
  would mint work forever — the same reason two vaults may not share a folder
  (`vault_daemon`).
- The service is the only writer. A module hands it bytes and gets back the
  settled state, attributed to itself.

### Raw events are folded into settled states (D7)

- Editors save by writing a temporary file and renaming it, or by deleting and
  recreating. Those are **not** states: the service coalesces events per path
  and emits only the final state once the path has been quiet for the
  configured interval. A delete-then-write inside the window is one edit, not a
  deletion and a new life.
- Timing lives **here**, once, rather than in each module: this is precisely
  the knowledge that must not be duplicated, and a module that had to
  re-implement it would get it subtly differently.
- Every emitted state carries the **sha256 of its content**, computed once and
  shared by every subscriber — modules never re-hash what the service has
  already hashed.

### Attribution is the whole interface (R5)

- A state whose content the service itself just wrote is emitted as
  `materialized(by: X)`. Everything else is `local`.
- Attribution is **by content**, not by timing: a write is matched to its
  request by path and hash, so a slow watcher, a coalesced burst or a restart
  cannot turn a materialization into a phantom edit.
- The distinction is what a module acts on, and it is expressed without naming
  any module: history commits `local` and adopts `materialized`; replication
  pushes `local` and ignores `materialized`. Neither mentions the other.
- A module may of course see its **own** materializations; it is told which
  module asked, and ignoring its own is its business.

### Ordering is guaranteed here, because here is the only place it can be

- A local edit that races an incoming write is emitted **before** the write is
  applied, so a module recording it records from the state it was really made
  on. Only the owner of the folder can promise this, which is why the write
  path and the watch path are one service.
- The service never emits a state it has not finished writing: a subscriber
  seeing `materialized` can rely on the bytes being on disk.

### Its own record of the folder (R6)

- The service persists, per path, what it last saw — hash, size, mtime — and
  detects changes against that. It does **not** consult any module's state, so
  change detection works identically with one module enabled, both, or none.
- The fast path compares size and mtime; content is hashed only when they
  differ. A periodic full rescan and a startup scan catch whatever the watcher
  missed, and are the reason a module can be enabled later and still see a
  correct picture without a special "catch-up" mode.

### A full pass is a batch, and one bad file is not a bad pass

- The periodic and startup passes report **everything that changed at once**,
  not a trickle. A rename is a pair of states — one path gone, another
  appeared with the same content — and a consumer shown them separately could
  not tell a move from a deletion and an unrelated creation.
- A failed **listing** is reported as a failure of the whole pass and nothing
  is emitted: a partial listing would read as mass deletion. The next pass
  tries again.
- A file that cannot be read (permissions, vanishing mid-pass, a bad disk) is
  **reported alongside the states, not thrown**: every other path is still
  reported, the unreadable one stays out of the record, and the next pass
  retries it. One bad file must never cost a pass.

### Large content stays on disk

- Content up to the inline limit rides inside the state. Above it the state
  carries its **hash** and the bytes stay where they are, their digest
  computed from a stream — neither the service nor any subscriber holds one
  large file whole. A module that needs those bytes asks the service for them.
- The limit is the folder's business, not a module's: it is about how much of
  the folder may be in memory at once, not about what anybody does with the
  content.

### The record can be corrected (R6)

- A subscriber that could not apply a state asks the service to **report it
  again**: forgetting a path makes the next pass see it as new, and restoring
  what preceded a deletion makes the next pass see the deletion again. The
  service queues nothing durably (see non-goals), so this is how a consumer
  that failed on a state recovers instead of losing it with the event that
  carried it.

### Exclusions belong to the folder (R7)

- An excluded path is invisible: not watched, not scanned, not emitted, and not
  writable through the service. Modules receive no excluded path and cannot
  reach one, so exclusion needs no per-module implementation.
- Exclusions are configured once for the vault, not per module.
- They can change while the service runs (the vault's rule file was edited). A
  path that **becomes** excluded leaves the record: it is invisible from then
  on, and un-excluding it re-admits it as new rather than as unchanged. The
  service never mistakes exclusion for deletion — it says nothing about an
  excluded path at all.
- **Some exclusions are built in**, and no configuration can remove them.
  `.hist-state/` — this machine's working state for the folder, kept beside
  `.hist/` (an unfinished history merge lives there) — is never watched,
  scanned, emitted, or writable through the service, and therefore never
  replicated and never history-tracked. It is per-machine and disposable,
  which is the opposite of what a synced file is; the exclusion is built in
  exactly as the history mirror already excludes itself from tracking, so no
  module needs to know the folder exists, and a draft written there can never
  reach another device.

### Ignore files nest, like `.gitignore`

- The vault's rule files — `.syncignore` for what the folder excludes, and
  `.histignore`, which a module consumes through the **same engine** — may
  sit in **any** directory, not only the vault root. An ignore file applies
  to its own directory and everything under it, and its patterns are
  **relative to the directory it sits in**: a pattern with `/` anchors to
  *that* directory, not to the vault; a pattern without `/` matches a
  basename anywhere beneath it. Rules end up next to what they describe, deep
  folders need no long root-anchored paths, and moving a folder moves its
  rules with it.
- **Nesting is additive, and the rule is one sentence:** a path is excluded if
  **any** applicable ignore file excludes it. No precedence, no ordering. This
  holds precisely because negation is absent — `!` stays unsupported and is
  skipped as a comment, so no deeper file can re-include what an ancestor
  excluded.
- **The rules travel.** Ignore files are ordinary vault files, so a nested one
  syncs like any other and every device honours the same set — the property
  the root file already had, now true per folder. An ignore file that is
  edited, arrives, or appears in a new directory applies on the service's
  next pass, exactly as the root file does.

### Writes are atomic, and deletions are recoverable

- A materialization is written to a temporary file in the same directory and
  renamed into place, so a reader never sees a half-written file, and the
  logical modification time is applied to the result.
- A removal moves the file to the **system trash**, never destroys it — a
  wrongly propagated deletion must always be recoverable by hand.
- The service creates parent directories as needed. It never removes a
  directory: an empty folder left behind is harmless, while removing one that
  another device is about to fill is not.

## Non-goals

- **Not replication, not history, not encryption.** The service has no idea
  what its subscribers do; it moves bytes and reports states.
- **Not a conflict resolver.** Two states for one path are two events; what
  that means is a module's judgement.
- **Not a policy on what is worth watching** beyond exclusions — a module that
  cares about only some paths filters for itself.
- **Not a general filesystem API.** It exposes the vault's own tree and
  nothing outside it; a path escaping the root is refused, not clamped.
- **Not durable queueing.** A subscriber that is down misses events and
  recovers through the scan, which is why the scan exists.

## Examples

### An autosave burst is one state (D7)

An editor writes `notes/plan.md` three times in two seconds, the middle write
being a delete-then-create. The service emits **one** `local` state — the final
content — after the path goes quiet. Every module sees the same single state
and the same hash.

### A materialization is not an edit (R5)

Replication asks the service to write `notes/plan.md` with content that arrived
from another device. The service writes it atomically and emits
`materialized(by: sync)`. History adopts it and records nothing — the version
was recorded by whoever authored it. History never learns that "sync" exists;
it only knows the state was not local.

### History alone over a plain folder (R1)

Only history is enabled. The service watches, coalesces and emits `local`
states; nothing is ever materialized, no server is contacted, and no
credentials exist. The stream and the scan behave exactly as with both modules
enabled.

### A racing edit keeps its true base

A file is edited locally while a remote winner for the same path is being
applied. The service emits the local state first, then performs the write and
emits the materialization. A module recording versions therefore records the
edit from the state it was actually made on, and does not attribute the
arriving content to this device.
