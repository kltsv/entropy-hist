/// `vault_hist.tests` — "Conflict losers" (RV9).
library;

import 'package:entropy_hist/entropy_hist.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  group('Conflict losers (RV9)', () {
    test('a losing binary is rescued whole into a conflict file', () async {
      final h = Harness(at: 1700000000000);
      final losingBytes = [0x89, 0x50, 0x4e, 0x47, 0x00, 0xff, 0x01];

      await h.writer.recordBinaryConflictLoser('img/logo.png', losingBytes);

      final headers = await h.headers('img/logo.png');
      expect(headers, hasLength(1));
      expect(headers.single.filename, '1700000000000.conflict');
      expect(headers.single.version, sha256Hex(losingBytes));
      expect(headers.single.writer, 'laptop');
      expect(bodyOf(await h.bytes('img/logo.png', headers.single.filename)),
          losingBytes,
          reason: 'the full losing bytes — otherwise the losing binary '
              'would be gone forever; the winner is not recorded');
    });

    test('a losing text version records nothing at the receiver', () async {
      final h = Harness();
      await h.record('f.md', 'A');
      await h.record('f.md', 'B'); // the local edit, already flushed
      final before = await h.names('f.md');

      h.adopt('f.md', 'C');

      expect(await h.names('f.md'), before,
          reason: 'no conflict file and no other new file — the text '
              'loser\'s author already recorded it, and it surfaces as a '
              'dead-end branch on every device');
      expect(before.any((n) => n.endsWith('.conflict')), isFalse);
    });
  });
}
