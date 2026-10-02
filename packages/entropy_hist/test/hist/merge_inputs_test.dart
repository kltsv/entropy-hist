/// `vault_hist.tests` — "Reconciliation inputs: fork point and diff3"
/// (R9', R9'', R10).
library;

import 'package:entropy_hist/entropy_hist.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  group('Reconciliation inputs (R9\', R9\'\', R10)', () {
    test(
        'the fork point is the branch\'s nearest ancestor on the primary '
        'line', () async {
      final h = Harness();
      await h.putSnapshot('plan.md', 'A', ts: 1000, by: 'laptop');
      await h.putPatch('plan.md', 'A', 'B', ts: 2000, by: 'laptop');
      await h.putPatch('plan.md', 'B', 'C', ts: 3000, by: 'laptop');
      await h.putPatch('plan.md', 'B', 'D', ts: 2500, by: 'phone');
      await h.putPatch('plan.md', 'D', 'D2', ts: 2600, by: 'phone');
      await h.putSnapshot('plan.md', 'Q', ts: 4000, by: 'tablet');
      final graph = await h.graph('plan.md', live: 'C');

      expect(forkPoint(graph, sha('D2')), sha('B'));
      expect(forkPoint(graph, sha('D')), sha('B'));
      expect(forkPoint(graph, sha('Q')), isNull,
          reason: 'unrelated roots have no common ancestor');
      expect(forkPoint(graph, sha('nowhere')), isNull);
    });

    test(
        'diff3 takes each side\'s untouched-by-the-other change and flags '
        'the overlap', () {
      const a = 'one\ntwo\nthree\n';
      const l = 'one\ntwo changed here\nthree\n';
      const b = 'one\ntwo changed there\nthree\nfour\n';

      final conflicted = diff3(a, l, b, labelTheirs: 'branch d0d0');
      expect(conflicted.conflicts, 1);
      expect(
        conflicted.text,
        'one\n'
        '<<<<<<< live\n'
        'two changed here\n'
        '||||||| base\n'
        'two\n'
        '=======\n'
        'two changed there\n'
        '>>>>>>> branch d0d0\n'
        'three\n'
        'four\n',
        reason: '"four" merged cleanly; the second line is a region',
      );
      expect(hasConflictRegion(conflicted.text), isTrue);

      const l2 = 'ONE\ntwo\nthree\n';
      const b2 = 'one\ntwo\nthree\nfour\n';
      final clean = diff3(a, l2, b2);
      expect(clean.conflicts, 0);
      expect(clean.text, 'ONE\ntwo\nthree\nfour\n',
          reason: 'each side changed what the other left alone');
      expect(hasConflictRegion(clean.text), isFalse);

      final identical = diff3(a, l, l);
      expect(identical.conflicts, 0);
      expect(identical.text, l, reason: 'identical changes are one change');

      final oursOnly = diff3(a, l, a);
      expect(oursOnly.text, l);
      final theirsOnly = diff3(a, a, b);
      expect(theirsOnly.text, b);
    });

    test(
        'touching changes conflict rather than being guessed apart, and a '
        'lone ======= is not a marker', () {
      const a = 'one\ntwo\nthree\nfour\n';
      final touching =
          diff3(a, 'one\nTWO\nthree\nfour\n', 'one\ntwo\nTHREE\nfour\n');
      expect(touching.conflicts, 1,
          reason: 'adjacent lines changed by different sides touch');
      expect(touching.text, contains('<<<<<<< live\nTWO\nthree\n'));
      expect(touching.text, contains('=======\ntwo\nTHREE\n>>>>>>> branch\n'));

      expect(hasConflictRegion('Title\n=======\nbody\n'), isFalse);

      // A final line without a newline never glues to a marker.
      final tail = diff3('x\n', 'x\nours', 'x\ntheirs');
      expect(
          tail.text, contains('ours\n||||||| base\n=======\ntheirs\n>>>>>>>'));
    });
  });
}
