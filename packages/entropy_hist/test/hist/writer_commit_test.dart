/// `vault_hist.tests` — "Writer — debounce and dedup" (D7, RV5).
library;

import 'package:entropy_hist/entropy_hist.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  group('Writer — debounce and dedup (D7, RV5)', () {
    test('an autosave burst folds into one version', () async {
      final h = Harness();
      h.local('notes/foo.md', 'd1');
      h.clock.millis += 1000;
      h.local('notes/foo.md', 'd2');
      h.clock.millis += 1000;
      h.local('notes/foo.md', 'final');
      await h.idle();

      final headers = await h.headers('notes/foo.md');
      expect(headers, hasLength(1),
          reason: 'only the final state of the window is evaluated');
      expect(headers.single.type, HistFileType.snapshot);
      expect(headers.single.version, sha('final'));
      expect(await h.body('notes/foo.md', headers.single.filename), 'final',
          reason: 'the intermediate states d1 and d2 are never recorded');
    });

    test('delete-plus-recreate inside the window is an ordinary edit',
        () async {
      final h = Harness();
      await h.record('notes/foo.md', 'A');
      final before = await h.names('notes/foo.md');

      h.local('notes/foo.md', null);
      h.clock.millis += 2000;
      h.local('notes/foo.md', 'AB');
      await h.idle();

      final after = await h.headers('notes/foo.md');
      expect(after, hasLength(before.length + 1),
          reason: 'exactly one new file — raw events are never recorded '
              'directly');
      final added = after.singleWhere((x) => !before.contains(x.filename));
      expect(added.type, HistFileType.patch);
      expect(added.prev, sha('A'));
      expect(added.version, sha('AB'));
      expect(after.map((x) => x.type), isNot(contains(HistFileType.deleted)),
          reason: 'no deleted marker for a tool saving by delete-then-write');
    });

    test('unchanged content records nothing', () async {
      final h = Harness();
      await h.record('notes/foo.md', 'A');
      final before = await h.names('notes/foo.md');

      await h.record('notes/foo.md', 'A');

      expect(await h.names('notes/foo.md'), before,
          reason: 'pending hashed equal to baseline, so the flush deduped');
    });

    test('rollback to a known version records nothing and moves the baseline',
        () async {
      final h = Harness();
      await h.record('f.md', 'A');
      await h.record('f.md', 'B');
      final before = await h.names('f.md');

      await h.record('f.md', 'A'); // the owner restored version A
      expect(await h.names('f.md'), before,
          reason: 'sha(A) already exists in the folder — nothing recorded');

      await h.record('f.md', 'E');
      final headers = await h.headers('f.md');
      final added = headers.where((x) => !before.contains(x.filename)).toList();
      expect(added, hasLength(1));
      expect(added.single.type, HistFileType.patch);
      expect(added.single.prev, sha('A'),
          reason: 'the next edit diffs from A — no anchor snapshot, sha(A) '
              'is present');
      expect(added.single.version, sha('E'));

      final edges = {
        for (final x in headers)
          if (x.type == HistFileType.patch) (x.prev, x.version),
      };
      expect(edges, {(sha('A'), sha('B')), (sha('A'), sha('E'))},
          reason: 'no edge points backward, no cycle enters the graph');
    });
  });
}
