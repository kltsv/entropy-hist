import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'hist_format.dart';

/// Storage for `.hist/<path>/` version files, injected by the shell
/// (`vault_hist` RV5, RV6). The store is strictly **append-only**: files
/// are never modified, moved, or deleted, and writing a filename that already
/// exists must throw [HistFileExists].

/// Thrown by [HistStore.write] when the filename is already taken. The
/// writer reacts by bumping the millisecond value until free — names must be
/// unique, nothing more (`vault_hist` RV5).
class HistFileExists implements Exception {
  HistFileExists(this.path, this.filename);

  final String path;
  final String filename;

  @override
  String toString() => 'HistFileExists: .hist/$path/$filename';
}

/// The injected history store: list the headers of every version file under
/// a path's history folder, read one file, append one new file
/// (`vault_hist` RV5). The daemon backs it with the real mirror folder;
/// the app with its sandbox storage.
abstract interface class HistStore {
  /// Headers of every version file under `.hist/[path]/`, sorted by
  /// filename (chronological, thanks to the zero-padded names); empty when
  /// the folder does not exist. Files whose names are not
  /// `<epoch-ms>.<type>` are ignored.
  Future<List<HistFileHeader>> listHeaders(String path);

  /// Every path that has at least one version file — what a folder-wide
  /// traversal (the vault-wide log, the divergence count) iterates.
  Future<List<String>> listPaths();

  /// The raw bytes of one version file.
  Future<Uint8List> read(String path, String filename);

  /// Appends a new version file. Must throw [HistFileExists] when
  /// [filename] already exists — history files are immutable and are never
  /// overwritten (`vault_hist` RV5).
  Future<void> write(String path, String filename, List<int> bytes);
}

/// In-memory [HistStore] for tests and ephemeral hosts.
class MemoryHistStore implements HistStore {
  final Map<String, Map<String, Uint8List>> _folders = {};

  @override
  Future<List<HistFileHeader>> listHeaders(String path) async {
    final folder = _folders[path];
    if (folder == null) return const [];
    final names = folder.keys.toList()..sort();
    return [
      for (final name in names)
        if (HistFileHeader.tryParse(name, folder[name]!) case final h?) h,
    ];
  }

  @override
  Future<List<String>> listPaths() async => [
        for (final e in _folders.entries)
          if (e.value.isNotEmpty) e.key,
      ]..sort();

  @override
  Future<Uint8List> read(String path, String filename) async {
    final bytes = _folders[path]?[filename];
    if (bytes == null) {
      throw StateError('no such history file: .hist/$path/$filename');
    }
    return bytes;
  }

  @override
  Future<void> write(String path, String filename, List<int> bytes) async {
    final folder = _folders.putIfAbsent(path, () => {});
    if (folder.containsKey(filename)) {
      throw HistFileExists(path, filename);
    }
    folder[filename] = Uint8List.fromList(bytes);
  }
}

/// The chunk size of a header read; headers are a few hundred bytes, so
/// one chunk almost always holds the whole prefix.
const int headerReadChunk = 1024;

/// Reads [file] up to and including its first blank line (the end of the
/// header section), in [headerReadChunk]-byte steps — never the whole
/// file. A file with no blank line is read to its end.
Future<Uint8List> readHeaderPrefix(File file) async {
  final raf = await file.open();
  try {
    final out = BytesBuilder(copy: false);
    var previous = -1;
    while (true) {
      final chunk = await raf.read(headerReadChunk);
      if (chunk.isEmpty) break;
      for (var i = 0; i < chunk.length; i++) {
        if (chunk[i] == 0x0a && previous == 0x0a) {
          out.add(Uint8List.sublistView(chunk, 0, i + 1));
          return out.takeBytes();
        }
        previous = chunk[i];
      }
      out.add(chunk);
    }
    return out.takeBytes();
  } finally {
    await raf.close();
  }
}

/// `dart:io` [HistStore] over the real mirror folder
/// `<vaultRoot>/.hist/<path>/` (`vault_hist` RV5) — the file's vault
/// path becomes a folder under the dot-folder mirror, invisible to
/// Obsidian's indexing.
class FsHistStore implements HistStore {
  FsHistStore(this.vaultRoot, {this.mirrorDir = '.hist'});

  final String vaultRoot;
  final String mirrorDir;

  Directory _dirFor(String path) =>
      Directory(p.joinAll([vaultRoot, mirrorDir, ...path.split('/')]));

  /// Headers only, so each file is read as a **prefix** up to its first
  /// blank line — a snapshot is a whole note, and every traversal (the
  /// graph, the divergence count) must stay cheap (`vault_hist` R18).
  @override
  Future<List<HistFileHeader>> listHeaders(String path) async {
    final dir = _dirFor(path);
    if (!await dir.exists()) return const [];
    final headers = <HistFileHeader>[];
    await for (final entry in dir.list()) {
      if (entry is! File) continue;
      final name = p.basename(entry.path);
      if (!isVersionFileName(name)) continue;
      final header =
          HistFileHeader.tryParse(name, await readHeaderPrefix(entry));
      if (header != null) headers.add(header);
    }
    headers.sort((a, b) => a.filename.compareTo(b.filename));
    return headers;
  }

  /// Walks the mirror once: a directory is a path's history folder when it
  /// holds at least one file named `<epoch-ms>.<type>`.
  @override
  Future<List<String>> listPaths() async {
    final mirror = Directory(p.join(vaultRoot, mirrorDir));
    if (!await mirror.exists()) return const [];
    final paths = <String>{};
    await for (final entry
        in mirror.list(recursive: true, followLinks: false)) {
      if (entry is! File) continue;
      if (!isVersionFileName(p.basename(entry.path))) continue;
      final dir = p.relative(entry.parent.path, from: mirror.path);
      paths.add(p.posix.joinAll(p.split(dir)));
    }
    return paths.toList()..sort();
  }

  @override
  Future<Uint8List> read(String path, String filename) =>
      File(p.join(_dirFor(path).path, filename)).readAsBytes();

  @override
  Future<void> write(String path, String filename, List<int> bytes) async {
    final dir = _dirFor(path);
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, filename));
    try {
      await file.create(exclusive: true);
    } on PathExistsException {
      throw HistFileExists(path, filename);
    }
    await file.writeAsBytes(bytes, flush: true);
  }
}
