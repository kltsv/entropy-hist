# entropy_hist

Per-file history for notes, **standing alone**. One package holding the
`vault_hist` library, the exclusion engine that reads ignore files, and the
`hist` command line over them — and depending on no other entropy package.
`entropy_daemon` depends on it (its history module, and `entropyd hist …`,
which runs this same command line over the vaults it serves — one
implementation, two entry points); `entropy_sync` knows nothing about it, and
the arrow never runs the other way.

## Shape

- `lib/src/hist/` — `implements: vault_hist`. Per-file history as
  append-only immutable files: forward dmp patches from snapshots, sha256
  hash-linked version graph, five file types
  (`snapshot|patch|deleted|conflict|merged`), and the verifying reader
  (graph / primary line / branches / materialize). Files in, files out;
  storage is an injected `HistStore`.

  The write surface is **one stateless verb**: `commit(path, content,
  previous?, previousHash?, at?)`, plus `merge(path, leaf, into)`. There is
  no debounce, no timer and no persisted baseline here — *when* an edit
  becomes a version is the caller's decision (`HistCommitQueue` in
  `entropy_daemon`; the owner's command in the CLI), which is what lets a
  commit be replayed, interleaved, or run from two processes without
  anything to desynchronize. The base is recovered from the graph when the
  lineage is unambiguous, else from `previous` / `previousHash`, else the
  state becomes a root snapshot.

  A reconciliation is an ordinary single-parent version plus a `merged`
  marker — **no record ever has two parents**, so reconstruction stays one
  hash-verified chain and history files stay conflict-free in sync. Branches
  are identified by their **leaf hash** (never by writer, so renaming a
  writer cannot reshape the graph) and classified `divergent` / `merged` /
  `archived`; a line's writers are the writers of its **edits**, so an
  anchor snapshot never makes another device's line look like the owner's
  own; the primary line follows the **live content**, never the filenames'
  clocks.

  The **read surface** (history-surface PRD): `hist_refs.dart` resolves
  git-style addresses (full hash, unambiguous prefix, `HEAD`, `HEAD~n`,
  `@{date}` — ambiguity is an error naming the candidates); `hist_log.dart`
  builds log entries (primary line newest first, branches with kind and
  writers, filters by time/writer/count); `hist_diff.dart` is line diff,
  unified diff and blame; `hist_merge.dart` the fork point and diff3 with
  explicit conflict regions; `hist_divergence.dart` the folder's divergent
  paths.
- `lib/src/exclusions/` — `implements: vault_folder` (its exclusion-engine
  half). `ExclusionMatcher` compiles every exclusion source — a configured
  list and ignore files at **any depth**, each anchored at its own directory
  — through the documented gitignore subset; nesting is additive.
  `IgnoreFileTree` tracks the rule files a host offers from its own walk (or
  finds with `discover()`), re-reading by mtime+size. Here rather than in
  the daemon so the standalone CLI reads `.histignore` without a daemon, and
  the daemon's folder service runs the very same engine.
- `lib/src/cli/` — `implements: vault_hist_cli`. A local **git-lite for
  notes** over a bare folder: it records history on command and reads it
  back, and settles a divergent line deliberately — with no daemon, no
  server, no credentials, no passphrase and no registration
  (`app/vault_hist_cli.md`).
  - `hist_cli.dart` — `HistCli`: argument parsing, the verbs (`commit`,
    `log`, `show`, `restore`, `diff`, `blame`, `merge`, `status`),
    rendering, exit statuses, and the help text that says where the model
    is not git (R14). Output goes to an injected byte sink (content is
    emitted verbatim) and an injected error sink; the clock, environment
    and hostname are injectable too, so the whole tool is tested
    in-process.
  - `hist_folder.dart` — `HistFolder`: the folder the tool operates on.
    Locates the root the way git does (nearest `.hist/` above the working
    directory), builds the library's store/reader/writer over it, and walks
    it through the exclusion engine — built-ins (`.hist/`, `.hist-state/`,
    `.git/`, `.trash/`, `.DS_Store`) plus every `.syncignore` /
    `.histignore` at any depth — then the writer's extension list.
  - `hist_state.dart` — `HistState`: this machine's working state,
    `.hist-state/` beside `.hist/` (a built-in exclusion of the folder
    service, so it never syncs) or `--state-dir`. Holds the merge draft and
    a per-path note of the last version this machine recorded or restored —
    a cache the next `commit` offers the library as its base, never a source
    of truth.
- `bin/hist.dart` — the process entry point.
- `lib/src/bridge/` — `implements: vault_hist_bridge`. One structured request
  per process over the same library/CLI, with verified reads, current-content
  guards and preservation before restore. `bin/hist_bridge.dart` is bundled
  in `entropy-hist-obsidian` platform ZIPs; no daemon is involved; BRAT installs the verified engine on first use.

## Key design choices

- **History links by content hash, not time** (RV5): filenames' timestamps
  are for humans; the graph is built from `version`/`prev` sha256 headers.
  The same reason the primary line is chosen by the live content: a device
  with a skewed clock must not be able to take it, and a late-arriving
  offline device must not move it retroactively.
- **Every writer records only its own edits.** An arriving change is never
  committed by the receiver — its own writer did — which is what keeps two
  devices' histories from duplicating each other and makes the graph
  multi-writer without coordination.

## Binary

Compiled to `tools/hist/hist` (gitignored), like the daemon:

```
cd packages/entropy_hist && dart compile exe bin/hist.dart -o ../../tools/hist/hist
```

## Verify

```
dart pub get && dart analyze && dart test
```

`test/hist/` is the library's suite (`implements-tests: vault_hist`; the
`fixtures/dmp_interop/` patches it emits are also consumed by the Obsidian
plugin's cross-language test); `test/cli_test.dart` drives the command line
in-process (`implements-tests: vault_hist_cli`).
