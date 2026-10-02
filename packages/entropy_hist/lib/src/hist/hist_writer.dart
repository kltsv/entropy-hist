import 'dart:convert';
import 'dart:typed_data';

import 'hist_format.dart';
import 'hist_reader.dart';
import 'hist_store.dart';

/// The `vault_hist` writer (RV5, RV6): records **only this client's own
/// local edits** as append-only immutable version files. Changes that arrive
/// through sync are never recorded by the receiver — the source already
/// recorded them; `remoteApplied` merely rebases the baseline. There is no
/// single writer and no coordination: immutable uniquely-named files linked
/// by content hash make any interleaving of writers safe by construction.
class HistWriter {
  HistWriter({
    required this.store,
    required this.now,
    List<String> extensions = const ['.md'],
    required this.writerName,
    this.snapshotEvery = 200,
  })  : extensions = [for (final e in extensions) e.toLowerCase()],
        _reader = HistReader(store);

  final HistStore store;

  /// Used to recover a base's bytes from the graph when the caller does not
  /// supply them — the same verified reconstruction any reader performs.
  final HistReader _reader;

  /// Injected clock (UTC epoch ms), for testability (`vault_hist`).
  final int Function() now;

  /// Tracked extensions (lowercase, with the dot), or the single entry `*`
  /// for any file whose content is text. Paths outside the list are never
  /// versioned; binaries never are either way, because content decides
  /// (`vault_hist` RV5).
  final List<String> extensions;

  /// This client's identity in `writer:` headers (`vault_hist` RV6).
  final String writerName;

  /// Snapshot-checkpoint interval: once the patch chain from the nearest
  /// snapshot ancestor reaches this length, the next version is recorded as
  /// a `snapshot` instead of a `patch` — same file type, no new mechanism,
  /// it just shortens reconstruction (`vault_hist` RV5).
  final int snapshotEvery;

  /// The mirror folder name; paths under it are excluded from tracking —
  /// no history-of-history, even though the shell syncs the mirror like any
  /// other files (`vault_hist` RV8).
  static const String mirrorRoot = '.hist';

  /// Record [content] as the next version of [path] — the module's only
  /// write verb (`vault_hist`).
  ///
  /// **When** to call this is the caller's decision, never this module's:
  /// there is no debounce and no timer here. Editors save by writing a
  /// temporary file and renaming it, or by deleting and recreating; a caller
  /// that forwards those raw events verbatim gets exactly that recorded — a
  /// deletion and a new life per save. The daemon coalesces events into one
  /// settled state per edit first (`vault_daemon`, D7).
  ///
  /// Nothing is remembered between calls. The base is **recovered**: from
  /// [previous] when the caller can produce the bytes, else from
  /// [previousHash] when it can name the version (reconstructed from the
  /// graph), else from the graph when exactly one line is open, else there
  /// is no base and [content] is recorded as a root snapshot — a patch needs
  /// the base's bytes, and inventing one reconstructs to garbage. The
  /// caller's word wins over the graph's guess: after a rollback the one
  /// open leaf is the abandoned state (`vault_hist` — commit rules).
  ///
  /// [at] stamps the version with the moment the edit happened (the filename
  /// is for humans and sorting only); it defaults to now.
  ///
  /// Returns whether anything was written. A commit of the state already
  /// recorded writes nothing, so calling twice costs nothing.
  Future<bool> commit(
    String path,
    List<int>? content, {
    List<int>? previous,
    String? previousHash,
    int? at,
  }) async {
    if (!tracks(path)) return false;
    Uint8List? bytes;
    if (content != null) {
      bytes = Uint8List.fromList(content);
      // Binary content is never versioned (dmp is text-only).
      if (decodeUtf8Text(bytes) == null) return false;
    }
    // Stamped when the edit happened, not when the caller got around to
    // committing it — the caller owns the timing, so it owns the time too.
    return _record(path, bytes,
        previous: previous, previousHash: previousHash, ts: at ?? now());
  }

