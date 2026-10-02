/// `vault_hist.tests` — "Noticing a divergence" (R16, R18).
library;

import 'dart:convert';
import 'dart:io';

import 'package:entropy_hist/entropy_hist.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  group('Noticing a divergence (R16, R18)', () {
    test('listing headers reads a prefix of each file, never the whole',
        () async {
      final tmp = Directory.systemTemp.createTempSync('hist-prefix');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final store = FsHistStore(tmp.path);
      final big = 'x' * (2 << 20); // two megabytes
      await store.write(
        'f.md',
        versionFileName(1000, HistFileType.snapshot),
        encodeVersionFile(
            version: sha(big), writer: 'laptop', body: utf8.encode(big)),
      );
      await store.write(
        'f.md',
        versionFileName(2000, HistFileType.patch),
        encodeVersionFile(
            version: sha('y'),
            prev: sha(big),
            writer: 'phone',
            body: utf8.encode(makePatchText(big, 'y'))),
      );

      final headers = await store.listHeaders('f.md');
      expect(headers.map((h) => h.type),
          [HistFileType.snapshot, HistFileType.patch]);
      expect(headers[0].version, sha(big));
      expect(headers[0].writer, 'laptop');
      expect(headers[1].prev, sha(big));
      expect(headers[1].writer, 'phone');

      final prefix = await readHeaderPrefix(
          File(p.join(tmp.path, '.hist', 'f.md', '0000000001000.snapshot')));
      expect(prefix.length, lessThan(4096),
          reason: 'a few kilobytes at most, not the two-megabyte body');
      expect(utf8.decode(prefix), endsWith('\n\n'));
    });

    test('the divergence count is a count of files, derived from the graphs',
        () async {
      final h = Harness();
      // a.md: two divergent branches.
      await h.record('a.md', 'A');
      await h.record('a.md', 'C');
      final phone = Harness(store: h.store, writerName: 'phone');
      phone.adopt('a.md', 'A');
      await phone.record('a.md', 'D');
      final tablet = Harness(store: h.store, writerName: 'tablet');
      tablet.adopt('a.md', 'A');
      await tablet.record('a.md', 'T');
      // b.md: an archived branch (rollback).
      await h.record('b.md', 'A');
      await h.record('b.md', 'B');
      await h.record('b.md', 'A');
      await h.record('b.md', 'E');
      // c.md: a merged branch.
      await h.record('c.md', 'A');
      await h.record('c.md', 'C');
      phone.adopt('c.md', 'A');
      await phone.record('c.md', 'D');
      await h.merge('c.md', sha('D'), sha('C'));
      // d.md: nothing.
      await h.record('d.md', 'A');
      // e.md: one divergent branch.
      await h.record('e.md', 'A');
      await h.record('e.md', 'C');
      phone.adopt('e.md', 'A');
      await phone.record('e.md', 'D');
      final live = {
        'a.md': sha('C'),
        'b.md': sha('E'),
        'c.md': sha('C'),
        'd.md': sha('A'),
        'e.md': sha('C'),
      };
      final before = await h.capture('a.md');

      final divergent = await divergentPaths(
        h.reader,
        await h.store.listPaths(),
        liveHashOf: (path) async => live[path],
      );

      expect(divergent, ['a.md', 'e.md'],
          reason: 'two files, not three branches');
      expect(await h.capture('a.md'), before, reason: 'nothing was written');
      expect(await hasDivergentLine(h.reader, 'c.md', liveHash: sha('C')),
          isFalse);
    });
  });
}
