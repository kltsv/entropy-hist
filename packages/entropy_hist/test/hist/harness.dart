/// Shared test harness for the `vault_hist` cases
/// (`app/vault_hist.tests.md`): an injected store, injected persistent
/// writer state, an injected clock, and helpers to craft history files that
/// "arrive through sync" (placed in the store externally, never via the
/// writer).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:entropy_hist/entropy_hist.dart';

/// Injected clock: `clock.call` is the writer's `now`.
class FakeClock {
  FakeClock(this.millis);

  int millis;

  int call() => millis;
}

/// Lowercase-hex sha256 of the exact bytes of [s] (the test-spec's `sha(X)`).
String sha(String s) => sha256Hex(utf8.encode(s));

class Harness {
  Harness({
    HistStore? store,
    String writerName = 'laptop',
    this.idleMillis = 60000,
    List<String> extensions = const ['.md'],
    int snapshotEvery = 200,
    int at = 1700000000000,
  })  : store = store ?? MemoryHistStore(),
        clock = FakeClock(at) {
    writer = HistWriter(
      store: this.store,
      now: clock.call,
      extensions: extensions,
      writerName: writerName,
      snapshotEvery: snapshotEvery,
    );
    reader = HistReader(this.store);
  }

  final HistStore store;
  final FakeClock clock;
  final int idleMillis;
  late final HistWriter writer;
  late final HistReader reader;

  // The harness plays the **caller**: `vault_hist` has no timing of its own,
  // so the coalescing a daemon would do lives here (`vault_hist` D7).
  final Map<String, List<int>?> _pending = {};
  final Map<String, int> _pendingAt = {};
  final Map<String, List<int>?> _lastKnown = {};

  /// Offer a local state without committing it — the caller's buffer.
  void local(String path, String? content) {
    _pending[path] = content == null ? null : utf8.encode(content);
    _pendingAt[path] = clock.millis;
  }

  /// Advance the clock and commit whatever was offered.
  Future<List<String>> idle() async {
    clock.millis += idleMillis;
    final written = <String>[];
    for (final path in _pending.keys.toList()) {
      final content = _pending.remove(path);
      final at = _pendingAt.remove(path);
      if (await commitNow(path, content, at: at)) written.add(path);
    }
    return written;
  }

  /// One settled edit: offer then commit.
  Future<void> record(String path, String? content, {int? at}) async {
    if (at != null) clock.millis = at;
    local(path, content);
    await idle();
  }

  /// `commit(path, content, previous?)` straight through, as the daemon calls
  /// it. [previous] defaults to the last state this harness committed for the
  /// path — the cache a caller keeps so a base's bytes are available even when
  /// the folder cannot supply them.
  Future<bool> commitNow(
    String path,
    List<int>? content, {
    List<int>? previous,
    String? previousHash,
    bool usePrevious = true,
    int? at,
  }) async {
    final wrote = await writer.commit(
      path,
      content,
      previous: previous ?? (usePrevious ? _lastKnown[path] : null),
      previousHash: previousHash,
      at: at,
    );
    _lastKnown[path] = content;
    return wrote;
  }

  /// Record that a branch has been reconciled into a version.
  Future<void> merge(String path, String branchLeaf, String into) =>
      writer.merge(path, branchLeaf, into);

  /// Adopt a state that arrived through sync: never committed, but it becomes
  /// the base the next local edit diffs from.
  void adopt(String path, String? content) =>
      _lastKnown[path] = content == null ? null : utf8.encode(content);

  Future<List<HistFileHeader>> headers(String path) => store.listHeaders(path);

  Future<List<String>> names(String path) async =>
      [for (final h in await store.listHeaders(path)) h.filename];

  Future<Uint8List> bytes(String path, String filename) =>
      store.read(path, filename);

  Future<String> body(String path, String filename) async =>
      utf8.decode(bodyOf(await store.read(path, filename)));

  /// Byte content of every file in the path's folder, by filename.
  Future<Map<String, List<int>>> capture(String path) async => {
        for (final name in await names(path)) name: await bytes(path, name),
      };

  /// Reconstructed content of a version, as text.
  Future<String> materializeText(String path, String hash) async =>
      utf8.decode(await reader.materialize(path, hash));

  /// `graph(path)` given the live file's content (`null` = absent).
  Future<HistGraph> graph(String path, {String? live}) =>
      reader.graph(path, liveHash: live == null ? null : sha(live));

  // -------------------------------------------------------------------------
  // Files arriving through sync: placed in the store externally.
  // -------------------------------------------------------------------------

  Future<void> putSnapshot(
    String path,
    String content, {
    required int ts,
    String by = 'other',
    String? renamedFrom,
  }) =>
      store.write(
        path,
        versionFileName(ts, HistFileType.snapshot),
        encodeVersionFile(
          version: sha(content),
          writer: by,
          renamedFrom: renamedFrom,
          body: utf8.encode(content),
        ),
      );

  /// A well-formed forward patch `prev → next` from the pinned dmp recipe.
  Future<void> putPatch(
    String path,
    String prev,
    String next, {
    required int ts,
    String by = 'other',
  }) =>
      putPatchRaw(path,
          prevHash: sha(prev),
          versionHash: sha(next),
          body: makePatchText(prev, next),
          ts: ts,
          by: by);

  /// A patch file with arbitrary (possibly corrupted) body.
  Future<void> putPatchRaw(
    String path, {
    required String prevHash,
    required String versionHash,
    required String body,
    required int ts,
    String by = 'other',
  }) =>
      store.write(
        path,
        versionFileName(ts, HistFileType.patch),
        encodeVersionFile(
          version: versionHash,
          prev: prevHash,
          writer: by,
          body: utf8.encode(body),
        ),
      );

  Future<void> putDeleted(
    String path, {
    required String prevHash,
    required int ts,
    String by = 'other',
    String? renamedTo,
  }) =>
      store.write(
        path,
        versionFileName(ts, HistFileType.deleted),
        encodeVersionFile(prev: prevHash, writer: by, renamedTo: renamedTo),
      );
}