  /// Record that the branch ending at [branchLeaf] has been reconciled into
  /// the version [into] (`vault_hist` RV6).
  ///
  /// This writes a **marker only**. The reconciled content is committed
  /// separately as an ordinary single-parent version, so no record ever
  /// declares two parents: reconstruction stays one hash-verified chain and
  /// history files stay conflict-free in sync. The branch itself is left
  /// byte-for-byte as it was — still readable, no longer open.
  Future<void> merge(String path, String branchLeaf, String into) async {
    if (!tracks(path)) return;
    await _writeFile(
      path,
      now(),
      HistFileType.merged,
      encodeVersionFile(merged: branchLeaf, into: into, writer: writerName),
    );
  }

  /// The base for the next commit, or null when there is none to diff from.
  ///
  /// Explicit [previous] bytes win; then a [previousHash] the folder holds,
  /// reconstructed; otherwise the folder is consulted, and only an
  /// **unambiguous** answer is accepted — exactly one open leaf. Where
  /// several lines are open the caller must say which one it edited;
  /// guessing by filename would let a skewed clock pick the base
  /// (`vault_hist` RV5).
  Future<Baseline?> _recoverBase(
      String path, List<int>? previous, String? previousHash) async {
    if (previous != null) {
      final bytes = Uint8List.fromList(previous);
      if (decodeUtf8Text(bytes) != null) {
        return Baseline(sha256Hex(bytes), bytes);
      }
    }
    final headers = await store.listHeaders(path);
    if (previousHash != null) {
      // A hash the folder does not hold is no base at all — never a fall
      // through to a guess the caller has just contradicted.
      if (!_recordedVersions(headers).contains(previousHash)) return null;
      return _materializedBase(path, previousHash);
    }
    final leaves = _openLeaves(headers);
    if (leaves.length != 1) return null;
    return _materializedBase(path, leaves.single);
  }

  Future<Baseline?> _materializedBase(String path, String hash) async {
    try {
      return Baseline(hash, await _reader.materialize(path, hash));
    } on BrokenVersion {
      return null;
    }
  }

  /// Recorded versions with no outgoing patch, no `deleted` marker and no
  /// `merged` marker naming them — the open ends of the graph. A settled
  /// branch is not open (`vault_hist` RV6). More than one means the lines
  /// diverged and the caller must say which it edited; zero means there is
  /// nothing live here.
  List<String> _openLeaves(List<HistFileHeader> headers) {
    final versions = <String>{};
    final withOutgoing = <String>{};
    final deleted = <String>{};
    final merged = <String>{};
    for (final h in headers) {
      switch (h.type) {
        case HistFileType.snapshot:
          if (h.version != null) versions.add(h.version!);
        case HistFileType.patch:
          if (h.version != null) versions.add(h.version!);
          if (h.prev != null) withOutgoing.add(h.prev!);
        case HistFileType.deleted:
          if (h.prev != null) deleted.add(h.prev!);
        case HistFileType.merged:
          if (h.merged != null) merged.add(h.merged!);
        case HistFileType.conflict:
          break;
      }
    }
    return [
      for (final v in versions)
        if (!withOutgoing.contains(v) &&
            !deleted.contains(v) &&
            !merged.contains(v))
          v,
    ];
  }

  /// A rename the shell detected (`vault_hist` RV7): a `deleted` marker
  /// with `renamed_to` into the old folder and a `snapshot` with
  /// `renamed_from` into the new one — **no folder ever moves** (a moved
  /// folder would resurrect from other replicas). The old folder is anchored
  /// first when [content]'s hash is not recorded there yet, so the marker's
  /// `prev` resolves; the new folder's snapshot is skipped when the hash is
  /// already a root there.
  Future<void> recordRename(
      String oldPath, String newPath, List<int> content) async {
    if (!tracks(oldPath) || !tracks(newPath)) return;
    final bytes = Uint8List.fromList(content);
    if (decodeUtf8Text(bytes) == null) return;
    final hash = sha256Hex(bytes);
    final ts = now();

    var wantTs = ts;
    final oldHeaders = await store.listHeaders(oldPath);
    if (!_recordedVersions(oldHeaders).contains(hash)) {
      final anchorTs = await _writeFile(
        oldPath,
        wantTs,
        HistFileType.snapshot,
        encodeVersionFile(version: hash, writer: writerName, body: bytes),
      );
      wantTs = anchorTs + 1; // the marker must sort after its anchor
    }
    await _writeFile(
      oldPath,
      wantTs,
      HistFileType.deleted,
      encodeVersionFile(prev: hash, writer: writerName, renamedTo: newPath),
    );

    final newHeaders = await store.listHeaders(newPath);
    final alreadyRoot = newHeaders
        .any((h) => h.type == HistFileType.snapshot && h.version == hash);
    if (!alreadyRoot) {
      await _writeFile(
        newPath,
        ts,
        HistFileType.snapshot,
        encodeVersionFile(
          version: hash,
          writer: writerName,
          renamedFrom: oldPath,
          body: bytes,
        ),
      );
    }
  }

