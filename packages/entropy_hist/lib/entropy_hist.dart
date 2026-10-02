/// Per-file history for notes, standing alone: the `vault_hist` library
/// (snapshots + forward patches, hash-linked, multi-writer), the exclusion
/// engine that reads `.histignore` / `.syncignore`, and the `hist` command
/// line over them (`vault_hist_cli`) — a local git-lite for notes over a
/// bare folder.
///
/// This package depends on nothing else of the entropy stack. Two entry
/// points share the command line: the `hist` binary (`bin/hist.dart`) and
/// the daemon's `hist` verbs over the vaults it serves (`entropy_daemon`) —
/// the same code, never a second implementation.
library;

// The history library (`vault_hist`).
export 'src/hist/hist.dart';

// The exclusion engine of the folder service (`vault_folder` R7): here so
// the standalone CLI reads ignore files without the daemon, and the daemon's
// folder service runs the same engine.
export 'src/exclusions/exclusions.dart';

// The command line (`vault_hist_cli`).
export 'src/cli/hist_cli.dart';
export 'src/cli/hist_folder.dart';
export 'src/cli/hist_state.dart';
