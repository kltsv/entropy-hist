import 'dart:convert';
import 'dart:typed_data';

import 'hist_format.dart';
import 'hist_refs.dart';
import 'hist_store.dart';

/// The `vault_hist` reader (RV5): rebuilds the version graph of a path
/// from whatever files have arrived, in any order, under any clock skew —
/// nodes and edges link by content hash, never by time — and reconstructs
/// any version with sha256 verification after **every** step.

/// Thrown when a version cannot be reconstructed or fails hash verification.
/// dmp applies patches fuzzily and produces garbage without error on a wrong
/// base — silent wrongness is forbidden, so a broken version is flagged and
/// its wrong bytes are never returned (`vault_hist` RV5).
class BrokenVersion implements Exception {
  BrokenVersion(this.path, this.versionHash, this.reason);

  final String path;
  final String versionHash;
  final String reason;

  @override
  String toString() => 'BrokenVersion($path @ $versionHash): $reason';
}

/// One node of the graph: a recorded state, identified by content sha256.
class HistVersion {
  const HistVersion({
    required this.hash,
    required this.timestampMillis,
    required this.writers,
    required this.isSnapshot,
    required this.broken,
  });

  final String hash;

  /// Earliest filename timestamp among files declaring this version — for
  /// humans and sorting only (`vault_hist` RV5).
  final int timestampMillis;

  /// Every writer that recorded this version (duplicates dedup by hash).
  final Set<String> writers;

  /// Whether at least one `snapshot` file declares this version (a root or
  /// a checkpoint).
  final bool isSnapshot;

  /// Structurally broken: no snapshot ancestor is reachable, so the version
  /// cannot be materialized. Content corruption is only detected during
  /// [HistReader.materialize], which throws [BrokenVersion] (RV5).
  final bool broken;
}

/// One recorded edit: a forward patch `prev → version` (`vault_hist` RV5).
class HistEdge {
  const HistEdge({
    required this.prev,
    required this.version,
    required this.timestampMillis,
    this.writer,
  });

  final String prev;
  final String version;
  final int timestampMillis;
  final String? writer;
}

/// A `deleted` marker: when a life of the path ended and which leaf was live
/// (`vault_hist` RV5, R15).
class HistDeletion {
  const HistDeletion({
    required this.prev,
    required this.timestampMillis,
    this.writer,
    this.renamedTo,
  });

  final String prev;
  final int timestampMillis;
  final String? writer;
  final String? renamedTo;
}

/// A rescued losing binary (`vault_hist` RV9) — not a graph node.
class HistConflict {
  const HistConflict({
    required this.versionHash,
    required this.timestampMillis,
    this.writer,
  });

  final String versionHash;
  final int timestampMillis;
  final String? writer;
}

/// A rename display link (`vault_hist` RV7, S6): history under the old
/// name stays reachable from the new — no folder was merged or moved.
class HistRenameLink {
  const HistRenameLink({
    required this.path,
    required this.versionHash,
    required this.timestampMillis,
  });

  /// The linked path (the old name for `renamedFrom` links, the new name for
  /// `renamedTo` links).
  final String path;

  /// The content hash the rename carried across.
  final String versionHash;

  final int timestampMillis;
}

/// Versions unreachable from the main line: conflict losers, past lives
/// before deletion, states abandoned by rollback (`vault_hist` RV5).
/// What a branch is, and therefore whether anything is still owed on it
/// (`vault_hist` RV6). The distinction is what lets a surface ask about a
/// divergence without also nagging about the owner's own discarded states.
enum HistBranchKind {
  /// Another writer's line, still open — the only kind that can be merged.
  divergent,

  /// A `merged` marker names this branch's leaf: settled, still readable.
  merged,

  /// A previous life (ended by a `deleted` marker) or a line stranded by a
  /// rollback. The owner's own discarded states — nothing to reconcile, and
  /// a **single writer produces these**, so "one writer" never means "no
  /// branches".
  archived,
}

class HistBranch {
  const HistBranch({
    required this.hashes,
    required this.kind,
    this.endedAtMillis,
    this.writers = const [],
  });

  /// The branch's versions, ordered by timestamp.
  final List<String> hashes;

  /// The branch's identity: its leaf — never the writer that made it, so
  /// renaming a writer cannot reshape the graph.
  String get leaf => hashes.last;

  final HistBranchKind kind;