  /// Rescues the losing **binary** version of a sync conflict whole into a
  /// `conflict` file — otherwise it would be gone forever; a losing text
  /// version needs nothing, its author already recorded it (`vault_hist`
  /// RV9). Ignores the extension filter — this is the one history
  /// appearance a binary can have.
  Future<void> recordBinaryConflictLoser(String path, List<int> bytes) async {
    if (_underMirror(path)) return; // no history-of-history, ever (RV8)
    final copy = Uint8List.fromList(bytes);
    await _writeFile(
      path,
      now(),
      HistFileType.conflict,
      encodeVersionFile(
          version: sha256Hex(copy), writer: writerName, body: copy),
    );
  }

  // ---------------------------------------------------------------------------
  // Flush — the `vault_hist` writer rules (RV5, RV6)
  // ---------------------------------------------------------------------------

  /// Compares `baseline (a)` → `pending (b)` and records per the flush table
  /// of `vault_hist`; returns whether any file was written.
  Future<bool> _record(
    String path,
    Uint8List? content, {
    List<int>? previous,
    String? previousHash,
    required int ts,
  }) async {
    final baseline = await _recoverBase(path, previous, previousHash);

    if (content == null) {
      // `a → absent`: a mandatory `deleted` marker with `prev`; the folder
      // is preserved for recovery (R15). `absent → absent`: nothing.
      if (baseline == null) return false;
      await _writeFile(
        path,
        ts,
        HistFileType.deleted,
        encodeVersionFile(prev: baseline.hash, writer: writerName),
      );
      return true;
    }

    final hash = sha256Hex(content);
    // `a → b`, same hash: dedup, record nothing.
    if (baseline != null && baseline.hash == hash) return false;

    final headers = await store.listHeaders(path);
    final recorded = _recordedVersions(headers);

    // `b`'s hash already in the folder: a rollback/restore to a known
    // version — writing an edge would point backward and create a cycle.
    // The baseline just moves; "current" is the live file's pointer (RV5).
    if (recorded.contains(hash)) return false;

    // `absent → w` with an unknown hash: a recreation is a new life — a new
    // root snapshot in the same folder (RV5).
    if (baseline == null) {
      await _writeFile(
        path,
        ts,
        HistFileType.snapshot,
        encodeVersionFile(version: hash, writer: writerName, body: content),
      );
      return true;
    }

    // `a → b`, otherwise — the anchor rule: if `a` is not in the folder,
    // snapshot it first. Covers the first-ever version, files that predate
    // history, and a new writer whose history has not arrived yet (RV5).
    final baseText = decodeUtf8Text(baseline.content);
    final nextText = decodeUtf8Text(content)!;
    var anchored = false;
    var wantTs = ts;
    if (!recorded.contains(baseline.hash)) {
      if (baseText == null) {
        // Defensive: an undecodable baseline cannot anchor or serve as a
        // diff base — start a new root at the current state instead.
        await _writeFile(
          path,
          ts,
          HistFileType.snapshot,
          encodeVersionFile(version: hash, writer: writerName, body: content),
        );
        return true;
      }
      final anchorTs = await _writeFile(
        path,
        wantTs,
        HistFileType.snapshot,
        encodeVersionFile(
          version: baseline.hash,
          writer: writerName,
          body: baseline.content,
        ),
      );
      // The patch must sort after its anchor snapshot (filenames of
      // different types never collide, so bump explicitly).
      wantTs = anchorTs + 1;
      anchored = true;
    }

    // Snapshot checkpoint: a chain at [snapshotEvery] records this version
    // whole instead of as a patch (RV5).
    final chain = anchored ? 0 : _chainLength(headers, baseline.hash);
    if (chain >= snapshotEvery || baseText == null) {
      await _writeFile(
        path,
        wantTs,
        HistFileType.snapshot,
        encodeVersionFile(version: hash, writer: writerName, body: content),
      );
    } else {
      // Forward patch `prev → version` from the pinned dmp recipe (C5, RV5).
      await _writeFile(
        path,
        wantTs,
        HistFileType.patch,
        encodeVersionFile(
          version: hash,
          prev: baseline.hash,
          writer: writerName,
          body: utf8.encode(makePatchText(baseText, nextText)),
        ),
      );
    }
    return true;
  }

