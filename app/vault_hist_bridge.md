---
name: vault_hist_bridge
description: Structured local process interface over vault_hist for graphical clients; verified reads and guarded history operations, without a daemon.
status: active
---

# Vault history bridge

## Purpose

Give graphical clients structured access to the existing history library and
CLI. Reuse their graph, reconstruction, diff, blame, commits and reconciliation;
do not parse human CLI output to reconstruct a graph.

## Inputs

One JSON request on stdin with an operation, absolute `folder`, optional absolute local
`stateDir`, writer and extensions, vault-relative paths and revision addresses.
The bundled process handles one request, writes one JSON response and exits.

## Outputs

Exactly one JSON envelope: `{ok:true,data:…}` or
`{ok:false,error:{code,message}}`. Exit is zero for success and nonzero for
failure. Failure text is useful to the owner, and never contains partial
reconstruction presented as valid. No storage format changes.

## Behavior

- **Location (R1–R7):** use the given folder directly. Refuse a path outside
  it, an excluded path, an unsafe path through symlinks, or invalid requests.
  All returned paths are vault-relative. The default state folder is
  `.hist-state/obsidian/`, excluded by the existing folder service.
- **Log (R1):** return primary-line versions in graph order, all branch
  versions with leaf, kind, writers and fork point, parent hashes, broken
  flags, live hash, unrecorded changes and rename links. Without a path,
  return the vault timeline, explicitly marked approximate between files.
  Optional path substring, exact author, since timestamp and count filter it.
- **Show (R2):** resolve the revision, reconstruct with per-step verification,
  return full hash and exact UTF-8 content. Unknown/ambiguous/broken revisions
  fail. Never substitute current content for a broken version.
- **Diff (R2):** reconstruct both named revisions; `WORKING` means the actual
  current file. Return both texts, full addresses, line edits and unified diff.
- **Blame (R2):** return line number, exact text, introducing hash, writers and
  recording time, through the library's existing attribution.
- **Status (R6):** return divergent paths and branch leaves, unrecorded paths,
  tracked paths and unfinished drafts. A deleted file's history is discoverable.
- **Commit (R3):** named paths or the whole folder use the existing CLI commit,
  honoring extensions, built-ins and nested ignores. An unchanged state writes
  nothing. Record deletion only when history already exists.
- **Rename (R3):** automatic recording can link a recorded old path to its new
  path using the library's ordinary rename markers; no mirror folder moves.
  A pending edit at the old path is recorded before the rename markers, and an
  excluded destination records only the old deletion. Unrecorded sources start
  the destination's history normally.
- **Mutation guard (R4,R5):** restore and merge operations require
  `expectedLive` (the hash the client previewed, or null for an absent file).
  A mismatch fails with `live_changed` before changing history, drafts or live
  content. Restore verifies its target before recording any unrecorded current
  text, then restores through the ordinary CLI path. Current text is preserved
  before side-taking or merge preparation too. The guard is checked again
  after preservation and before applying content.
- **Merge (R5):** `merge-start` and `merge-take` use existing CLI semantics.
  Start returns persistent draft metadata/text plus verified base, live and
  branch content. `draft` reads it, `draft-save` preserves edits locally,
  `merge-continue` takes resolved draft text and invokes the existing guarded
  continue, and `merge-abort` discards only the draft. Conflict markers or a
  changed live version block continue. No common ancestor offers side choices.
- **Serialization (R3–R5):** clients serialize requests for one vault. The
  bridge writes no long-running service and requires no registration/secrets.

## Non-goals

Replication, editor UI, a second history implementation, a network protocol,
and changing the existing human command line.

## Examples

`log` on `notes/plan.md` reports its primary versions and divergent branches.
`restore` with a stale `expectedLive` reports `live_changed` and writes nothing.
`merge-continue` containing `<<<<<<<` leaves the current file and marker intact.