  /// The writers that contributed to this branch — a human label, not an id.
  final List<String> writers;

  /// The date of the `deleted` marker ending this branch's life, when one
  /// does — so the reader can tell when that life ended.
  final int? endedAtMillis;
}

/// The version graph of one path (`vault_hist` RV5): nodes, edges, roots,
/// the main line (root → the live file's current hash) and branches
/// (everything else).
class HistGraph {
  const HistGraph({
    required this.versions,
    required this.edges,
    required this.roots,
    required this.mainLine,
    required this.branches,
    required this.deletions,
    required this.conflicts,
    required this.renamedFrom,
    required this.renamedTo,
    this.unsavedChangesAfter,
  });

  /// Nodes by hash: `snapshot`/`patch` version hashes, plus prev-only hashes
  /// referenced by `deleted` markers (states that were live but never
  /// recorded).
  final Map<String, HistVersion> versions;

  /// Patch edges, deduped by `(prev, version)` (`vault_hist` RV6).
  final List<HistEdge> edges;

  /// Snapshot versions, deduped by `version` — the graph's roots and
  /// checkpoints.
  final List<String> roots;

  /// Root → the live file's current hash; empty when no live hash was given
  /// or the hash is not reachable from a root.
  final List<String> mainLine;

  final List<HistBranch> branches;

  /// Every `deleted` marker, with its date — the delimiters of past lives.
  final List<HistDeletion> deletions;

  /// Rescued losing binaries (`vault_hist` RV9).
  final List<HistConflict> conflicts;

  /// Display links to old names this path was renamed from (RV7, S6).
  final List<HistRenameLink> renamedFrom;

  /// Display links to new names this path was renamed to (RV7, S6).
  final List<HistRenameLink> renamedTo;

  /// Set when the live hash matches no node: the live file is "unsaved
  /// changes after version X" — an edit still inside the debounce window,
  /// not a node and not an error (`vault_hist` RV5).
  final String? unsavedChangesAfter;
}

/// Reads `.hist/<path>/` folders back into graphs and content
/// (`vault_hist` RV5).
class HistReader {
  HistReader(this.store);

  final HistStore store;

