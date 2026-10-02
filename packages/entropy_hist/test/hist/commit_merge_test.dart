/// `vault_hist` test-spec — "Commit — stateless" and "Merge: settled without
/// a merge node".
library;

import 'package:entropy_hist/entropy_hist.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  group('Commit — stateless (D7, RV5)', () {
    test('the module keeps no state between commits', () async {
      final store = MemoryHistStore();
      final first = Harness(store: store);
      await first.record('notes/foo.md', 'A');
      await first.record('notes/foo.md', 'AB');

      // A brand-new module over the same store, having seen neither commit.
      final second = Harness(store: store);
      await second.commitNow('notes/foo.md', [0x41, 0x42, 0x43]); // "ABC"

      // Found by version, not by filename order: the second module's clock
      // starts earlier, and filenames sort for humans — the graph is linked
      // by hashes (RV5).
      final headers = await store.listHeaders('notes/foo.md');
      final added = headers.singleWhere((h) => h.version == sha('ABC'));
      expect(added.type, HistFileType.patch);
      expect(added.prev, sha('AB'),
          reason: 'the base was recovered from the folder, not remembered');
    });

    test('committing the same state twice records nothing the second time',
        () async {
      final h = Harness();
      expect(await h.commitNow('notes/foo.md', [0x41]), isTrue);
      expect(await h.commitNow('notes/foo.md', [0x41]), isFalse,
          reason: 'a replayed commit is harmless');
      expect(await h.names('notes/foo.md'), hasLength(1));
    });

    test('with no base bytes available, the commit is a root snapshot',
        () async {
      final h = Harness();
      // `pre.md` predates history and the caller cannot produce its bytes.
      await h.commitNow('pre.md', [0x6e, 0x65, 0x77], usePrevious: false);

      final headers = await h.headers('pre.md');
      expect(headers, hasLength(1));
      expect(headers.single.type, HistFileType.snapshot,
          reason: 'no patch is invented from a base whose bytes are unknown');
      expect(headers.single.version, sha('new'));
    });

    test(
        'a caller that names the previous version\'s hash gets it '
        'reconstructed as the base', () async {
      final h = Harness();
      await h.record('f.md', 'A');
      await h.record('f.md', 'C');
      final other = Harness(store: h.store, writerName: 'phone');
      other.adopt('f.md', 'A');
      await other.record('f.md', 'D'); // two lines open

      final fresh = Harness(store: h.store);
      await fresh.commitNow('f.md', [0x45],
          usePrevious: false, previousHash: sha('C')); // "E"
      final added =
          (await h.headers('f.md')).singleWhere((x) => x.version == sha('E'));
      expect(added.type, HistFileType.patch);
      expect(added.prev, sha('C'),
          reason: 'the base\'s bytes were reconstructed from the graph');

      // A hash the folder does not hold is no base at all.
      await fresh.commitNow('f.md', [0x46],
          usePrevious: false, previousHash: sha('nowhere')); // "F"
      final root =
          (await h.headers('f.md')).singleWhere((x) => x.version == sha('F'));
      expect(root.type, HistFileType.snapshot);
    });

    test('a leaf settled by a merged marker no longer counts as an open line',
        () async {
      final h = Harness();
      await h.record('plan.md', 'A');
      await h.record('plan.md', 'C');
      final other = Harness(store: h.store, writerName: 'phone');
      other.adopt('plan.md', 'A');
      await other.record('plan.md', 'D');
      await h.commitNow('plan.md', [0x45], previous: [0x43]); // C → E
      await h.merge('plan.md', sha('D'), sha('E'));

      final fresh = Harness(store: h.store);
      await fresh.commitNow('plan.md', [0x46], usePrevious: false); // "F"
      final added = (await h.headers('plan.md'))
          .singleWhere((x) => x.version == sha('F'));
      expect(added.type, HistFileType.patch,
          reason: 'D is settled, so only one line is open');
      expect(added.prev, sha('E'));
    });

    test('raw editor events are the caller\'s problem, not this module\'s',
        () async {
      final h = Harness();
      await h.record('notes/foo.md', 'A');

      // A caller that forwarded a delete-then-write save verbatim.
      await h.commitNow('notes/foo.md', null);
      await h.commitNow('notes/foo.md', [0x41, 0x42]);

      final types = (await h.headers('notes/foo.md')).map((x) => x.type);
      expect(types, contains(HistFileType.deleted));
      expect(
        types.where((t) => t == HistFileType.snapshot).length,
        2,
        reason: 'two lives, not one edit — the module records what it is told '
            'and invents no window of its own',
      );
    });
  });

  group('Merge (RV6)', () {
    /// `plan.md` forks at A: `A → C` (live) and `A → D`.
    Future<Harness> forked() async {
      final h = Harness();
      await h.record('plan.md', 'A');
      await h.record('plan.md', 'C');
      // The other writer's line, arriving through sync.
      final other = Harness(store: h.store, writerName: 'phone');
      other.adopt('plan.md', 'A');
      await other.record('plan.md', 'D');
      return h;
    }

    test('a merge writes an ordinary edge plus a marker, never two parents',
        () async {
      final h = await forked();
      final before = await h.names('plan.md');

      await h.commitNow('plan.md', [0x45], previous: [0x43]); // C → E
      await h.merge('plan.md', sha('D'), sha('E'));

      final added = (await h.headers('plan.md'))
          .where((x) => !before.contains(x.filename))
          .toList();
      expect(added.map((x) => x.type),
          containsAll([HistFileType.patch, HistFileType.merged]));

      final patch = added.firstWhere((x) => x.type == HistFileType.patch);
      expect(patch.prev, sha('C'), reason: 'one parent, like any edit');
      expect(patch.version, sha('E'));

      final marker = added.firstWhere((x) => x.type == HistFileType.merged);
      expect(marker.merged, sha('D'));
      expect(marker.into, sha('E'));

      // Reconstruction is still one hash-verified chain.
      expect(await h.materializeText('plan.md', sha('E')), 'E');
    });

    test('a merged branch stays readable but stops being open', () async {
      final h = await forked();
      await h.commitNow('plan.md', [0x45], previous: [0x43]);
      await h.merge('plan.md', sha('D'), sha('E'));

      final graph = await h.graph('plan.md', live: 'E');
      final branch = graph.branches.singleWhere((b) => b.leaf == sha('D'));
      expect(branch.kind, HistBranchKind.merged);
      // Untouched and still reconstructible.
      expect(await h.materializeText('plan.md', sha('D')), 'D');
    });

    test('merging is idempotent whoever recorded it', () async {
      final h = await forked();
      await h.commitNow('plan.md', [0x45], previous: [0x43]);
      await h.merge('plan.md', sha('D'), sha('E'));
      // The phone reconciled concurrently into its own version.
      final phone = Harness(store: h.store, writerName: 'phone');
      await phone.merge('plan.md', sha('D'), sha('E2'));

      final graph = await h.graph('plan.md', live: 'E');
      final merged =
          graph.branches.where((b) => b.kind == HistBranchKind.merged);
      expect(merged, hasLength(1),
          reason: 'settled once — any marker naming the leaf is enough, so a '
              'surface can never loop on it');
    });

    test('only divergent branches are offered for merging', () async {
      final h = Harness();
      // A previous life.
      await h.record('f.md', 'X');
      await h.record('f.md', null);
      // A new life, then a rollback that strands B.
      await h.record('f.md', 'A');
      await h.record('f.md', 'B');
      await h.record('f.md', 'A'); // restore — records nothing
      await h.record('f.md', 'E');
      // Another writer's open line.
      final other = Harness(store: h.store, writerName: 'phone');
      other.adopt('f.md', 'A');
      await other.record('f.md', 'D');

      final graph = await h.graph('f.md', live: 'E');
      final divergent =
          graph.branches.where((b) => b.kind == HistBranchKind.divergent);
      expect(divergent.map((b) => b.leaf), [sha('D')],
          reason: 'the past life and the rollback are archived — the owner\'s '
              'own discarded states, nothing to reconcile');
      expect(
        graph.branches.where((b) => b.kind == HistBranchKind.archived),
        hasLength(2),
      );
    });

    test(
        'an anchor snapshot does not make another device\'s line the '
        'owner\'s own', () async {
      final store = MemoryHistStore();
      // plan.md = A predates history everywhere: each device, on its own
      // folder before the other's files arrive, anchors A under its own name
      // when it makes its first edit.
      final mac = Harness(store: store, writerName: 'mac');
      await mac.commitNow('plan.md', [0x43], previous: [0x41]); // A → C
      final deskOwn = MemoryHistStore();
      final deskAlone =
          Harness(store: deskOwn, writerName: 'desk', at: 1700000005000);
      await deskAlone.commitNow('plan.md', [0x44], previous: [0x41]); // A → D
      // …and desk's files arrive through sync.
      for (final h in await deskOwn.listHeaders('plan.md')) {
        await store.write(
            'plan.md', h.filename, await deskOwn.read('plan.md', h.filename));
      }
      final desk = Harness(store: store, writerName: 'desk');

      final graph = await desk.graph('plan.md', live: 'D');
      expect(graph.versions[sha('A')]!.writers, {'mac', 'desk'},
          reason: 'the two anchors dedup into one node');
      final c = graph.branches.singleWhere((b) => b.leaf == sha('C'));
      expect(c.kind, HistBranchKind.divergent,
          reason: 'mac edited nothing on the primary line — its line is '
              'somebody else\'s, still open');
      expect(c.writers, ['mac']);

      // desk rolls back to A and edits onward: D becomes its own discarded
      // state; C stays open.
      await desk.commitNow('plan.md', [0x45], previous: [0x41]); // A → E
      final after = await desk.graph('plan.md', live: 'E');
      expect(after.branches.singleWhere((b) => b.leaf == sha('D')).kind,
          HistBranchKind.archived);
      expect(after.branches.singleWhere((b) => b.leaf == sha('C')).kind,
          HistBranchKind.divergent);
    });

    test('the primary line follows the live content, never the clock',
        () async {
      final h = Harness();
      await h.record('plan.md', 'A');
      await h.record('plan.md', 'C');
      // A device days ahead: its filenames sort last.
      final skewed = Harness(
        store: h.store,
        writerName: 'phone',
        at: 1700000000000 + Duration(days: 3).inMilliseconds,
      );
      skewed.adopt('plan.md', 'A');
      await skewed.record('plan.md', 'B');

      final graph = await h.graph('plan.md', live: 'C');
      expect(graph.mainLine, [sha('A'), sha('C')],
          reason: 'the later filenames do not take the primary line');
      expect(graph.branches.single.leaf, sha('B'));
    });
  });
}
