---
name: vault_hist_surface
description: A complete graphical history surface over the local history bridge: browse, record, diff, blame, restore, reconcile and install as a standalone desktop Obsidian plugin.
status: active
---

# Vault history surface

## Purpose

Use per-file history directly in the editor, over the same verified mechanism
as `hist`, independently of replication. Implements obsidian-history R1–R7.

## Inputs

The open filesystem vault, its active note and file events; the owner's
selected revision/branch, filters and actions; settings for opt-in recording
of saves, its debounce and device writer; the release's verified engine for this OS/CPU.

## Outputs

A dockable panel, commands and file-context actions; local settings and draft
state; ordinary history files and deliberate live-file mutations; a BRAT release
and an optional offline ZIP/install command targeting an explicitly named vault.

## Behavior

- **Panel (R1):** open current-note history from ribbon, command or file menu;
  offer a whole-vault timeline and retain the selected note/revision when
  refreshing. Deleted and renamed paths can be opened from the timeline/status.
  Show date, writer, full hash on demand, live/branch/broken state and rename
  links. Filter by path, author and since date; paginate or bound entries.
  Say that cross-file ordering uses device clocks and history is per file.
- **Preview (R2):** content, unified/side-by-side diff and blame views display
  text safely, never execute note HTML. Choose either diff revision or current
  working text. Broken/unknown revisions display an error, not stale content.
- **Record (R3):** commands record current note or vault. Opt-in recording of
  saves coalesces edits per path, preserves rename links and deletions, skips
  initial vault discovery, and cancels timers on unload. Serial requests and
  coalesced refreshes keep typing responsive. New empty history offers recording.
- **Restore (R4):** show the selected content and confirm the target revision
  and replacement. Save current editor text first; if an editor changes while
  the request is in flight, do not replace that newer buffer. Recheck the
  previewed live hash before applying. Unrecorded current text is preserved;
  refresh the file/editor through Obsidian's normal vault update path.
- **Reconcile (R5):** divergent branches have keep-live, take-branch and merge
  actions. Ask confirmation for side choices. A three-way editor displays base,
  live, branch and an editable result; save/resume draft, apply resolved text,
  or discard. Any remaining marker or changed live file blocks application.
  Draft edits are kept when the dialog closes and can be resumed after reload.
  Other branch kinds are labelled and never offered as merge candidates.
- **Status (R6):** show a divergent-file count and list, plus unfinished drafts.
  Opening a path takes the owner to its actionable history. File and history
  changes refresh the panel; failures display a useful message with retry.
- **Lifecycle (R6):** view, commands, timers, subprocesses and events are
  cleaned up on unload. Closing a panel invalidates pending UI results.
- **Delivery (R7):** desktop-only standalone plugin, no sync plugin required.
  BRAT installs the release's manifest, script and styles. On first use, fetch
  the matching engine from that exact public release, verify the OS/CPU-specific
  SHA256 embedded in the plugin, and cache it outside the vault. Reuse a verified
  cache offline; never select a moving latest release or ask the owner for a hash.
  Failed, corrupt or unsupported downloads display an actionable error and never
  execute. Concurrent requests share installation; unloading cancels installation.
  A platform ZIP can instead include the verified engine for offline installation.
  Neither delivery requires Dart/Node installation on the owner's machine.
  Packaging builds host architecture; release automation builds supported
  macOS/Linux/Windows architectures. An install command takes an explicit vault
  path and never chooses a personal vault itself. A separate demo-vault command
  produces multi-writer versions and a real unresolved draft for verification.

## Non-goals

Mobile, sync configuration, publishing to Obsidian's community directory,
rewriting history, and compatibility with unreleased versions.

## Examples

The owner restores yesterday's revision; today's unrecorded text remains a
recoverable version. A deleted note appears in the vault timeline and restores.
An offline writer's line offers merge; an archived rollback line does not.
