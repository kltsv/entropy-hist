import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// This machine's working state for one folder (`vault_hist_cli`,
/// history-surface R15): `.hist-state/` beside `.hist/` by default — never
/// synced and never history-tracked, a built-in exclusion of the folder
/// service — or wherever `--state-dir` points for a folder inside somebody
/// else's sync.
///
/// It holds only what is meaningful to this machine: an unfinished merge
/// draft, and a per-path note of the last version this machine recorded or
/// restored — the tool's equivalent of the daemon's checkpoint, consulted
/// only when several lines are open and the graph alone cannot name the
/// base. It is a cache, never a source of truth: losing it costs nothing.
class HistState {
  HistState(this.dir);

  /// Absolute path of the working-state directory.
  final String dir;

  File get _headsFile => File(p.join(dir, 'heads.json'));

  Map<String, String> _heads() {
    final file = _headsFile;
    if (!file.existsSync()) return {};
    try {
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map) return {};
      return {
        for (final e in raw.entries)
          if (e.value is String) e.key as String: e.value as String,
      };
    } catch (_) {
      return {}; // a corrupt note behaves like no note at all
    }
  }

  void _writeHeads(Map<String, String> heads) {
    final file = _headsFile;
    if (heads.isEmpty) {
      if (file.existsSync()) file.deleteSync();
      return;
    }
    file.parent.createSync(recursive: true);
    final sorted = Map.fromEntries(
        heads.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
    file.writeAsStringSync('${jsonEncode(sorted)}\n', flush: true);
  }

  /// The last version this machine recorded or restored for [path], if any.
  String? head(String path) => _heads()[path];

  void setHead(String path, String hash) {
    final heads = _heads();
    if (heads[path] == hash) return;
    heads[path] = hash;
    _writeHeads(heads);
  }

  void forgetHead(String path) {
    final heads = _heads();
    if (heads.remove(path) != null) _writeHeads(heads);
  }

  // ---------------------------------------------------------------------------
  // Merge drafts (history-surface R15)
  // ---------------------------------------------------------------------------

  String _draftBase(String path) =>
      p.joinAll([dir, 'merge', ...path.split('/')]);

  File _draftFile(String path) => File('${_draftBase(path)}.draft');

  File _draftMetaFile(String path) => File('${_draftBase(path)}.json');

  /// Where the draft of [path] lives — printed for the owner to open.
  String draftPathOf(String path) => _draftFile(path).path;

  /// Write a draft and what it was composed from.
  void writeDraft(MergeDraft draft, String text) {
    final file = _draftFile(draft.path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text, flush: true);
    _draftMetaFile(draft.path)
        .writeAsStringSync('${jsonEncode(draft.toJson())}\n', flush: true);
  }

  /// The draft of [path] with its text, or null when there is none.
  (MergeDraft, String)? readDraft(String path) {
    final meta = _draftMetaFile(path);
    final file = _draftFile(path);
    if (!meta.existsSync() || !file.existsSync()) return null;
    try {
      final draft = MergeDraft.fromJson(
          (jsonDecode(meta.readAsStringSync()) as Map).cast<String, Object?>());
      return (draft, file.readAsStringSync());
    } catch (_) {
      return null; // a corrupt draft is no draft
    }
  }

  void discardDraft(String path) {
    for (final file in [_draftFile(path), _draftMetaFile(path)]) {
      if (file.existsSync()) file.deleteSync();
    }
  }

  /// Every unfinished draft — so one cannot be silently forgotten.
  List<MergeDraft> drafts() {
    final root = Directory(p.join(dir, 'merge'));
    if (!root.existsSync()) return const [];
    final out = <MergeDraft>[];
    for (final entity in root.listSync(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        out.add(MergeDraft.fromJson(
            (jsonDecode(entity.readAsStringSync()) as Map)
                .cast<String, Object?>()));
      } catch (_) {
        // skip a corrupt note
      }
    }
    return out..sort((a, b) => a.path.compareTo(b.path));
  }
}

/// What a merge draft was composed from: the live version it must be
/// committed against, the branch leaf it settles, the fork point (null when
/// it was taken as a side — not written as a draft then), and when.
class MergeDraft {
  const MergeDraft({
    required this.path,
    required this.live,
    required this.branch,
    required this.base,
    required this.createdMillis,
    required this.conflicts,
  });

  final String path;
  final String live;
  final String branch;
  final String? base;
  final int createdMillis;

  /// How many conflict regions the draft was written with.
  final int conflicts;

  Map<String, Object?> toJson() => {
        'path': path,
        'live': live,
        'branch': branch,
        'base': base,
        'created': createdMillis,
        'conflicts': conflicts,
      };

  static MergeDraft fromJson(Map<String, Object?> json) => MergeDraft(
        path: json['path'] as String,
        live: json['live'] as String,
        branch: json['branch'] as String,
        base: json['base'] as String?,
        createdMillis: (json['created'] as num).toInt(),
        conflicts: (json['conflicts'] as num?)?.toInt() ?? 0,
      );
}
