/// `vault_hist.tests` — "Reader" (RV5).
library;

import 'dart:convert';

import 'package:entropy_hist/entropy_hist.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  group('Reader (RV5)', () {
    test('the reader builds a deduped graph of nodes, edges, and roots',
        () async {
      final h = Harness();
      await h.putSnapshot('f.md', 'A', ts: 1000, by: 'laptop');
      await h.putSnapshot('f.md', 'A', ts: 2000, by: 'phone');
      await h.putPatch('f.md', 'A', 'B', ts: 3000, by: 'laptop');
      await h.putPatch('f.md', 'A', 'B', ts: 4000, by: 'phone');
      await h.putPatch('f.md', 'B', 'C', ts: 5000);
      await h.putDeleted('f.md', prevHash: sha('C'), ts: 6000);

      final graph = await h.reader.graph('f.md'); // live file absent

      expect(graph.versions.keys.toSet(), {sha('A'), sha('B'), sha('C')});
      expect(graph.roots, [sha('A')], reason: 'deduped by version');
      expect({
        for (final e in graph.edges) (e.prev, e.version)
      }, {
        (sha('A'), sha('B')),
        (sha('B'), sha('C'))
      }, reason: 'deduped by (prev, version)');
      expect(graph.deletions, hasLength(1),
          reason: 'the deleted marker contributes no node or edge — it '
              'marks where the life ended');
    });

    test('the main line runs from a root to the live hash', () async {
      final h = Harness();
      await h.putSnapshot('f.md', 'A', ts: 1000);
      await h.putPatch('f.md', 'A', 'B', ts: 2000);
      await h.putPatch('f.md', 'B', 'C', ts: 3000);
      await h.putPatch('f.md', 'A', 'X', ts: 4000);

      final graph = await h.graph('f.md', live: 'C');

      expect(graph.mainLine, [sha('A'), sha('B'), sha('C')]);
      expect(graph.branches.expand((b) => b.hashes), [sha('X')],
          reason: 'X is unreachable from the main line and reported as a '
              'branch');
    });

    test('a conflict loser is a dead-end branch', () async {
      final h = Harness();
      await h.putSnapshot('f.md', 'A', ts: 1000);
      await h.putPatch('f.md', 'A', 'B', ts: 2000, by: 'laptop');
      await h.putPatch('f.md', 'A', 'C', ts: 3000, by: 'phone');

      final graph = await h.graph('f.md', live: 'C');

      expect(graph.mainLine, [sha('A'), sha('C')]);
      expect(graph.branches.expand((b) => b.hashes), [sha('B')],
          reason: 'the losing version remains visible on every device '
              'without any conflict file having been written for it');
    });

    test('a past life is a branch delimited by its deleted marker and date',
        () async {
      final h = Harness();
      await h.putSnapshot('todo.md', 'X', ts: 1000);
      await h.putPatch('todo.md', 'X', 'X2', ts: 2000);
      await h.putDeleted('todo.md', prevHash: sha('X2'), ts: 3000);
      await h.putSnapshot('todo.md', 'Y', ts: 4000);

      final graph = await h.graph('todo.md', live: 'Y');

      expect(graph.mainLine, [sha('Y')],
          reason: 'the main line is the new life rooted at Y');
      expect(graph.branches, hasLength(1));
      expect(graph.branches.single.hashes, [sha('X'), sha('X2')]);
      expect(graph.branches.single.endedAtMillis, 3000,
          reason: 'the old life ends at the deleted marker and is shown '
              'with the marker\'s date');
    });

    test('a rollback strands a branch', () async {
      final h = Harness();
      await h.putSnapshot('f.md', 'A', ts: 1000);
      await h.putPatch('f.md', 'A', 'B', ts: 2000);
      await h.putPatch('f.md', 'B', 'C', ts: 3000);
      // The owner restored A (nothing recorded) and edited onward.
      await h.putPatch('f.md', 'A', 'E', ts: 4000);

      final graph = await h.graph('f.md', live: 'E');

      expect(graph.mainLine, [sha('A'), sha('E')],
          reason: '"current" moved via the live file\'s pointer, not via '
              'an edge');
      expect(graph.branches, hasLength(1));
      expect(graph.branches.single.hashes, [sha('B'), sha('C')],
          reason: 'the abandoned states are a branch');
      for (final e in graph.edges) {
        expect(e.version, isNot(sha('A')),
            reason: 'no file in the folder points backward — the restore '
                'recorded no edge into A');
      }
    });

    test('materialization starts at the nearest snapshot ancestor', () async {
      final h = Harness();
      const a = 'alpha\n';
      const b = 'alpha beta\n';
      const c = 'alpha beta gamma\n';
      const d = 'alpha beta gamma delta\n';
      await h.putSnapshot('f.md', a, ts: 1000);
      await h.putPatchRaw('f.md',
          prevHash: sha(a),
          versionHash: sha(b),
          body: 'GARBAGE — not a dmp patch',
          ts: 2000);
      await h.putPatch('f.md', b, c, ts: 3000);
      await h.putSnapshot('f.md', c, ts: 4000); // the checkpoint
      await h.putPatch('f.md', c, d, ts: 5000);

      expect(await h.reader.materialize('f.md', sha(d)), utf8.encode(d),
          reason: 'the reader starts at the nearest snapshot ancestor '
              'snapshot(C) and applies one verified patch step, never '
              'touching the corrupted early patch');
      await expectLater(
          h.reader.materialize('f.md', sha(b)), throwsA(isA<BrokenVersion>()),
          reason: 'B\'s only route runs through the corrupted patch');
    });

    test(
        'every reconstruction step is hash-verified; corruption flags '
        'broken', () async {
      final h = Harness();
      const a = 'The quick brown fox jumps.\n';
      const b = 'The quick red fox jumps.\n';
      final tampered = makePatchText(a, b).replaceAll('red', 'rad');
      expect(tampered, isNot(makePatchText(a, b)),
          reason: 'precondition: the tampering changed the patch text');
      expect(applyPatchText(tampered, a), isNotNull,
          reason: 'precondition: dmp still applies the tampered patch '
              'without error — fuzzy application produces garbage silently');

      await h.putSnapshot('f.md', a, ts: 1000);
      await h.putPatchRaw('f.md',
          prevHash: sha(a), versionHash: sha(b), body: tampered, ts: 2000);

      await expectLater(
          h.reader.materialize('f.md', sha(b)), throwsA(isA<BrokenVersion>()),
          reason: 'sha256 is verified against the declared version after '
              'every patch step — the wrong bytes are never returned');
      expect(await h.reader.materialize('f.md', sha(a)), utf8.encode(a),
          reason: 'the intact snapshot still materializes');
    });

    test('a live hash absent from the graph reads as unsaved changes',
        () async {
      final h = Harness();
      await h.putSnapshot('f.md', 'A', ts: 1000);
      await h.putPatch('f.md', 'A', 'B', ts: 2000);

      final graph = await h.graph('f.md', live: 'Z');

      expect(graph.versions.keys.toSet(), {sha('A'), sha('B')},
          reason: 'the live state is not a node');
      expect(graph.mainLine, isEmpty);
      expect(graph.unsavedChangesAfter, sha('B'),
          reason: 'reported as "unsaved changes after version B" — an edit '
              'still inside the debounce window, not an error');
    });

    test('rename links make old history reachable from the new name (S6)',
        () async {
      final h = Harness();
      await h.record('doc/a.md', 'W');
      await h.record('doc/a.md', 'X');
      await h.writer.recordRename('doc/a.md', 'doc/b.md', utf8.encode('X'));

      final newGraph = await h.graph('doc/b.md', live: 'X');
      expect(newGraph.renamedFrom, hasLength(1));
      expect(newGraph.renamedFrom.single.path, 'doc/a.md',
          reason: 'the display link through which versions recorded under '
              'the old name are reachable');
      expect(newGraph.renamedFrom.single.versionHash, sha('X'));

      final oldGraph = await h.reader.graph('doc/a.md');
      expect(oldGraph.renamedTo, hasLength(1));
      expect(oldGraph.renamedTo.single.path, 'doc/b.md',
          reason: 'the old folder\'s marker carries the forward link — no '
              'folder was merged or moved');
      expect(oldGraph.versions.keys, contains(sha('W')),
          reason: 'the old name\'s versions are all still there');
    });
  });
}