  /// Builds the version graph of [path] from the headers of every file in
  /// its history folder. [liveHash] is the live file's current content hash;
  /// the main line is computed only when it is given and reachable.
  Future<HistGraph> graph(String path, {String? liveHash}) async {
    final headers = await store.listHeaders(path);

    final timestamps = <String, int>{};
    final writers = <String, Set<String>>{};
    final snapshotVersions = <String>{};
    final edgesByKey = <(String, String), HistEdge>{};
    // Every writer of every edge — what a line's authorship is read from
    // (rule 3): a snapshot may be an anchor, an edit never is.
    final edgeWriters = <(String, String), Set<String>>{};
    final deletions = <HistDeletion>[];
    final conflicts = <HistConflict>[];
    final renamedFrom = <HistRenameLink>[];
    final renamedTo = <HistRenameLink>[];
    final mergedLeaves = <String>{};

    void note(String hash, int ts, String? writer) {
      timestamps.update(hash, (t) => t < ts ? t : ts, ifAbsent: () => ts);
      if (writer != null) (writers[hash] ??= {}).add(writer);
    }

    for (final h in headers) {
      final ts = h.timestampMillis;
      switch (h.type) {
        case HistFileType.snapshot:
          final version = h.version;
          if (version == null) continue;
          note(version, ts, h.writer);
          snapshotVersions.add(version);
          if (h.renamedFrom != null) {
            renamedFrom.add(HistRenameLink(
                path: h.renamedFrom!,
                versionHash: version,
                timestampMillis: ts));
          }
        case HistFileType.patch:
          final version = h.version;
          final prev = h.prev;
          if (version == null || prev == null) continue;
          note(version, ts, h.writer);
          edgesByKey.putIfAbsent(
            (prev, version),
            () => HistEdge(
                prev: prev,
                version: version,
                timestampMillis: ts,
                writer: h.writer),
          );
          if (h.writer != null) {
            (edgeWriters[(prev, version)] ??= {}).add(h.writer!);
          }
        case HistFileType.deleted:
          final prev = h.prev;
          if (prev == null) continue;
          deletions.add(HistDeletion(
              prev: prev,
              timestampMillis: ts,
              writer: h.writer,
              renamedTo: h.renamedTo));
          if (h.renamedTo != null) {
            renamedTo.add(HistRenameLink(
                path: h.renamedTo!, versionHash: prev, timestampMillis: ts));
          }
        case HistFileType.merged:
          if (h.merged != null) mergedLeaves.add(h.merged!);
        case HistFileType.conflict:
          if (h.version == null) continue;
          conflicts.add(HistConflict(
              versionHash: h.version!, timestampMillis: ts, writer: h.writer));
      }
    }

    // Prev-only hashes referenced by deleted markers become nodes: states
    // that were live when a life ended but were never recorded whole.
    for (final d in deletions) {
      timestamps.putIfAbsent(d.prev, () => d.timestampMillis);
    }

    // Structural brokenness: a version with no snapshot ancestor cannot be
    // materialized (RV5).
    final children = <String, List<String>>{};
    for (final key in edgesByKey.keys) {
      (children[key.$1] ??= []).add(key.$2);
    }
    final reachable = <String>{...snapshotVersions};
    final queue = [...snapshotVersions];
    while (queue.isNotEmpty) {
      final cur = queue.removeLast();
      for (final child in children[cur] ?? const <String>[]) {
        if (reachable.add(child)) queue.add(child);
      }
    }

    final versions = <String, HistVersion>{
      for (final e in timestamps.entries)
        e.key: HistVersion(
          hash: e.key,
          timestampMillis: e.value,
          writers: writers[e.key] ?? const {},
          isSnapshot: snapshotVersions.contains(e.key),
          broken: !reachable.contains(e.key),
        ),
    };

    int order(String a, String b) {
      final byTs = timestamps[a]!.compareTo(timestamps[b]!);
      return byTs != 0 ? byTs : a.compareTo(b);
    }

    final roots = snapshotVersions.toList()..sort(order);
    final edges = edgesByKey.values.toList()
      ..sort((a, b) {
        final byTs = a.timestampMillis.compareTo(b.timestampMillis);
        if (byTs != 0) return byTs;
        final byPrev = a.prev.compareTo(b.prev);
        return byPrev != 0 ? byPrev : a.version.compareTo(b.version);
      });

    final mainLine =
        _mainLine(liveHash, versions, snapshotVersions, edgesByKey);

    String? unsavedAfter;
    if (liveHash != null &&
        !versions.containsKey(liveHash) &&
        versions.isNotEmpty) {
      unsavedAfter = _head(versions, edgesByKey, deletions);
    }

    final branches = _branches(versions, edgesByKey, mainLine, deletions, order,
        mergedLeaves, writers, edgeWriters);

    return HistGraph(
      versions: versions,
      edges: edges,
      roots: roots,
      mainLine: mainLine,
      branches: branches,
      deletions: deletions,
      conflicts: conflicts,
      renamedFrom: renamedFrom,
      renamedTo: renamedTo,
      unsavedChangesAfter: unsavedAfter,
    );
  }

  /// Resolve a git-style revision address against [path]'s graph
  /// (`vault_hist` R1): a full hash, an unambiguous prefix, `HEAD`,
  /// `HEAD~n` or `@{<instant>}`. Throws [HistRefError].
  Future<String> resolve(String path, String ref, {String? liveHash}) async =>
      resolveRef(await graph(path, liveHash: liveHash), ref);

