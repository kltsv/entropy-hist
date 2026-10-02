---
tests: vault_hist_surface
spec-digest: 13ae5414db2c7c8fd17c989d25fd37620890350a909c28f5f5edca84e9c84c1a
---

# History surface tests

### Requests and process lifecycle
- Arrange: A vault path and note containing spaces, Unicode and shell syntax.
- Act: Request history; issue concurrent mutations; time out or unload a request.
- Assert: Arguments are literal, requests serialize, engine errors remain useful,
  and timeout/unload kills the owned process without applying a stale result.

### Bundled engine
- Arrange: A matching platform executable and checksum metadata, then corrupt it.
- Act: Resolve the engine and request history.
- Assert: Correct platform is selected and verified; corrupt/missing/unsupported
  engine reports actionable failure before execution, without network access.

### BRAT engine delivery
- Arrange: Only manifest/script/styles installed; release metadata pins one
  platform binary and its digest; a fake download server and empty local cache.
- Act: Make concurrent history requests, reopen offline, corrupt the cache,
  fail a download or unload during installation.
- Assert: One exact-release download, a verified atomic cache outside the vault,
  offline reuse, verified replacement of a corrupt cache, visible failures,
  no execution of invalid bytes and no process launched after cancellation.

### Read and restore workflow
- Arrange: Recorded note A/B and current unrecorded C.
- Act: Open panel, select A, inspect content/diff/blame, confirm restore.
- Assert: Correct selected version, inert content, guarded restore with C kept,
  refreshed editor and history; a changed editor invalidates application.

### Draft workflow
- Arrange: Divergent writers and persisted unresolved draft.
- Act: Open status, resume draft, edit/close/reopen, unload/reload with a typed
  draft, resolve/apply or abort.
- Assert: Edits survive reopen and unload; stale/unresolved apply is refused; only divergent
  lines offer reconciliation; settled and archived lines remain readable.

### Saved edit recording
- Arrange: Automatic recording on; several saves, rename and delete; load events.
- Act: Deliver events, advance debounce, then unload with a pending timer.
- Assert: One coalesced record, ordered rename/deletion, no initial-load records,
  ignored/binary paths skipped, no timer/process leaks after unload.

### Installable artifact
- Arrange: Built host-platform ZIP and a newly created demo vault.
- Act: Extract/install into its plugin folder, run the bundled engine and UI.
- Assert: Manifest/script/styles/checksummed binary exist; history previews,
  diff/blame, restore and persisted merge work without daemon or external runtime.
