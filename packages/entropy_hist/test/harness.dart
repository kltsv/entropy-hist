/// Shared scaffolding for the `vault_hist_cli` test-spec: a temp folder, an
/// injected clock, the tool run in-process with captured output, and the
/// plain-file reads of `.hist/` the cases assert on.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:entropy_hist/entropy_hist.dart';
import 'package:path/path.dart' as p;

String sha(String text) => sha256Hex(utf8.encode(text));

class CliResult {
  CliResult(this.code, this.bytes, this.stderr);

  final int code;
  final Uint8List bytes;
  final String stderr;

  String get stdout => utf8.decode(bytes, allowMalformed: true);

  /// Non-empty output lines, trimmed of the rendering's indentation.
  List<String> get lines => stdout
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
}

class _BytesSink implements Sink<List<int>> {
  final BytesBuilder builder = BytesBuilder(copy: false);

  @override
  void add(List<int> data) => builder.add(data);

  @override
  void close() {}
}

class CliHarness {
  CliHarness()
      : tmp = Directory.systemTemp.createTempSync('hist-cli'),
        clock = 1700000000000 {
    Directory(root).createSync(recursive: true);
  }

  final Directory tmp;
  int clock;

  String get root => p.join(tmp.path, 'vault');

  void dispose() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  }

  File file(String rel) => File(p.joinAll([root, ...rel.split('/')]));

  void write(String rel, String content) {
    final f = file(rel);
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  void delete(String rel) => file(rel).deleteSync();

  String read(String rel) => file(rel).readAsStringSync();

  /// One invocation of the tool: writer `laptop` unless `--writer` says
  /// otherwise, the injected clock, cwd = the folder unless given.
  Future<CliResult> run(List<String> args, {String? cwd}) async {
    final out = _BytesSink();
    final err = StringBuffer();
    final cli = HistCli(
      out: out,
      err: err,
      now: () => clock,
      environment: const {},
      hostname: 'laptop',
    );
    final code = await cli.run(args, cwd: cwd ?? root);
    return CliResult(code, out.builder.takeBytes(), err.toString());
  }

  FsHistStore get store => FsHistStore(root);

  Future<List<HistFileHeader>> headers(String rel) => store.listHeaders(rel);

  Future<List<String>> names(String rel) async =>
      [for (final h in await headers(rel)) h.filename];

  /// Every history file under the mirror, with its bytes — for "nothing was
  /// written" assertions.
  Map<String, List<int>> mirrorSnapshot() {
    final mirror = Directory(p.join(root, '.hist'));
    if (!mirror.existsSync()) return const {};
    return {
      for (final e in mirror.listSync(recursive: true, followLinks: false))
        if (e is File)
          p.relative(e.path, from: mirror.path): e.readAsBytesSync(),
    };
  }

  // Files arriving through sync: placed under .hist/ directly.

  Future<void> putSnapshot(String rel, String content,
          {required int ts, String by = 'phone'}) =>
      store.write(
        rel,
        versionFileName(ts, HistFileType.snapshot),
        encodeVersionFile(
            version: sha(content), writer: by, body: utf8.encode(content)),
      );

  Future<void> putPatch(String rel, String prev, String next,
          {required int ts, String by = 'phone'}) =>
      putPatchRaw(rel,
          prevHash: sha(prev),
          versionHash: sha(next),
          body: makePatchText(prev, next),
          ts: ts,
          by: by);

  Future<void> putPatchRaw(String rel,
          {required String prevHash,
          required String versionHash,
          required String body,
          required int ts,
          String by = 'phone'}) =>
      store.write(
        rel,
        versionFileName(ts, HistFileType.patch),
        encodeVersionFile(
            version: versionHash,
            prev: prevHash,
            writer: by,
            body: utf8.encode(body)),
      );

  Future<void> putDeleted(String rel,
          {required String prevHash, required int ts, String by = 'phone'}) =>
      store.write(
        rel,
        versionFileName(ts, HistFileType.deleted),
        encodeVersionFile(prev: prevHash, writer: by),
      );

  Future<void> putMerged(String rel,
          {required String merged,
          required String into,
          required int ts,
          String by = 'phone'}) =>
      store.write(
        rel,
        versionFileName(ts, HistFileType.merged),
        encodeVersionFile(merged: merged, into: into, writer: by),
      );
}
