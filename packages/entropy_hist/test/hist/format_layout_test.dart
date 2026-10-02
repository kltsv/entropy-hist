/// `vault_hist.tests` — "File format and layout" (RV5).
library;

import 'dart:convert';
import 'dart:io';

import 'package:entropy_hist/entropy_hist.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  group('File format and layout (RV5)', () {
    late Directory vault;

    setUp(() => vault = Directory.systemTemp.createTempSync('vault_hist_'));
    tearDown(() => vault.deleteSync(recursive: true));

    test('a version file is named 13-digit zero-padded epoch-ms plus its type',
        () async {
      final h = Harness(store: FsHistStore(vault.path), at: 999999999999);
      h.local('notes/foo.md', 'A');
      await h.idle();

      final dir = Directory(p.join(vault.path, '.hist', 'notes', 'foo.md'));
      expect(dir.existsSync(), isTrue,
          reason: 'the file path becomes a folder under the .hist mirror');
      final files = dir.listSync().map((e) => p.basename(e.path)).toList();
      expect(files, ['0999999999999.snapshot'],
          reason: 'the 12-digit timestamp is padded to 13 with a leading '
              'zero, and the extension is one of the four types');
    });

    test('filenames sort lexicographically in chronological order', () async {
      final h = Harness();
      await h.record('n.md', 'one', at: 999999999999);
      await h.record('n.md', 'two', at: 1700000000000);
      await h.record('n.md', 'three', at: 1700000100000);

      final names = await h.names('n.md');
      final sorted = [...names]..sort();
      expect(
          sorted,
          [
            '0999999999999.snapshot',
            '1700000000000.patch',
            '1700000100000.patch',
          ],
          reason: 'zero-padding makes 0999999999999… sort before '
              '1700000000000… — unpadded it would sort after');
    });

    test('a snapshot file is headers, a blank line, then the full content',
        () async {
      final h = Harness();
      await h.record('notes/foo.md', 'A');

      final names = await h.names('notes/foo.md');
      final raw = utf8.decode(await h.bytes('notes/foo.md', names.single));
      expect(raw, 'version: ${sha('A')}\nwriter: laptop\n\nA',
          reason: 'key: value header lines, exactly one empty line, then '
              'the full content — not a diff');
    });

    test('a patch file links prev to version with a forward dmp body',
        () async {
      final h = Harness();
      await h.record('notes/foo.md', 'A');
      final before = await h.names('notes/foo.md');
      await h.record('notes/foo.md', 'AB');

      final after = await h.names('notes/foo.md');
      final added = after.toSet().difference(before.toSet()).toList();
      expect(added, hasLength(1));
      expect(added.single, endsWith('.patch'));

      final header = (await h.headers('notes/foo.md'))
          .singleWhere((x) => x.filename == added.single);
      expect(header.version, sha('AB'));
      expect(header.prev, sha('A'));
      expect(header.writer, 'laptop');
      final body = await h.body('notes/foo.md', added.single);
      expect(applyPatchText(body, 'A'), 'AB',
          reason: 'the body is a forward dmp patch: applying it to "A" '
              'yields "AB"');
    });

    test('version and prev are sha256 of the content bytes as-is', () async {
      final h = Harness();
      await h.record('notes/foo.md', 'A\n');

      final header = (await h.headers('notes/foo.md')).single;
      expect(header.version, sha('A\n'),
          reason: 'hashed over exactly the bytes A\\n, newline included');
      expect(header.version, hasLength(64));
      expect(header.version, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(header.version, isNot(sha('A')),
          reason: 'no newline normalization');
    });

    test('every version file names its writer', () async {
      final h = Harness(writerName: 'phone');
      await h.record('a.md', 'A');
      await h.record('a.md', 'AB');
      await h.record('a.md', null);
      await h.merge('a.md', sha('AB'), sha('A'));
      await h.writer
          .recordBinaryConflictLoser('img/x.png', [0x89, 0x50, 0x00, 0x47]);

      final headers = [
        ...await h.headers('a.md'),
        ...await h.headers('img/x.png'),
      ];
      expect(headers.map((x) => x.type).toSet(), HistFileType.values.toSet(),
          reason: 'the scenario produced all five types');
      for (final header in headers) {
        expect(header.writer, 'phone',
            reason: '${header.filename} must carry writer: phone');
      }
    });

    test('a taken filename bumps the millisecond until free', () async {
      final h = Harness();
      // The other writer's patch (A0 → A) arrived through sync.
      await h.putPatchRaw('f.md',
          prevHash: sha('A0'),
          versionHash: sha('A'),
          body: makePatchText('A0', 'A'),
          ts: 1700000000000,
          by: 'phone');
      final arrived = await h.bytes('f.md', '1700000000000.patch');
      h.adopt('f.md', 'A');

      await h.record('f.md', 'AB', at: 1700000000000);

      expect(
          await h.names('f.md'), ['1700000000000.patch', '1700000000001.patch'],
          reason: 'the wanted name was taken, so the millisecond bumped '
              'until free; both files coexist');
      expect(await h.bytes('f.md', '1700000000000.patch'), arrived,
          reason: 'the pre-existing file is untouched');
      final bumped = (await h.headers('f.md'))
          .singleWhere((x) => x.filename == '1700000000001.patch');
      expect(bumped.prev, sha('A'));
      expect(bumped.version, sha('AB'),
          reason: 'identity stays in the hash headers, not the filename');
    });

    test('the mirror never tracks itself', () async {
      final h = Harness(store: FsHistStore(vault.path));
      h.local('.hist/notes/foo.md/0000000000001.snapshot', 'version: x\n\nA');
      await h.idle();

      expect(Directory(p.join(vault.path, '.hist')).existsSync(), isFalse,
          reason: 'paths under the mirror root are excluded from tracking — '
              'no .hist/.hist ever appears (RV8)');
    });

    test('history files are never modified, moved, or deleted', () async {
      final h = Harness();
      final captures = <Map<String, List<int>>>[];
      for (final step in ['A', 'B', 'A', null, 'C']) {
        await h.record('f.md', step);
        captures.add(await h.capture('f.md'));
      }

      for (var earlier = 0; earlier < captures.length; earlier++) {
        for (var later = earlier + 1; later < captures.length; later++) {
          for (final entry in captures[earlier].entries) {
            expect(captures[later], contains(entry.key),
                reason: 'no file is ever renamed or removed');
            expect(captures[later][entry.key], entry.value,
                reason: '${entry.key} must stay byte-identical — the store '
                    'only ever gains files');
          }
        }
      }
      expect(captures.last.length, greaterThan(captures.first.length),
          reason: 'the lifecycle really did append files');
    });
  });
}
