/// `vault_hist.tests` — "Writer — anchors and lifecycle" (RV5, RV6).
library;

import 'dart:convert';
import 'dart:io';

import 'package:entropy_hist/entropy_hist.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  group('Writer — anchors and lifecycle (RV5, RV6)', () {
    test('the first version of a new file is a root snapshot', () async {
      final h = Harness();
      await h.record('notes/foo.md', 'A');

      final headers = await h.headers('notes/foo.md');
      expect(headers, hasLength(1));
      expect(headers.single.type, HistFileType.snapshot);
      expect(headers.single.version, sha('A'));
      expect(headers.single.prev, isNull, reason: 'a root has no prev');
      expect(await h.body('notes/foo.md', headers.single.filename), 'A');
    });

    test('an edit on a recorded baseline writes a single patch', () async {
      final h = Harness();
      await h.record('notes/foo.md', 'A');
      await h.record('notes/foo.md', 'AB');

      final headers = await h.headers('notes/foo.md');
      expect(headers.map((x) => x.type),
          [HistFileType.snapshot, HistFileType.patch],
          reason: 'no additional snapshot — the anchor rule does not fire '
              'because sha(A) is already in the folder');
      expect(headers.last.prev, sha('A'));
      expect(headers.last.version, sha('AB'));
    });

    test(
        'first encounter sets the baseline and records nothing; '
        'the first edit anchors it', () async {
      final h = Harness();
      // The file predates history: nothing was ever committed for it, but the
      // caller can still produce its previous bytes.
      h.adopt('pre.md', 'old');
      expect(await h.names('pre.md'), isEmpty,
          reason: 'adopting a state records nothing');

      await h.record('pre.md', 'new');

      final headers = await h.headers('pre.md');
      expect(headers, hasLength(2),
          reason: 'the anchor rule fires — sha(old) was absent from the '
              'folder');
      expect(headers[0].type, HistFileType.snapshot);
      expect(headers[0].version, sha('old'));
      expect(await h.body('pre.md', headers[0].filename), 'old',
          reason: 'the pre-history content is preserved whole');
      expect(headers[1].type, HistFileType.patch);
      expect(headers[1].prev, sha('old'));
      expect(headers[1].version, sha('new'));
    });

    test(
        'a new writer whose history has not arrived anchors with its own '
        'snapshot', () async {
      final h = Harness(writerName: 'phone');
      // Baseline set when sync delivered the file; the folder is empty.
      h.adopt('f.md', 'A');
      await h.record('f.md', 'B');

      final headers = await h.headers('f.md');
      expect(
          headers.map((x) => (x.type, x.version, x.writer)),
          [
            (HistFileType.snapshot, sha('A'), 'phone'),
            (HistFileType.patch, sha('B'), 'phone'),
          ],
          reason: 'the anchor rule covers a writer that cannot see history '
              'yet');

      // Later, the first device's own snapshot(A) arrives through sync.
      await h.putSnapshot('f.md', 'A', ts: 1690000000000, by: 'laptop');
      final graph = await h.graph('f.md', live: 'B');
      expect(graph.roots, [sha('A')],
          reason: 'two snapshot files declare the same version — redundant '
              'snapshots dedup by version into a single root node');
    });

    test(
        'deletion writes a mandatory deleted marker and preserves the '
        'folder (R15)', () async {
      final h = Harness();
      await h.record('todo.md', 'X');
      await h.record('todo.md', 'X2');
      final before = await h.capture('todo.md');

      await h.record('todo.md', null);

      final headers = await h.headers('todo.md');
      expect(headers, hasLength(before.length + 1));
      final marker = headers.last;
      expect(marker.type, HistFileType.deleted);
      expect(marker.prev, sha('X2'),
          reason: 'the marker tells the reader which leaf was live');
      expect(marker.writer, 'laptop');
      expect(bodyOf(await h.bytes('todo.md', marker.filename)), isEmpty,
          reason: 'a deleted marker has no body');
      for (final entry in before.entries) {
        expect(await h.bytes('todo.md', entry.key), entry.value,
            reason: 'every earlier file is kept intact, so the file is '
                'recoverable after deletion');
      }
    });

    test('recreation with an unknown hash starts a new root', () async {
      final h = Harness();
      await h.record('todo.md', 'X');
      await h.record('todo.md', null);
      final before = await h.names('todo.md');

      await h.record('todo.md', 'Y');

      final headers = await h.headers('todo.md');
      final added = headers.where((x) => !before.contains(x.filename)).toList();
      expect(added, hasLength(1));
      expect(added.single.type, HistFileType.snapshot);
      expect(added.single.version, sha('Y'),
          reason: 'a new root in the same folder');
      expect([
        for (final x in headers)
          if (x.type == HistFileType.patch) x
      ], isEmpty,
          reason: 'no patch links the old life to Y — a diff across '
              'unrelated content would be a lie');
    });

    test('recreation with a known hash is a restore and records nothing',
        () async {
      final h = Harness();
      await h.record('todo.md', 'X');
      await h.record('todo.md', null);
      final before = await h.names('todo.md');

      await h.record('todo.md', 'X');

      expect(await h.names('todo.md'), before,
          reason: 'sha(X) already exists in the folder');
    });

    test(
        'a local edit racing an arrival is committed from the base it was '
        'made on', () async {
      final h = Harness();
      await h.record('f.md', 'A');
      final before = await h.names('f.md');

      h.local('f.md', 'B'); // a local save…
      h.clock.millis += 5000;
      await h.idle(); // …committed *before* the arrival is applied,
      h.adopt('f.md', 'C'); // and the winner itself is never committed

      final headers = await h.headers('f.md');
      final added = headers.where((x) => !before.contains(x.filename)).toList();
      expect(added, hasLength(1),
          reason: 'exactly one new file — nothing records C, its source '
              'already recorded it');
      expect(added.single.type, HistFileType.patch);
      expect(added.single.prev, sha('A'),
          reason: 'recorded from the base it was actually made on');
      expect(added.single.version, sha('B'),
          reason: 'the local edit survives as a divergent branch');
    });

    test('an arrival is never committed, and the next edit anchors on it',
        () async {
      final h = Harness();
      await h.record('f.md', 'A');
      final before = await h.names('f.md');

      h.adopt('f.md', 'C');
      expect(await h.names('f.md'), before,
          reason: 'an arrival writes no file');

      await h.record('f.md', 'D');

      final headers = await h.headers('f.md');
      final added = headers.where((x) => !before.contains(x.filename)).toList();
      expect(
          added.map((x) => (x.type, x.version, x.prev)),
          [
            (HistFileType.snapshot, sha('C'), null),
            (HistFileType.patch, sha('D'), sha('C')),
          ],
          reason: 'the later edit proves the rebase: the anchor rule wrote '
              'snapshot(C), and the edit diffs from C, not from A');
    });

    test('a long patch chain gets a snapshot checkpoint', () async {
      final h = Harness(snapshotEvery: 3);
      for (final v in ['v0', 'v1', 'v2', 'v3']) {
        await h.record('f.md', v);
      }
      expect((await h.headers('f.md')).map((x) => x.type), [
        HistFileType.snapshot,
        HistFileType.patch,
        HistFileType.patch,
        HistFileType.patch,
      ]);

      await h.record('f.md', 'v4');

      final checkpoint = (await h.headers('f.md')).last;
      expect(checkpoint.type, HistFileType.snapshot,
          reason: 'the chain reached the checkpoint interval — same '
              'ordinary snapshot type, no new mechanism');
      expect(checkpoint.version, sha('v4'));
      expect(await h.body('f.md', checkpoint.filename), 'v4',
          reason: 'the full content, not a patch');
      expect(await h.reader.materialize('f.md', sha('v4')), utf8.encode('v4'),
          reason: 'materialize reads it directly instead of replaying four '
              'patches');
    });

    test('an untracked extension is never versioned', () async {
      final vault = Directory.systemTemp.createTempSync('vault_hist_');
      addTearDown(() => vault.deleteSync(recursive: true));
      final h = Harness(store: FsHistStore(vault.path));

      await h.record('img/logo.png', 'not really a png');
      await h.record('img/logo.png', 'edited bytes');
      await h.record('img/logo.png', null);

      expect(
          Directory(p.join(vault.path, '.hist', 'img', 'logo.png'))
              .existsSync(),
          isFalse,
          reason: 'binaries get no diffs — their only possible history '
              'appearance is a conflict rescue copy');
    });

    test('the wildcard tracks any text file, and still never a binary',
        () async {
      final h = Harness(extensions: ['*']);

      await h.record('data/config.json', '{"a":1}');
      await h.record('notes/plain.txt', 'hello');
      await h.record('Makefile', 'all:\n\techo hi'); // no extension at all
      await h.commitNow('img/logo.png', [0x89, 0x50, 0x00, 0x47]);

      for (final path in ['data/config.json', 'notes/plain.txt', 'Makefile']) {
        final headers = await h.headers(path);
        expect(headers, hasLength(1), reason: '$path should be versioned');
        expect(headers.single.type, HistFileType.snapshot);
      }
      // Content is the real filter — the wildcard only stops the *name* being
      // a second, weaker one.
      expect(await h.headers('img/logo.png'), isEmpty);
    });

    test('invalid UTF-8 is never versioned', () async {
      final vault = Directory.systemTemp.createTempSync('vault_hist_');
      addTearDown(() => vault.deleteSync(recursive: true));
      final h = Harness(store: FsHistStore(vault.path));

      await h.commitNow('notes/x.md', [0x41, 0xc3, 0x28, 0x42]);
      await h.commitNow('notes/x.md', [0x41, 0x00, 0x42]); // NUL byte

      expect(Directory(p.join(vault.path, '.hist')).existsSync(), isFalse,
          reason: 'content must be valid UTF-8 despite the tracked .md '
              'extension — a file that is not valid UTF-8 is binary');
    });
  });
}
