import 'hist_reader.dart';

/// The log of a path (`vault_hist` — *The read surface*, history-surface
/// R2): the primary line newest first, each entry naming its version, its
/// writers and its time and marking the live one; with every line requested,
/// the branches follow, identified by leaf and labelled with kind and
/// writers. Ordering along a line comes from the graph and is exact.

class HistLogEntry {
  const HistLogEntry({
    required this.path,
    required this.hash,
    required this.timestampMillis,
    required this.writers,
    required this.isLive,
    required this.isSnapshot,
    this.branch,
  });

  final String path;
  final String hash;

  /// The earliest filename timestamp declaring this version — for humans
  /// and sorting only (`vault_hist` RV5).
  final int timestampMillis;

  final List<String> writers;
  final bool isLive;
  final bool isSnapshot;

  /// The branch this entry belongs to; `null` on the primary line.
  final HistBranch? branch;

  bool get onPrimaryLine => branch == null;
}

class HistLog {
  const HistLog({
    required this.path,
    required this.entries,
    required this.hasPrimaryLine,
    this.unsavedChangesAfter,
  });

  final String path;

  /// Primary-line entries first (newest first), then — when requested, or
  /// when there is no primary line — each branch's entries, newest first,
  /// branch by branch in the graph's order.
  final List<HistLogEntry> entries;

  /// False when the file has no live version (deleted, absent, or
  /// unrecorded on disk): every line is then listed as a branch.
  final bool hasPrimaryLine;

  /// Set when the live file's content is not a recorded version: "unsaved
  /// changes after X" (`vault_hist` reader rule 5).
  final String? unsavedChangesAfter;

  /// Every branch that appears in [entries], in order.
  List<HistBranch> get branches {
    final out = <HistBranch>[];
    for (final e in entries) {
      final b = e.branch;
      if (b != null && !out.contains(b)) out.add(b);
    }
    return out;
  }

  /// The same log filtered: entries recorded at or after [sinceMillis],
  /// carrying [author] among their writers, at most [limit] of them.
  HistLog where({int? sinceMillis, String? author, int? limit}) {
    Iterable<HistLogEntry> kept = entries;
    if (sinceMillis != null) {
      kept = kept.where((e) => e.timestampMillis >= sinceMillis);
    }
    if (author != null) kept = kept.where((e) => e.writers.contains(author));
    if (limit != null) kept = kept.take(limit);
    return HistLog(
      path: path,
      entries: kept.toList(),
      hasPrimaryLine: hasPrimaryLine,
      unsavedChangesAfter: unsavedChangesAfter,
    );
  }
}

/// Build the log of [path] from its [graph]. [all] appends the branches;
/// a graph with no primary line lists its branches regardless, since there
/// is nothing else to show.
///
/// A live file with **unsaved changes** has no primary line in the graph —
/// its content is not a version — but it does have a head: the version the
/// edit follows. The log lists the line ending there as the line (with
/// nothing marked live), so the owner reads their history rather than a
/// pile of branches; the announcement of unsaved changes rides alongside.
HistLog logOf(HistGraph graph, {required String path, bool all = false}) {
  final entries = <HistLogEntry>[];
  final line = graph.mainLine.isNotEmpty
      ? graph.mainLine
      : graph.unsavedChangesAfter != null
          ? _lineTo(graph, graph.unsavedChangesAfter!)
          : const <String>[];
  final live = graph.mainLine.isEmpty ? null : graph.mainLine.last;
  for (final hash in line.reversed) {
    entries.add(_entry(path, graph, hash, isLive: hash == live));
  }
  final onLine = line.toSet();
  if (all || line.isEmpty) {
    for (final branch in graph.branches) {
      if (branch.hashes.any(onLine.contains)) continue;
      for (final hash in branch.hashes.reversed) {
        entries.add(_entry(path, graph, hash, isLive: false, branch: branch));
      }
    }
  }
  return HistLog(
    path: path,
    entries: entries,
    hasPrimaryLine: line.isNotEmpty,
    unsavedChangesAfter: graph.unsavedChangesAfter,
  );
}

/// Root → [head] following `prev` links backward to the nearest snapshot —
/// the same walk the reader makes for the primary line, over the graph it
/// already built. Empty when [head] is unknown or has no snapshot ancestor.
List<String> lineTo(HistGraph graph, String head) => _lineTo(graph, head);

List<String> _lineTo(HistGraph graph, String head) {
  if (!graph.versions.containsKey(head)) return const [];
  bool isRoot(String h) => graph.versions[h]!.isSnapshot;
  if (isRoot(head)) return [head];
  final parents = <String, List<String>>{};
  for (final e in graph.edges) {
    (parents[e.version] ??= []).add(e.prev);
  }
  final cameFrom = <String, String>{};
  final visited = <String>{head};
  var frontier = [head];
  String? root;
  while (frontier.isNotEmpty && root == null) {
    final next = <String>[];
    for (final node in frontier) {
      for (final prev in (parents[node] ?? const <String>[]).toList()..sort()) {
        if (!visited.add(prev)) continue;
        cameFrom[prev] = node;
        if (isRoot(prev)) {
          root = prev;
          break;
        }
        next.add(prev);
      }
      if (root != null) break;
    }
    frontier = next;
  }
  if (root == null) return const [];
  final line = <String>[root];
  var cur = root;
  while (cur != head) {
    cur = cameFrom[cur]!;
    line.add(cur);
  }
  return line;
}

HistLogEntry _entry(
  String path,
  HistGraph graph,
  String hash, {
  required bool isLive,
  HistBranch? branch,
}) {
  final version = graph.versions[hash]!;
  return HistLogEntry(
    path: path,
    hash: hash,
    timestampMillis: version.timestampMillis,
    writers: version.writers.toList()..sort(),
    isLive: isLive,
    isSnapshot: version.isSnapshot,
    branch: branch,
  );
}
