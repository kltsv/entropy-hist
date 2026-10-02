/// `vault_hist.tests` — "Rename" (RV7).
library;

import 'dart:convert';

import 'package:entropy_hist/entropy_hist.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  group('Rename (RV7)', () {
    test('a detected rename writes linked markers and moves no folder',
        () async {
      final h = Harness();
      await h.record('doc/a.md', 'X');
      final before = await h.capture('doc/a.md');

      await h.writer.recordRename('doc/a.md', 'doc/b.md', utf8.encode('X'));

      final oldHeaders = await h.headers('doc/a.md');
      final marker = oldHeaders.last;
      expect(marker.type, HistFileType.deleted);
      expect(marker.prev, sha('X'));
      expect(marker.renamedTo, 'doc/b.md');
      expect(bodyOf(await h.bytes('doc/a.md', marker.filename)), isEmpty);

      final newHeaders = await h.headers('doc/b.md');
      expect(newHeaders, hasLength(1));
      expect(newHeaders.single.type, HistFileType.snapshot);
      expect(newHeaders.single.version, sha('X'));
      expect(newHeaders.single.renamedFrom, 'doc/a.md');
      expect(await h.body('doc/b.md', newHeaders.single.filename), 'X');

      for (final entry in before.entries) {
        expect(await h.bytes('doc/a.md', entry.key), entry.value,
            reason: 'the old folder still exists with every prior file '
                'intact — no folder is moved, a moved folder would '
                'resurrect from other replicas');
      }
    });

    test('an unrecognized rename degrades to delete plus create (R16)',
        () async {
      final h = Harness();
      await h.record('doc/a.md', 'X');
      final before = await h.capture('doc/a.md');

      h.local('doc/a.md', null);
      h.local('doc/c.md', 'X');
      await h.idle();

      final oldHeaders = await h.headers('doc/a.md');
      final marker = oldHeaders.last;
      expect(marker.type, HistFileType.deleted);
      expect(marker.prev, sha('X'));
      expect(marker.renamedTo, isNull,
          reason: 'a plain deleted marker — the shell did not recognize the '
              'rename');

      final newHeaders = await h.headers('doc/c.md');
      expect(newHeaders, hasLength(1));
      expect(newHeaders.single.type, HistFileType.snapshot);
      expect(newHeaders.single.version, sha('X'));
      expect(newHeaders.single.renamedFrom, isNull);

      for (final entry in before.entries) {
        expect(await h.bytes('doc/a.md', entry.key), entry.value,
            reason: 'the old history stays intact under the old name, '
                'merely without the link — nothing is lost');
      }
    });
  });
}