  /// Reconstructs the content whose sha256 is [versionHash]: start at the
  /// nearest snapshot ancestor, apply forward patches along the chain, and
  /// verify sha256 against the declared version after **every** step —
  /// including the snapshot itself. Throws [BrokenVersion] on any mismatch
  /// (`vault_hist` RV5).
  Future<Uint8List> materialize(String path, String versionHash) async {
    final headers = await store.listHeaders(path);

    final snapshotFiles = <String, List<String>>{};
    final patchFiles = <(String, String), List<String>>{};
    final parents = <String, Set<String>>{};
    for (final h in headers) {
      if (h.type == HistFileType.snapshot && h.version != null) {
        (snapshotFiles[h.version!] ??= []).add(h.filename);
      } else if (h.type == HistFileType.patch &&
          h.version != null &&
          h.prev != null) {
        (patchFiles[(h.prev!, h.version!)] ??= []).add(h.filename);
        (parents[h.version!] ??= {}).add(h.prev!);
      }
    }

    // The version is itself a snapshot: read it directly (redundant copies
    // are content-identical; a corrupt copy is skipped for an intact one).
    if (snapshotFiles.containsKey(versionHash)) {
      final text = await _verifiedSnapshot(path, versionHash, snapshotFiles);
      if (text == null) {
        throw BrokenVersion(
            path, versionHash, 'snapshot bytes fail sha256 verification');
      }
      return utf8.encode(text);
    }

    // Breadth-first walk backward over `prev` links to the nearest snapshot
    // ancestor.
    final cameFrom = <String, String>{};
    final visited = <String>{versionHash};
    var frontier = [versionHash];
    String? ancestor;
    while (frontier.isNotEmpty && ancestor == null) {
      final next = <String>[];
      for (final node in frontier) {
        for (final prev in parents[node] ?? const <String>{}) {
          if (!visited.add(prev)) continue;
          cameFrom[prev] = node;
          if (snapshotFiles.containsKey(prev)) {
            ancestor = prev;
            break;
          }
          next.add(prev);
        }
        if (ancestor != null) break;
      }
      frontier = next;
    }
    if (ancestor == null) {
      throw BrokenVersion(path, versionHash, 'no snapshot ancestor reachable');
    }

    var text = await _verifiedSnapshot(path, ancestor, snapshotFiles);
    if (text == null) {
      throw BrokenVersion(path, versionHash,
          'snapshot ancestor $ancestor fails sha256 verification');
    }

    var cur = ancestor;
    while (cur != versionHash) {
      final child = cameFrom[cur]!;
      String? applied;
      for (final filename in patchFiles[(cur, child)]!) {
        final body = bodyOf(await store.read(path, filename));
        final patchText = decodeUtf8Text(body);
        if (patchText == null) continue;
        final result = applyPatchText(patchText, text!);
        if (result != null && sha256Hex(utf8.encode(result)) == child) {
          applied = result;
          break;
        }
      }
      if (applied == null) {
        throw BrokenVersion(path, versionHash,
            'patch $cur -> $child fails sha256 verification');
      }
      text = applied;
      cur = child;
    }
    return utf8.encode(text!);
  }

  /// The snapshot body of [hash] verified against its declared version, or
  /// `null` when every copy fails (RV5 — verify after every step).
  Future<String?> _verifiedSnapshot(
      String path, String hash, Map<String, List<String>> snapshotFiles) async {
    for (final filename in snapshotFiles[hash] ?? const <String>[]) {
      final body = bodyOf(await store.read(path, filename));
      if (sha256Hex(body) != hash) continue;
      final text = decodeUtf8Text(body);
      if (text != null) return text;
    }
    return null;
  }

