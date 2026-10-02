---
tests: vault_hist_bridge
spec-digest: fd70298fd92088d36cc223293ed3eb0dfcfb58d4be8fcfebd43409dc1c8927dd
---

# History bridge tests

### Verified read surface
- Arrange: Record two versions, including Unicode and a missing final newline.
- Act: Log, show, diff and blame through JSON requests.
- Assert: Graph order, authors, exact content, full hashes, changed lines and
  attribution match the library; the file and history remain unchanged.

### Folder discovery and filters
- Arrange: Two tracked files, a deleted path and a nested ignored file.
- Act: Record the folder, delete a recorded file, read timeline and status,
  then filter by path, writer, timestamp and limit.
- Assert: Ignored file has no history, deleted history remains discoverable,
  timeline says approximate, and every filter is honored.

### Broken version and unsafe paths
- Arrange: Corrupt a recorded snapshot; create an outside file and symlink.
- Act: Show corrupt content, request traversal and a path through the symlink.
- Assert: Structured failures, no invalid content, and no outside mutation.

### Restore preserves current text and guards races
- Arrange: Record A and B, then leave C unrecorded; preview C's hash.
- Act: Restore A with that hash, then try a restore with the stale hash.
- Assert: A is live, C reconstructs exactly, and stale restore writes nothing.

### Rename and deletion
- Arrange: A recorded path has an unrecorded edit and is renamed on disk.
- Act: Notify the rename, then delete and record the new path.
- Assert: Pending text is recorded before rename, old/new links exist, history
  directories remain, and deletion markers describe the last live content.

### Deliberate reconciliation
- Arrange: Two writers fork from one root with overlapping edits.
- Act: Start merge, read and save draft, try unresolved continue, save resolved
  text and continue; repeat with side choices and abort on fresh branches.
- Assert: Base/live/branch are verified; unresolved/changing-live application
  is refused; resolved text is recorded and the branch settled; side choices
  have ordinary marker semantics, and abort changes only draft state.
