/// `vault_hist.tests` — "Diff and blame" (R4, R5).
library;

import 'package:entropy_hist/entropy_hist.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  group('Diff and blame (R4, R5)', () {
    test('the line diff runs in line mode and keeps lines whole', () {
      final edits = lineDiff('one\ntwo\nthree\n', 'uno\ntwo\nthree\nfour');
      expect(edits.map((e) => (e.op, e.lines.join('|'))), [
        (LineOp.delete, 'one\n'),
        (LineOp.insert, 'uno\n'),
        (LineOp.equal, 'two\n|three\n'),
        (LineOp.insert, 'four'),
      ]);
      expect(lineDiff('same\n', 'same\n').single.op, LineOp.equal);
      expect(splitLines(''), isEmpty);
      expect(splitLines('a\nb'), ['a\n', 'b']);
    });

    test(
        'a diff is a unified rendering over verified content, correct '
        'across a checkpoint', () async {
      final h = Harness();
      const a = 'one\ntwo\n';
      const b = 'one\ntwo\nthree\n';
      const c = 'uno\ntwo\nthree\n';
      await h.putSnapshot('f.md', a, ts: 1000);
      await h.putPatchRaw('f.md',
          prevHash: sha(a), versionHash: sha(b), body: 'GARBAGE', ts: 2000);
      await h.putSnapshot('f.md', b, ts: 3000); // the checkpoint
      await h.putPatch('f.md', b, c, ts: 4000);

      Future<String> diffOf(String x, String y) async => unifiedDiff(
            await h.materializeText('f.md', sha(x)),
            await h.materializeText('f.md', sha(y)),
            labelA: 'a/f.md (${sha(x).substring(0, 12)})',
            labelB: 'b/f.md (${sha(y).substring(0, 12)})',
          );

      expect(
        await diffOf(b, c),
        '--- a/f.md (${sha(b).substring(0, 12)})\n'
        '+++ b/f.md (${sha(c).substring(0, 12)})\n'
        '@@ -1,3 +1,3 @@\n'
        '-one\n'
        '+uno\n'
        ' two\n'
        ' three\n',
        reason: 'B reconstructed from the checkpoint, untouched by the '
            'corrupted patch',
      );
      expect(
        await diffOf(a, c),
        contains('@@ -1,2 +1,3 @@\n-one\n+uno\n two\n+three\n'),
      );
      expect(await diffOf(c, c), isEmpty, reason: 'identical: no hunks');
    });

    test(
        'a unified diff handles context, several hunks and a missing '
        'final newline', () {
      final a = List.generate(20, (i) => 'line $i\n').join();
      final b = a
          .replaceFirst('line 2\n', 'LINE 2\n')
          .replaceFirst('line 19\n', 'LINE 19'); // the last line, no newline
      final diff = unifiedDiff(a, b, labelA: 'x', labelB: 'y');
      expect(diff, startsWith('--- x\n+++ y\n'));
      expect(diff,
          contains('@@ -1,6 +1,6 @@\n line 0\n line 1\n-line 2\n+LINE 2\n'));
      expect(
          diff,
          contains('@@ -17,4 +17,4 @@\n line 16\n line 17\n line 18\n'
              '-line 19\n+LINE 19\n\\ No newline at end of file\n'));
    });

    test(
        'blame attributes every line to the version and writer that '
        'introduced it', () async {
      final h = Harness();
      const v1 = 'one\ntwo\n';
      const v2 = 'one\ntwo\nthree\n';
      const v3 = 'uno\ntwo\nthree\n';
      await h.putSnapshot('f.md', v1, ts: 1000, by: 'laptop');
      await h.putPatch('f.md', v1, v2, ts: 2000, by: 'phone');
      await h.putPatch('f.md', v2, v3, ts: 3000, by: 'laptop');
      final graph = await h.graph('f.md', live: v3);

      final lines = await blame(h.reader, graph, 'f.md', sha(v3));
      expect(lines.map((l) => (l.text, l.hash, l.writers.single)), [
        ('uno\n', sha(v3), 'laptop'),
        ('two\n', sha(v1), 'laptop'),
        ('three\n', sha(v2), 'phone'),
      ]);
      expect(lines.map((l) => l.timestampMillis), [3000, 1000, 2000]);

      final earlier = await blame(h.reader, graph, 'f.md', sha(v2));
      expect(earlier.map((l) => l.hash), [sha(v1), sha(v1), sha(v2)],
          reason: 'attribution is carried forward through every step');
    });

    test('blame is broken when any step of the chain fails verification',
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
      final graph = await h.graph('f.md', live: b);
      await expectLater(blame(h.reader, graph, 'f.md', sha(b)),
          throwsA(isA<BrokenVersion>()));
    });
  });
}
