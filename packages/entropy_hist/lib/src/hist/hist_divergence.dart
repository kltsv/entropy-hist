import 'hist_reader.dart';

/// The divergence count (`vault_hist` — *The reconciliation inputs*,
/// history-surface R16–R18): how many **files** have at least one divergent
/// line, derived from each path's graph against its live content. Nothing
/// is stored to know it; a host keeps it incrementally by recounting the
/// one path each history write belongs to.

/// Whether [path]'s graph, against [liveHash], carries a divergent branch.
Future<bool> hasDivergentLine(
  HistReader reader,
  String path, {
  required String? liveHash,
}) async {
  final graph = await reader.graph(path, liveHash: liveHash);
  return graph.branches.any((b) => b.kind == HistBranchKind.divergent);
}

/// The paths among [paths] that have a divergent line — a count of files,
/// never of branches (R13). [liveHashOf] supplies each path's live content
/// hash (null when the file is absent).
Future<List<String>> divergentPaths(
  HistReader reader,
  Iterable<String> paths, {
  required Future<String?> Function(String path) liveHashOf,
}) async {
  final out = <String>[];
  for (final path in paths) {
    if (await hasDivergentLine(reader, path,
        liveHash: await liveHashOf(path))) {
      out.add(path);
    }
  }
  return out..sort();
}
