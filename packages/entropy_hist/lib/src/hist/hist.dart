/// `vault_hist` — per-file edit history as ordinary files in a mirrored
/// `.hist/` folder (RV5–RV9): forward diff-match-patch patches from full
/// snapshots, versions named and linked by content sha256 into a graph, four
/// immutable file types (`snapshot | patch | deleted | conflict`), written by
/// every client for its own edits only, and a reader that reconstructs any
/// version with per-step hash verification.
///
/// This is the algorithm and layout — pure and framework-agnostic. Shells
/// feed the [HistWriter] path-state changes and inject storage
/// ([HistStore]) and a clock; the
/// desktop daemon and the Flutter app both embed it (RV6).
library;

export 'hist_diff.dart';
export 'hist_divergence.dart';
export 'hist_format.dart';
export 'hist_log.dart';
export 'hist_merge.dart';
export 'hist_reader.dart';
export 'hist_refs.dart';
export 'hist_store.dart';
export 'hist_writer.dart';
