/// `vault_hist.tests` — "Multi-writer" (RV6).
library;

import 'dart:convert';

import 'package:test/test.dart';

import 'harness.dart';

void main() {
  group('Multi-writer (RV6)', () {
    test('two writers recording the same version dedup in the reader',
        () async {
      final h = Harness();
      // Two devices independently made the identical edit A → B.
      await h.putSnapshot('f.md', 'A', ts: 1000, by: 'laptop');
      await h.putSnapshot('f.md', 'A', ts: 2000, by: 'phone');
      await h.putPatch('f.md', 'A', 'B', ts: 3000, by: 'laptop');
      await h.putPatch('f.md', 'A', 'B', ts: 4000, by: 'phone');

      final graph = await h.graph('f.md', live: 'B');

      expect(graph.versions.keys.toSet(), {sha('A'), sha('B')});
      expect(graph.roots, [sha('A')], reason: 'snapshots dedup by version');
      expect(graph.edges, hasLength(1),
          reason: 'edges dedup by (prev, version)');
      expect((graph.edges.single.prev, graph.edges.single.version),
          (sha('A'), sha('B')));
      expect(graph.mainLine, [sha('A'), sha('B')],
          reason: 'duplicate recordings are harmless by construction');
    });

    test("an offline device's late files connect by hash", () async {
      final h = Harness();
      await h.putSnapshot('plan.md', 'A', ts: 1000, by: 'phone');
      await h.putPatch('plan.md', 'A', 'D', ts: 2000, by: 'phone');
      final before = await h.capture('plan.md');

      // The laptop's offline recordings arrive through sync.
      await h.putPatch('plan.md', 'A', 'B', ts: 3000, by: 'laptop');
      await h.putPatch('plan.md', 'B', 'C', ts: 4000, by: 'laptop');

      final graph = await h.graph('plan.md', live: 'D');
      expect(graph.roots, [sha('A')]);
      expect({
        for (final e in graph.edges) (e.prev, e.version)
      }, {
        (sha('A'), sha('B')),
        (sha('B'), sha('C')),
        (sha('A'), sha('D')),
      },
          reason: 'a fork at A — the late pieces slotted in purely by hash '
              'linkage');
      expect(graph.mainLine, [sha('A'), sha('D')],
          reason: 'the LWW winner owns the main line');
      expect(graph.branches, hasLength(1));
      expect(graph.branches.single.hashes, [sha('B'), sha('C')],
          reason: 'B → C is a visible branch');
      for (final entry in before.entries) {
        expect(await h.bytes('plan.md', entry.key), entry.value,
            reason: 'no history file ever conflicts in sync');
      }
    });

    test('clock skew reorders filenames but not the graph', () async {
      final h = Harness();
      await h.putSnapshot('f.md', 'A', ts: 1000);
      await h.putPatch('f.md', 'A', 'B', ts: 3000);
      // Written by a device with a skewed clock: the child edge's filename
      // sorts before its parent edge's.
      await h.putPatch('f.md', 'B', 'C', ts: 2000, by: 'skewed');

      final graph = await h.graph('f.md', live: 'C');
      expect(graph.mainLine, [sha('A'), sha('B'), sha('C')],
          reason: 'the main line follows the hash headers, not the '
              'filename order — timestamps are for humans and sorting only');
      expect(await h.reader.materialize('f.md', sha('C')), utf8.encode('C'));
    });
  });
}
