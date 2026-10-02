/// `vault_hist.tests` — "Diff-match-patch recipe and interop" (C5, RV5).
///
/// The fixtures under `fixtures/dmp_interop/` are the cross-port contract:
/// each holds a base text, the patch text emitted by the pinned recipe
/// (`diff_main` → `diff_cleanupEfficiency` → `patch_make`, defaults,
/// `patch_toText`), the result text, and both texts' sha256. The Obsidian
/// plugin's JS-side test consumes the same files, so a patch produced by one
/// port applies in the other with matching hashes. Keep the JSON stable.
library;

import 'dart:convert';
import 'dart:io';

import 'package:entropy_hist/entropy_hist.dart';
import 'package:test/test.dart';

import 'harness.dart';

const _fixtureDir = 'test/hist/fixtures/dmp_interop';

Map<String, Map<String, String>> _loadFixtures() {
  final files = Directory(_fixtureDir)
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return {
    for (final f in files)
      f.uri.pathSegments.last: {
        for (final e
            in (jsonDecode(f.readAsStringSync()) as Map<String, dynamic>)
                .entries)
          e.key: e.value as String,
      },
  };
}

void main() {
  group('Diff-match-patch recipe and interop (C5, RV5)', () {
    final fixtures = _loadFixtures();

    test('fixtures cover plain, unicode, and multi-hunk edits', () {
      expect(fixtures.keys,
          containsAll(['plain_edit.json', 'unicode.json', 'multi_hunk.json']));
      expect(fixtures.length, greaterThanOrEqualTo(3));
    });

    test('regenerating every fixture patch pins the recipe', () {
      fixtures.forEach((name, fx) {
        expect(makePatchText(fx['before']!, fx['after']!), fx['patch'],
            reason: '$name: the pinned recipe must reproduce the checked-in '
                'patch text byte-for-byte');
        expect(sha256Hex(utf8.encode(fx['before']!)), fx['beforeSha'],
            reason: '$name: beforeSha');
        expect(sha256Hex(utf8.encode(fx['after']!)), fx['afterSha'],
            reason: '$name: afterSha');
      });
    });

    test('every fixture patch applies cleanly with a matching hash', () {
      fixtures.forEach((name, fx) {
        final result = applyPatchText(fx['patch']!, fx['before']!);
        expect(result, fx['after']!, reason: '$name: apply');
        expect(sha256Hex(utf8.encode(result!)), fx['afterSha'],
            reason: '$name: a patch produced by one port must apply in the '
                'other with matching hashes');
      });
    });

    test('the patch body the writer records follows the pinned dmp recipe',
        () async {
      final fx = fixtures['plain_edit.json']!;
      final h = Harness();
      await h.record('f.md', fx['before']!);

      await h.record('f.md', fx['after']!);

      final patch = (await h.headers('f.md'))
          .singleWhere((x) => x.type == HistFileType.patch);
      final body = await h.body('f.md', patch.filename);
      expect(body, fx['patch'],
          reason: 'the body equals the fixture patch text byte-for-byte — '
              'the interoperable dmp text format');
      expect(applyPatchText(body, fx['before']!), fx['after']!);
    });
  });
}