  /// Version hashes recorded in the folder — the states the graph knows
  /// (`snapshot` and `patch` files; `deleted` markers add no state and
  /// `conflict` rescues are not graph nodes).
  Set<String> _recordedVersions(List<HistFileHeader> headers) => {
        for (final h in headers)
          if ((h.type == HistFileType.snapshot ||
                  h.type == HistFileType.patch) &&
              h.version != null)
            h.version!,
      };

  /// Patch-chain length from the nearest snapshot ancestor to [hash].
  int _chainLength(List<HistFileHeader> headers, String hash) {
    final snapshots = <String>{
      for (final h in headers)
        if (h.type == HistFileType.snapshot && h.version != null) h.version!,
    };
    final prevByVersion = <String, String>{};
    for (final h in headers) {
      if (h.type == HistFileType.patch && h.version != null && h.prev != null) {
        prevByVersion.putIfAbsent(h.version!, () => h.prev!);
      }
    }
    var steps = 0;
    var cur = hash;
    final seen = <String>{};
    while (!snapshots.contains(cur)) {
      if (!seen.add(cur)) break;
      final prev = prevByVersion[cur];
      if (prev == null) break;
      cur = prev;
      steps++;
    }
    return steps;
  }

  /// Writes one immutable version file, bumping the millisecond value until
  /// the name is free (`vault_hist` RV5 — names must be unique, nothing
  /// more; identity stays in the hash headers). Returns the millisecond
  /// value actually used.
  Future<int> _writeFile(
      String path, int wantMillis, HistFileType type, List<int> bytes) async {
    var ms = wantMillis;
    while (true) {
      try {
        await store.write(path, versionFileName(ms, type), bytes);
        return ms;
      } on HistFileExists {
        ms += 1;
      }
    }
  }

  bool _underMirror(String path) =>
      path == mirrorRoot || path.startsWith('$mirrorRoot/');

  /// Whether this writer would version [path]: not under the mirror (RV8)
  /// and the last dot-suffix is in [extensions], compared case-insensitively
  /// (`vault_hist` RV5). Content still decides in the end — a commit of
  /// non-UTF-8 bytes records nothing.
  bool tracks(String path) {
    if (_underMirror(path)) return false;
    // `*` means "any file whose content is text". Content is already the real
    // filter — a commit of non-UTF-8 bytes records nothing whatever the file
    // is called — so the wildcard only stops the *name* being a second,
    // weaker one. Extensionless files are tracked under it, and only under it
    // (`vault_hist`).
    if (extensions.contains('*')) return true;
    final base = path.substring(path.lastIndexOf('/') + 1);
    final dot = base.lastIndexOf('.');
    if (dot < 0) return false;
    return extensions.contains(base.substring(dot).toLowerCase());
  }
}

/// The base a commit diffs from — a version's hash and its bytes.
///
/// Recovered per call and discarded: nothing about a path survives between
/// commits, which is what makes an explicit commit verb safe to replay
/// (`vault_hist`).
class Baseline {
  Baseline(this.hash, this.content);

  /// Lowercase-hex sha256 of [content].
  final String hash;

  final Uint8List content;
}