  /// Shortest path root → [liveHash], following `prev` links backward from
  /// the live hash to the nearest snapshot (`vault_hist` RV5 — the main
  /// line runs from a root to the live file's current hash).
  List<String> _mainLine(
    String? liveHash,
    Map<String, HistVersion> versions,
    Set<String> snapshotVersions,
    Map<(String, String), HistEdge> edgesByKey,
  ) {
    if (liveHash == null || !versions.containsKey(liveHash)) return const [];
    if (snapshotVersions.contains(liveHash)) return [liveHash];

    final parents = <String, Set<String>>{};
    for (final key in edgesByKey.keys) {
      (parents[key.$2] ??= {}).add(key.$1);
    }
    final cameFrom = <String, String>{};
    final visited = <String>{liveHash};
    var frontier = [liveHash];
    String? root;
    while (frontier.isNotEmpty && root == null) {
      final next = <String>[];
      for (final node in frontier) {
        for (final prev in (parents[node] ?? const <String>{}).toList()
          ..sort()) {
          if (!visited.add(prev)) continue;
          cameFrom[prev] = node;
          if (snapshotVersions.contains(prev)) {
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
    while (cur != liveHash) {
      cur = cameFrom[cur]!;
      line.add(cur);
    }
    return line;
  }

  /// The head the live file's unsaved edit follows: the latest leaf, live
  /// leaves (not referenced by a deleted marker) preferred.
  String _head(
    Map<String, HistVersion> versions,
    Map<(String, String), HistEdge> edgesByKey,
    List<HistDeletion> deletions,
  ) {
    final withOutgoing = {for (final key in edgesByKey.keys) key.$1};
    final deleted = {for (final d in deletions) d.prev};
    var leaves = versions.keys.where((h) => !withOutgoing.contains(h)).toList();
    final live = leaves.where((h) => !deleted.contains(h)).toList();
    if (live.isNotEmpty) leaves = live;
    leaves.sort((a, b) {
      final byTs =
          versions[a]!.timestampMillis.compareTo(versions[b]!.timestampMillis);
      return byTs != 0 ? byTs : a.compareTo(b);
    });
    return leaves.last;
  }

  /// Groups versions unreachable from the main line into connected
  /// components; a branch ending at a `deleted` marker carries the marker's
  /// date (`vault_hist` RV5 — conflict losers, past lives, rollbacks).
  List<HistBranch> _branches(
    Map<String, HistVersion> versions,
    Map<(String, String), HistEdge> edgesByKey,
    List<String> mainLine,
    List<HistDeletion> deletions,
    int Function(String, String) order,
    Set<String> mergedLeaves,
    Map<String, Set<String>> writers,
    Map<(String, String), Set<String>> edgeWriters,
  ) {
    final onMain = mainLine.toSet();
    final off = versions.keys.where((h) => !onMain.contains(h)).toSet();
    if (off.isEmpty) return const [];

    // Whose work a line is, read from its **edits** (rule 3): the writers
    // of the patches along it. A snapshot's writer counts only for a line
    // that is nothing but that snapshot — a snapshot may be an anchor,
    // written by a device that merely held the state, and two devices
    // anchoring one base must not make each other's edits look like the
    // owner's own.
    final mainWriters = <String>{};
    for (var i = 1; i < mainLine.length; i++) {
      mainWriters
          .addAll(edgeWriters[(mainLine[i - 1], mainLine[i])] ?? const {});
    }
    if (mainWriters.isEmpty && mainLine.isNotEmpty) {
      mainWriters.addAll(writers[mainLine.single] ?? const {});
    }

    final adjacent = <String, Set<String>>{};
    for (final key in edgesByKey.keys) {
      if (off.contains(key.$1) && off.contains(key.$2)) {
        (adjacent[key.$1] ??= {}).add(key.$2);
        (adjacent[key.$2] ??= {}).add(key.$1);
      }
    }

    final branches = <HistBranch>[];
    final seen = <String>{};
    for (final start in off.toList()..sort(order)) {
      if (!seen.add(start)) continue;
      final component = <String>[start];
      final queue = [start];
      while (queue.isNotEmpty) {
        final cur = queue.removeLast();
        for (final other in adjacent[cur] ?? const <String>{}) {
          if (seen.add(other)) {
            component.add(other);
            queue.add(other);
          }
        }
      }
      component.sort(order);
      int? endedAt;
      for (final d in deletions) {
        if (component.contains(d.prev)) {
          endedAt = endedAt == null || d.timestampMillis > endedAt
              ? d.timestampMillis
              : endedAt;
        }
      }
      // A branch is settled if *any* marker names its leaf, whoever wrote
      // it — two devices reconciling concurrently must not make it look
      // open again, or a surface would loop on it.
      final leaf = component.last;
      // The branch's edits: every edge that lands in the component,
      // including the one that forks it off the line it left.
      final componentSet = component.toSet();
      final branchWriters = <String>{
        for (final key in edgesByKey.keys)
          if (componentSet.contains(key.$2))
            ...(edgeWriters[key] ?? const <String>{}),
      };
      if (branchWriters.isEmpty) {
        // Nothing but a snapshot: its writer is all there is to go on.
        for (final h in component) {
          branchWriters.addAll(writers[h] ?? const {});
        }
      }
      // Whose work is this? A line written only by writers that also wrote
      // the primary line is the owner's own discarded state — a rollback, or
      // a life that ended — with nothing to reconcile. A line carrying a
      // writer the primary line does not have is somebody else's, still open.
      //
      // This is why writer names must be stable and unique per device: two
      // devices sharing one name make their divergence look self-inflicted.
      final ownWork = branchWriters.difference(mainWriters).isEmpty;
      final kind = mergedLeaves.contains(leaf)
          ? HistBranchKind.merged
          : (endedAt != null || ownWork)
              ? HistBranchKind.archived
              : HistBranchKind.divergent;
      branches.add(HistBranch(
        hashes: component,
        kind: kind,
        endedAtMillis: endedAt,
        writers: branchWriters.toList()..sort(),
      ));
    }
    return branches;
  }
}
