import 'dart:io';
import 'dart:typed_data';

import '../exclusions/exclusions.dart';
import '../hist/hist.dart';
import 'package:path/path.dart' as p;

import 'hist_state.dart';

/// A request the tool cannot honour: a path outside the folder, a verb
/// misused, a merge that cannot proceed. [usage] marks the ones that are the
/// caller's spelling rather than the history's state.
class HistCliError implements Exception {
  HistCliError(this.message, {this.usage = false});

  final String message;
  final bool usage;

  @override
  String toString() => message;
}

/// The bare folder the command line operates on (`vault_hist_cli` — *The
/// folder, and what is tracked*): its `.hist/` mirror through the library's
/// own store, reader and writer; its working state; and the walk that
/// decides what is tracked — the shared exclusion engine over the built-in
/// exclusions and every `.syncignore` / `.histignore` at any depth, then the
/// writer's extension list.
class HistFolder {
  HistFolder({
    required String root,
    String? stateDir,
    required this.writerName,
    List<String> extensions = const ['.md'],
    int Function()? now,
  })  : root = p.canonicalize(root),
        stateDir = stateDir == null
            ? p.join(p.canonicalize(root), stateDirName)
            : p.canonicalize(stateDir) {
    store = FsHistStore(this.root);
    reader = HistReader(store);
    writer = HistWriter(
      store: store,
      now: now ?? () => DateTime.now().millisecondsSinceEpoch,
      extensions: extensions,
      writerName: writerName,
    );
    state = HistState(this.stateDir);
  }

  /// The mirror the library writes.
  static const mirrorName = HistWriter.mirrorRoot;

  /// This machine's working state beside the mirror (history-surface R15).
  static const stateDirName = '.hist-state';

  /// Exclusions the tool applies before any ignore file: the mirror and the
  /// working state (never tracked), and what no bare folder wants versioned.
  static const builtInExclusions = [
    '$mirrorName/',
    '$stateDirName/',
    '.git/',
    '.trash/',
    '.DS_Store',
  ];

  /// Absolute, canonical path of the folder.
  final String root;

  /// Absolute path of the working-state directory.
  final String stateDir;

  /// Stamps every version this tool records (C5: stable per device).
  final String writerName;

  late final FsHistStore store;
  late final HistReader reader;
  late final HistWriter writer;
  late final HistState state;

  ExclusionMatcher? _rules;

  /// The folder's exclusion rules, compiled once per invocation from the
  /// built-ins and every ignore file in the tree.
  ExclusionMatcher get rules => _rules ??= _compileRules();

  ExclusionMatcher _compileRules() {
    final tree = IgnoreFileTree(root, names: {
      syncIgnoreFileName,
      histIgnoreFileName,
    })
      ..discover()
      ..refresh();
    return ExclusionMatcher.fromSources([
      IgnoreSource('', builtInExclusions),
      ...tree.sources(syncIgnoreFileName),
      ...tree.sources(histIgnoreFileName),
    ]);
  }

  /// Locate the folder the way git finds a repository: the nearest
  /// directory at or above [start] holding a `.hist/` mirror, else [start]
  /// itself.
  static String locate(String start) {
    var dir = p.canonicalize(start);
    while (true) {
      if (Directory(p.join(dir, mirrorName)).existsSync()) return dir;
      final parent = p.dirname(dir);
      if (parent == dir) return p.canonicalize(start);
      dir = parent;
    }
  }

  /// The folder-relative, `/`-separated form of a path the caller typed —
  /// relative to [cwd] or absolute. A path outside the folder is refused.
  String relativize(String input, {required String cwd}) {
    final abs =
        p.canonicalize(p.isAbsolute(input) ? input : p.join(cwd, input));
    final rel = p.relative(abs, from: root);
    if (rel == '.' || rel.startsWith('..') || p.isAbsolute(rel)) {
      throw HistCliError('$input: outside the folder $root', usage: true);
    }
    return p.posix.joinAll(p.split(rel));
  }

  /// Whether the tool would version [rel]: no exclusion covers it and the
  /// writer's extension list admits it. Content still decides in the end.
  bool tracks(String rel) => !rules.excludes(rel) && writer.tracks(rel);

  /// Every tracked file on disk, folder-relative, sorted. Excluded
  /// directories are not descended into; symlinks are not followed.
  List<String> trackedOnDisk() {
    final out = <String>[];
    void walk(Directory dir, String relDir) {
      for (final entity in dir.listSync(followLinks: false)) {
        final name = p.basename(entity.path);
        final rel = relDir.isEmpty ? name : '$relDir/$name';
        if (entity is Link) continue;
        if (entity is Directory) {
          if (rules.excludes(rel)) continue;
          walk(entity, rel);
        } else if (entity is File) {
          if (tracks(rel)) out.add(rel);
        }
      }
    }

    final dir = Directory(root);
    if (dir.existsSync()) walk(dir, '');
    return out..sort();
  }

  /// Every path that has history and is still tracked — the deletions a
  /// folder-wide commit records, the files a folder-wide log or status
  /// traverses.
  Future<List<String>> historyPaths() async => [
        for (final path in await store.listPaths())
          if (tracks(path)) path
      ];

  /// Tracked files on disk ∪ tracked paths with history: what "everything
  /// that differs from the graph" is checked against.
  Future<List<String>> everything() async =>
      {...trackedOnDisk(), ...await historyPaths()}.toList()..sort();

  Future<bool> hasHistory(String rel) async =>
      (await store.listHeaders(rel)).isNotEmpty;

  File fileOf(String rel) => File(p.joinAll([root, ...rel.split('/')]));

  /// The live bytes of [rel], or null when the file is absent.
  Uint8List? liveBytes(String rel) {
    final file = fileOf(rel);
    return file.existsSync() ? file.readAsBytesSync() : null;
  }

  String? liveHash(String rel) {
    final bytes = liveBytes(rel);
    return bytes == null ? null : sha256Hex(bytes);
  }

  /// The graph of [rel] against its live content.
  Future<HistGraph> graphOf(String rel) =>
      reader.graph(rel, liveHash: liveHash(rel));

  /// Write [bytes] over the live file atomically (temp + rename), creating
  /// parent directories as needed.
  void writeLive(String rel, List<int> bytes) {
    final file = fileOf(rel);
    file.parent.createSync(recursive: true);
    final temp = File('${file.path}.hist-tmp');
    temp.writeAsBytesSync(bytes, flush: true);
    temp.renameSync(file.path);
  }
}
