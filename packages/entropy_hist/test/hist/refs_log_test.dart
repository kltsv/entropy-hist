/// `vault_hist.tests` — "Addressing, log, show" (R1–R3).
library;

import 'dart:convert';

import 'package:entropy_hist/entropy_hist.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  group('Addressing, log, show (R1–R3)', () {
    test('a version is addressable by hash, prefix, HEAD, HEAD~n and date',
        () async {
      final h = Harness();
      await h.putSnapshot('f.md', 'A', ts: 1000);
      await h.putPatch('f.md', 'A', 'B', ts: 2000);
      await h.putPatch('f.md', 'B', 'C', ts: 3000);
      final graph = await h.graph('f.md', live: 'C');

      expect(resolveRef(graph, sha('B')), sha('B'));
      expect(resolveRef(graph, sha('B').substring(0, 8)), sha('B'));
      expect(resolveRef(graph, 'HEAD'), sha('C'));
      expect(resolveRef(graph, 'HEAD~1'), sha('B'));
      expect(resolveRef(graph, 'HEAD~2'), sha('A'));
      final at = DateTime.fromMillisecondsSinceEpoch(2500).toIso8601String();
      expect(resolveRef(graph, '@{$at}'), sha('B'),
          reason: 'the primary-line version live at that instant');
      expect(await h.reader.resolve('f.md', 'HEAD~1', liveHash: sha('C')),
          sha('B'));
    });

    test(
        'an ambiguous prefix is an error naming the candidates, never a '
        'guess', () async {
      final h = Harness();
      final (x, y) = _sharingPrefix(5);
      await h.putSnapshot('f.md', x, ts: 1000);
      await h.putSnapshot('f.md', y, ts: 2000);
      await h.putPatch('f.md', y, 'Z', ts: 3000);
      final graph = await h.graph('f.md', live: 'Z');

      final ambiguous = throwsA(isA<HistRefError>().having((e) => e.candidates,
          'candidates', unorderedEquals([sha(x), sha(y)])));
      expect(() => resolveRef(graph, sha(x).substring(0, 5)), ambiguous);
      expect(
          () => resolveRef(graph, 'abc'),
          throwsA(isA<HistRefError>()
              .having((e) => e.message, 'message', contains('too short'))));
      expect(
          () => resolveRef(graph, 'HEAD~9'),
          throwsA(isA<HistRefError>().having(
              (e) => e.message, 'message', contains('only 2 version'))));
      expect(
          () => resolveRef(graph, 'ffffffff'),
          throwsA(isA<HistRefError>().having(
              (e) => e.message, 'message', contains('no version matches'))));
    });

    test('HEAD is an error when there is no live version', () async {
      final h = Harness();
      await h.putSnapshot('f.md', 'A', ts: 1000);
      await h.putPatch('f.md', 'A', 'B', ts: 2000);

      final unsaved = await h.graph('f.md', live: 'Z');
      expect(
          () => resolveRef(unsaved, 'HEAD'),
          throwsA(isA<HistRefError>().having((e) => e.message, 'message',
              contains('unsaved changes after ${sha('B')}'))));

      final absent = await h.reader.graph('f.md');
      expect(
          () => resolveRef(absent, 'HEAD'),
          throwsA(isA<HistRefError>().having(
              (e) => e.message, 'message', contains('no live version'))));
      expect(resolveRef(absent, sha('B').substring(0, 6)), sha('B'),
          reason: 'a prefix still resolves');
    });

    test(
        'the log lists the primary line newest first and marks the live '
        'entry', () async {
      final h = Harness();
      await h.putSnapshot('f.md', 'A', ts: 1000, by: 'laptop');
      await h.putPatch('f.md', 'A', 'B', ts: 2000, by: 'phone');
      await h.putPatch('f.md', 'B', 'C', ts: 3000, by: 'laptop');
      // A third device's line: a writer the primary line does not have, so
      // the branch is somebody else's work — divergent, not archived.
      await h.putPatch('f.md', 'A', 'X', ts: 2500, by: 'tablet');
      final graph = await h.graph('f.md', live: 'C');

      final plain = logOf(graph, path: 'f.md');
      expect(plain.entries.map((e) => e.hash), [sha('C'), sha('B'), sha('A')]);
      expect(plain.entries.map((e) => e.isLive), [true, false, false]);
      expect(plain.entries.map((e) => e.writers.single),
          ['laptop', 'phone', 'laptop']);
      expect(plain.entries.map((e) => e.timestampMillis), [3000, 2000, 1000]);
      expect(plain.branches, isEmpty);
      expect(plain.hasPrimaryLine, isTrue);

      final all = logOf(graph, path: 'f.md', all: true);
      expect(all.entries.map((e) => e.hash),
          [sha('C'), sha('B'), sha('A'), sha('X')]);
      final branch = all.branches.single;
      expect(branch.leaf, sha('X'));
      expect(branch.kind, HistBranchKind.divergent);
      expect(branch.writers, ['tablet']);

      final filtered = all.where(author: 'tablet', sinceMillis: 2200, limit: 5);
      expect(filtered.entries.map((e) => e.hash), [sha('X')]);
      expect(all.where(author: 'phone').entries.map((e) => e.hash), [sha('B')]);
      expect(all.where(limit: 1).entries.map((e) => e.hash), [sha('C')]);
    });

    test('a file with no live version lists every line as a branch', () async {
      final h = Harness();
      await h.putSnapshot('todo.md', 'X', ts: 1000);
      await h.putPatch('todo.md', 'X', 'X2', ts: 2000);
      await h.putDeleted('todo.md', prevHash: sha('X2'), ts: 3000);

      final log = logOf(await h.reader.graph('todo.md'), path: 'todo.md');
      expect(log.hasPrimaryLine, isFalse);
      expect(log.entries.map((e) => e.hash), [sha('X2'), sha('X')]);
      expect(log.branches.single.kind, HistBranchKind.archived);
      expect(log.branches.single.endedAtMillis, 3000);
    });

    test('show reconstructs the addressed version or reports it broken',
        () async {
      final h = Harness();
      const a = 'The quick brown fox jumps.\n';
      const b = 'The quick red fox jumps.\n';
      await h.putSnapshot('f.md', a, ts: 1000);
      await h.putPatchRaw('f.md',
          prevHash: sha(a),
          versionHash: sha(b),
          body: makePatchText(a, b).replaceAll('red', 'rad'),
          ts: 2000);

      final older = await h.reader.resolve('f.md', 'HEAD~1', liveHash: sha(b));
      expect(await h.reader.materialize('f.md', older), utf8.encode(a));
      final head = await h.reader.resolve('f.md', 'HEAD', liveHash: sha(b));
      await expectLater(
          h.reader.materialize('f.md', head), throwsA(isA<BrokenVersion>()));
    });
  });
}

(String, String) _sharingPrefix(int n) {
  final seen = <String, String>{};
  for (var i = 0;; i++) {
    final text = 'candidate $i\n';
    final prefix = sha(text).substring(0, n);
    final other = seen[prefix];
    if (other != null) return (other, text);
    seen[prefix] = text;
  }
}
