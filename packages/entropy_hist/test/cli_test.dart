/// `vault_hist_cli` test-spec — the folder, commit, addressing, log, show and
/// restore.
library;

import 'dart:io';

import 'package:entropy_hist/entropy_hist.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  late CliHarness h;
  setUp(() => h = CliHarness());
  tearDown(() => h.dispose());

  group('the folder, and what is tracked', () {
    test('the folder is located by walking up to the nearest .hist/', () async {
      h.write('notes/plan.md', 'plan');
      expect((await h.run(['commit'])).code, 0);
      Directory(p.join(h.root, 'notes', 'deep')).createSync(recursive: true);

      final fromDeep = await h.run(['log', p.join(h.root, 'notes', 'plan.md')],
          cwd: p.join(h.root, 'notes', 'deep'));
      expect(fromDeep.code, 0, reason: fromDeep.stderr);
      expect(fromDeep.stdout, startsWith('notes/plan.md\n'),
          reason: 'resolved relative to the folder holding .hist/');

      // A directory with no .hist/ anywhere above it is its own folder.
      final elsewhere = Directory(p.join(h.tmp.path, 'elsewhere'))
        ..createSync();
      File(p.join(elsewhere.path, 'x.md')).writeAsStringSync('x');
      final own = await h.run(['commit'], cwd: elsewhere.path);
      expect(own.code, 0, reason: own.stderr);
      expect(Directory(p.join(elsewhere.path, '.hist')).existsSync(), isTrue);
    });

    test(
        'tracking honours the extension list, the built-ins and nested '
        'ignore files', () async {
      h.write('a.md', 'a');
      h.write('b.txt', 'b');
      h.write('.git/c.md', 'c');
      h.write('.hist-state/x.md', 'x');
      h.write('drafts/d.md', 'd');
      h.write('notes/scratch.md', 's');
      h.write('notes/keep.md', 'k');
      h.write('.histignore', 'drafts/\n');
      h.write('notes/.histignore', 'scratch.md\n');

      final first = await h.run(['commit']);
      expect(first.code, 0, reason: first.stderr);
      final recorded = await h.store.listPaths();
      expect(recorded, ['a.md', 'notes/keep.md']);

      final second = await h.run(['commit', '--extensions', '*']);
      expect(second.code, 0, reason: second.stderr);
      expect(
          await h.store.listPaths(),
          [
            '.histignore',
            'a.md',
            'b.txt',
            'notes/.histignore',
            'notes/keep.md'
          ],
          reason: 'text files of any name — still nothing excluded');
    });
  });

  group('commit (R19, R2\')', () {
    test(
        'commit with no paths records everything that differs, with one '
        'timestamp', () async {
      h.write('a.md', 'a1');
      h.write('notes/b.md', 'b1');
      h.clock = 1700000000000;
      final first = await h.run(['commit']);
      expect(first.code, 0, reason: first.stderr);
      expect(await h.names('a.md'), ['1700000000000.snapshot']);
      expect(await h.names('notes/b.md'), ['1700000000000.snapshot']);
      expect(first.stdout, contains('recorded  a.md'));
      expect(first.stdout, contains('recorded  notes/b.md'));

      h.write('a.md', 'a2');
      h.delete('notes/b.md');
      h.clock = 1700000005000;
      final second = await h.run(['commit']);
      expect(second.code, 0, reason: second.stderr);
      expect(await h.names('a.md'),
          ['1700000000000.snapshot', '1700000005000.patch']);
      expect(await h.names('notes/b.md'),
          ['1700000000000.snapshot', '1700000005000.deleted']);
      expect(second.stdout, contains('deleted   notes/b.md'));

      final third = await h.run(['commit']);
      expect(third.code, 0);
      expect(third.stdout, contains('unchanged a.md'));
      expect(third.stdout, contains('0 recorded'));
      expect(await h.names('a.md'), hasLength(2), reason: 'nothing written');
    });

    test('commit with paths records only those', () async {
      h.write('a.md', 'a1');
      h.write('b.md', 'b1');
      await h.run(['commit']);
      h.write('a.md', 'a2');
      h.write('b.md', 'b2');

      final res = await h.run(['commit', 'a.md']);
      expect(res.code, 0, reason: res.stderr);
      expect(await h.names('a.md'), hasLength(2));
      expect(await h.names('b.md'), hasLength(1));

      final outside = await h.run(['commit', p.join(h.tmp.path, 'x.md')]);
      expect(outside.code, 64);
      expect(outside.stderr, contains('outside the folder'));
    });

    test('a commit after a restore diffs from the restored version', () async {
      h.write('f.md', 'A');
      await h.run(['commit']);
      h.write('f.md', 'B');
      await h.run(['commit']);

      final restore = await h.run(['restore', 'f.md', 'HEAD~1']);
      expect(restore.code, 0, reason: restore.stderr);
      expect(h.read('f.md'), 'A');
      expect(await h.names('f.md'), hasLength(2), reason: 'nothing recorded');

      h.write('f.md', 'E');
      final commit = await h.run(['commit', 'f.md']);
      expect(commit.code, 0, reason: commit.stderr);
      final headers = await h.headers('f.md');
      final added = headers.singleWhere((x) => x.version == sha('E'));
      expect(added.type, HistFileType.patch);
      expect(added.prev, sha('A'),
          reason: 'from the restored version, not the stranded leaf');

      final log = await h.run(['log', '--all', 'f.md']);
      expect(log.stdout,
          contains('branch ${sha('B').substring(0, 12)}  archived'));
    });
  });

  group('addressing (R1)', () {
    test(
        'revisions resolve like git, and ambiguity is an error naming the '
        'candidates', () async {
      h.write('f.md', 'A');
      h.clock = 1700000001000;
      await h.run(['commit']);
      h.write('f.md', 'B');
      h.clock = 1700000002000;
      await h.run(['commit']);
      h.write('f.md', 'C');
      h.clock = 1700000003000;
      await h.run(['commit']);

      for (final ref in [
        sha('B'),
        sha('B').substring(0, 8),
        'HEAD~1',
        '@{${DateTime.fromMillisecondsSinceEpoch(1700000002500).toIso8601String()}}',
      ]) {
        final res = await h.run(['show', 'f.md', ref]);
        expect(res.code, 0, reason: '$ref: ${res.stderr}');
        expect(res.stdout, 'B', reason: ref);
      }

      // Two versions sharing a five-character prefix, arrived through sync.
      final (x, y) = _sharingPrefix(5);
      await h.putSnapshot('g.md', x, ts: 1000);
      await h.putSnapshot('g.md', y, ts: 2000);
      final ambiguous = await h.run(['show', 'g.md', sha(x).substring(0, 5)]);
      expect(ambiguous.code, 1);
      expect(ambiguous.stderr, contains(sha(x)));
      expect(ambiguous.stderr, contains(sha(y)));
      expect(ambiguous.stdout, isEmpty);
    });
  });

  group('log (R2)', () {
    test(
        'the log lists the primary line newest first, marks live, and '
        'appends branches on request', () async {
      h.write('f.md', 'A');
      h.clock = 1700000001000;
      await h.run(['commit']);
      h.write('f.md', 'B');
      h.clock = 1700000002000;
      await h.run(['commit', '--writer', 'phone']);
      h.write('f.md', 'C');
      h.clock = 1700000003000;
      await h.run(['commit']);
      await h.putPatch('f.md', 'A', 'X', ts: 1700000002500, by: 'tablet');

      final plain = await h.run(['log', 'f.md']);
      expect(plain.code, 0, reason: plain.stderr);
      final lines = plain.lines;
      expect(lines.first, 'f.md');
      expect(lines[1], startsWith(sha('C').substring(0, 12)));
      expect(lines[1], endsWith('laptop  live'));
      expect(lines[2], startsWith(sha('B').substring(0, 12)));
      expect(lines[2], contains('phone'));
      expect(lines[3], startsWith(sha('A').substring(0, 12)));
      expect(lines, hasLength(4), reason: 'no branch without --all');

      final all = await h.run(['log', '--all', 'f.md']);
      expect(all.stdout,
          contains('branch ${sha('X').substring(0, 12)}  divergent  (tablet)'));
      expect(all.stdout, contains(sha('X').substring(0, 12)));

      final byPhone =
          await h.run(['log', '--author', 'phone', '--all', 'f.md']);
      final phoneLines = byPhone.lines.where((l) => !l.startsWith('branch'));
      expect(phoneLines.skip(1).map((l) => l.substring(0, 12)),
          [sha('B').substring(0, 12)]);

      final one = await h.run(['log', '-n', '1', 'f.md']);
      expect(one.lines, hasLength(2));
      expect(one.lines[1], startsWith(sha('C').substring(0, 12)));
    });

    test('unsaved live changes are announced, never mistaken for a version',
        () async {
      h.write('f.md', 'A');
      await h.run(['commit']);
      h.write('f.md', 'B');
      await h.run(['commit']);
      h.write('f.md', 'Z');

      final log = await h.run(['log', 'f.md']);
      expect(log.lines[1],
          contains('unsaved changes after ${sha('B').substring(0, 12)}'));
      expect(log.lines, hasLength(4));

      final head = await h.run(['show', 'f.md', 'HEAD']);
      expect(head.code, 1);
      expect(head.stderr, contains('unsaved changes after ${sha('B')}'));
    });
  });

  group('show and restore (R3)', () {
    test('show prints verified content and reports a broken version', () async {
      const a = 'The quick brown fox jumps.\n';
      const b = 'The quick red fox jumps.\n';
      await h.putSnapshot('f.md', a, ts: 1000);
      final tampered = makePatchText(a, b).replaceAll('red', 'rad');
      await h.putPatchRaw('f.md',
          prevHash: sha(a), versionHash: sha(b), body: tampered, ts: 2000);
      h.write('f.md', b);

      final ok = await h.run(['show', 'f.md', 'HEAD~1']);
      expect(ok.code, 0, reason: ok.stderr);
      expect(ok.stdout, a);

      final broken = await h.run(['show', 'f.md', 'HEAD']);
      expect(broken.code, 1);
      expect(broken.stdout, isEmpty, reason: 'never silently wrong');
      expect(broken.stderr, contains('broken'));
    });

    test(
        'restore writes the addressed version over the live file and '
        'records nothing', () async {
      h.write('f.md', 'A');
      await h.run(['commit']);
      h.write('f.md', 'B');
      await h.run(['commit']);
      final before = h.mirrorSnapshot();

      final res = await h.run(['restore', 'f.md', 'HEAD~1']);
      expect(res.code, 0, reason: res.stderr);
      expect(h.read('f.md'), 'A');
      expect(res.stdout, contains(sha('A').substring(0, 12)));
      expect(File(p.join(h.root, 'f.md.hist-tmp')).existsSync(), isFalse);
      expect(h.mirrorSnapshot(), before, reason: 'no history file written');
    });
  });

  group('diff and blame (R4, R5)', () {
    test(
        'diff renders a unified diff over verified content, across a '
        'checkpoint', () async {
      const a = 'one\ntwo\n';
      const b = 'one\ntwo\nthree\n';
      const c = 'uno\ntwo\nthree\n';
      await h.putSnapshot('f.md', a, ts: 1000);
      await h.putPatchRaw('f.md',
          prevHash: sha(a), versionHash: sha(b), body: 'GARBAGE', ts: 2000);
      await h.putSnapshot('f.md', b, ts: 3000);
      await h.putPatch('f.md', b, c, ts: 4000);
      h.write('f.md', c);

      final explicit = await h.run(['diff', 'f.md', 'HEAD~1', 'HEAD']);
      expect(explicit.code, 0, reason: explicit.stderr);
      expect(
          explicit.stdout,
          startsWith('--- a/f.md (${sha(b).substring(0, 12)})\n'
              '+++ b/f.md (${sha(c).substring(0, 12)})\n'
              '@@ -1,3 +1,3 @@\n-one\n+uno\n two\n three\n'));

      final defaults = await h.run(['diff', 'f.md']);
      expect(defaults.stdout, explicit.stdout, reason: 'HEAD~1 HEAD');

      // A side that cannot be verified fails the whole command as broken.
      final tampered = makePatchText(b, c).replaceAll('uno', 'una');
      await h.putPatchRaw('g.md',
          prevHash: sha(b), versionHash: sha(c), body: tampered, ts: 2000);
      await h.putSnapshot('g.md', b, ts: 1000);
      h.write('g.md', c);
      final broken = await h.run(['diff', 'g.md']);
      expect(broken.code, 1);
      expect(broken.stdout, isEmpty);
      expect(broken.stderr, contains('broken'));
    });

    test(
        'blame attributes each line to the version and writer that '
        'introduced it', () async {
      h.write('f.md', 'one\ntwo\n');
      h.clock = 1700000001000;
      await h.run(['commit']);
      h.write('f.md', 'one\ntwo\nthree\n');
      h.clock = 1700000002000;
      await h.run(['commit', '--writer', 'phone']);
      h.write('f.md', 'uno\ntwo\nthree\n');
      h.clock = 1700000003000;
      await h.run(['commit']);

      final res = await h.run(['blame', 'f.md']);
      expect(res.code, 0, reason: res.stderr);
      final lines = res.lines;
      expect(lines, hasLength(3));
      expect(lines[0], startsWith(sha('uno\ntwo\nthree\n').substring(0, 12)));
      expect(lines[0], contains('laptop'));
      expect(lines[0], endsWith('  uno'));
      expect(lines[1], startsWith(sha('one\ntwo\n').substring(0, 12)));
      expect(lines[1], contains('laptop'));
      expect(lines[1], endsWith('  two'));
      expect(lines[2], startsWith(sha('one\ntwo\nthree\n').substring(0, 12)));
      expect(lines[2], contains('phone'));
      expect(lines[2], endsWith('  three'));
    });
  });

  group('merge (R8–R13, R15, R17)', () {
    /// `plan.md` forked at A: `A → C` (live, laptop) and `A → D` (phone).
    Future<void> forked({
      String a = 'A',
      String c = 'C',
      String d = 'D',
    }) async {
      h.write('plan.md', a);
      h.clock = 1700000001000;
      await h.run(['commit']);
      h.write('plan.md', c);
      h.clock = 1700000002000;
      await h.run(['commit']);
      await h.putPatch('plan.md', a, d, ts: 1700000001500, by: 'phone');
    }

    test(
        'take the branch whole restores its leaf as the live version and '
        'settles the former line', () async {
      await forked();
      final before = h.mirrorSnapshot();

      final res = await h.run(
          ['merge', 'plan.md', sha('D').substring(0, 8), '--take', 'branch']);
      expect(res.code, 0, reason: res.stderr);
      expect(h.read('plan.md'), 'D');
      final added = h.mirrorSnapshot().keys.toSet()..removeAll(before.keys);
      expect(added, hasLength(1), reason: 'the leaf is already recorded');
      final marker = (await h.headers('plan.md'))
          .singleWhere((x) => x.type == HistFileType.merged);
      expect(marker.merged, sha('C'), reason: 'the line that was live');
      expect(marker.into, sha('D'));

      final log = await h.run(['log', '--all', 'plan.md']);
      expect(log.stdout, contains('${sha('D').substring(0, 12)}  '));
      expect(log.stdout, contains('  live'));
      expect(
          log.stdout, contains('branch ${sha('C').substring(0, 12)}  merged'));
      final status = await h.run(['status']);
      expect(status.stdout, contains('no divergent lines'));
    });

    test('take the live side writes only a marker and changes no content',
        () async {
      await forked();
      final before = h.mirrorSnapshot();

      final res = await h.run(['merge', 'plan.md', sha('D'), '--take', 'live']);
      expect(res.code, 0, reason: res.stderr);
      expect(h.read('plan.md'), 'C');
      final added = h.mirrorSnapshot().keys.toSet()..removeAll(before.keys);
      expect(added, hasLength(1));
      final marker = (await h.headers('plan.md'))
          .singleWhere((x) => x.type == HistFileType.merged);
      expect(marker.merged, sha('D'));
      expect(marker.into, sha('C'));
      expect((await h.run(['log', '--all', 'plan.md'])).stdout,
          contains('branch ${sha('D').substring(0, 12)}  merged'));
      expect((await h.run(['status'])).stdout, contains('no divergent lines'));
    });

    test(
        'the three-way merge writes a draft with explicit conflict regions, '
        'resumable', () async {
      const a = 'one\ntwo\nthree\n';
      const c = 'one\ntwo changed here\nthree\n';
      const d = 'one\ntwo changed there\nthree\nfour\n';
      await forked(a: a, c: c, d: d);
      final before = h.mirrorSnapshot();

      final start = await h.run(['merge', 'plan.md', sha(d).substring(0, 8)]);
      expect(start.code, 0, reason: start.stderr);
      final draftPath = p.join(h.root, '.hist-state', 'merge', 'plan.md.draft');
      expect(start.stdout, contains(draftPath));
      expect(start.stdout, contains('1 conflict region'));
      expect(h.mirrorSnapshot(), before, reason: 'nothing written to history');
      expect(h.read('plan.md'), c, reason: 'the live file is untouched');
      final draft = File(draftPath).readAsStringSync();
      expect(draft, endsWith('three\nfour\n'), reason: '"four" merged cleanly');
      expect(
          draft,
          contains('<<<<<<< live ${sha(c).substring(0, 12)}\n'
              'two changed here\n'
              '||||||| base ${sha(a).substring(0, 12)}\n'
              'two\n'
              '=======\n'
              'two changed there\n'
              '>>>>>>> branch ${sha(d).substring(0, 12)}\n'));

      final status = await h.run(['status']);
      expect(status.stdout, contains('1 unfinished merge'));
      expect(status.stdout, contains(draftPath));

      final refused = await h.run(['merge', 'plan.md', '--continue']);
      expect(refused.code, 1);
      expect(refused.stderr, contains('still has 1 conflict region'));
      expect(refused.stderr, contains('line 2'));
      expect(h.read('plan.md'), c);

      File(draftPath)
          .writeAsStringSync('one\ntwo changed both ways\nthree\nfour\n');
      h.clock = 1700000003000;
      final done = await h.run(['merge', 'plan.md', '--continue']);
      expect(done.code, 0, reason: done.stderr);
      const e = 'one\ntwo changed both ways\nthree\nfour\n';
      expect(h.read('plan.md'), e);
      final headers = await h.headers('plan.md');
      final patch = headers.singleWhere((x) => x.version == sha(e));
      expect(patch.type, HistFileType.patch);
      expect(patch.prev, sha(c), reason: 'committed from the live version');
      final marker = headers.singleWhere((x) => x.type == HistFileType.merged);
      expect(marker.merged, sha(d));
      expect(marker.into, sha(e));
      expect(File(draftPath).existsSync(), isFalse, reason: 'draft removed');
      expect((await h.run(['status'])).stdout, isNot(contains('unfinished')));
    });

    test('no common ancestor means side-choosing only', () async {
      h.write('f.md', 'P');
      await h.run(['commit']);
      await h.putSnapshot('f.md', 'Q', ts: 1700000009000, by: 'phone');
      final before = h.mirrorSnapshot();

      final res = await h.run(['merge', 'f.md', sha('Q')]);
      expect(res.code, 1);
      expect(res.stderr, contains('no ancestor'));
      expect(res.stderr, contains('--take live'));
      expect(res.stderr, contains('--take branch'));
      expect(h.mirrorSnapshot(), before);
    });

    test('merge refuses archived branches and is a no-op on settled ones',
        () async {
      // A rollback strands B: archived.
      h.write('f.md', 'A');
      await h.run(['commit']);
      h.write('f.md', 'B');
      await h.run(['commit']);
      await h.run(['restore', 'f.md', 'HEAD~1']);
      h.write('f.md', 'E');
      await h.run(['commit']);
      // Another writer's line, already settled by a marker.
      await h.putPatch('f.md', 'A', 'D', ts: 1700000001500, by: 'phone');
      await h.putMerged('f.md',
          merged: sha('D'), into: sha('E'), ts: 1700000009000);
      final before = h.mirrorSnapshot();

      final archived =
          await h.run(['merge', 'f.md', sha('B'), '--take', 'branch']);
      expect(archived.code, 1);
      expect(archived.stderr, contains('archived'));
      expect(archived.stderr, contains('nothing to reconcile'));

      final settled =
          await h.run(['merge', 'f.md', sha('D'), '--take', 'live']);
      expect(settled.code, 0, reason: settled.stderr);
      expect(settled.stdout, contains('already settled'));
      expect(h.mirrorSnapshot(), before, reason: 'nothing written either way');
    });

    test('--abort discards the draft', () async {
      const a = 'one\ntwo\n';
      await forked(a: a, c: 'one\ntwo\nC\n', d: 'one\ntwo\nD\n');
      await h.run(['merge', 'plan.md', sha('one\ntwo\nD\n')]);
      final before = h.mirrorSnapshot();
      expect((await h.run(['status'])).stdout, contains('unfinished merge'));

      final res = await h.run(['merge', 'plan.md', '--abort']);
      expect(res.code, 0, reason: res.stderr);
      expect(
          File(p.join(h.root, '.hist-state', 'merge', 'plan.md.draft'))
              .existsSync(),
          isFalse);
      expect(h.mirrorSnapshot(), before);
      expect(h.read('plan.md'), 'one\ntwo\nC\n');
      expect((await h.run(['status'])).stdout, isNot(contains('unfinished')));
    });
  });

  group('the folder-wide log (R6, R2\')', () {
    test('merges every file\'s versions and says it is approximate', () async {
      h.write('a.md', 'A');
      h.write('b.md', 'B');
      h.clock = 1700000001000;
      await h.run(['commit']); // two versions, one timestamp, one writer
      await h.putPatch('a.md', 'A', 'A2', ts: 1700000009000, by: 'phone');
      h.write('a.md', 'A2'); // the phone's edit is live

      final plain = await h.run(['log']);
      expect(plain.code, 0, reason: plain.stderr);
      expect(plain.lines.first, contains('approximate between files'));
      expect(plain.lines.first, contains('clocks'));
      expect(plain.lines.first, contains('not commits'));
      final rows = plain.lines.skip(1).toList();
      expect(rows, hasLength(3));
      expect(rows[0], startsWith(sha('A2').substring(0, 12)));
      expect(rows[0], contains('phone'));
      expect(rows[0], contains('a.md'));
      expect(rows[0], endsWith('live'));
      expect(rows[1], startsWith(sha('A').substring(0, 12)));
      expect(rows[1], contains('laptop'));
      expect(rows[1], contains('a.md'));
      expect(rows[2], startsWith(sha('B').substring(0, 12)));
      expect(rows[2], contains('b.md'));

      final grouped = await h.run(['log', '--group']);
      expect(grouped.code, 0, reason: grouped.stderr);
      final blocks = grouped.lines.skip(1).toList();
      expect(blocks[0], contains('phone  (1 version)'));
      expect(blocks[1], contains('a.md'));
      expect(blocks[2], contains('laptop  (2 versions)'),
          reason: 'same writer, same time: one commit invocation');
      expect(blocks[3], contains('a.md'));
      expect(blocks[4], contains('b.md'));

      final filtered = await h.run(['log', '--author', 'laptop', '-n', '1']);
      expect(filtered.lines.skip(1), hasLength(1));
      expect(filtered.lines[1], contains('a.md'));
    });
  });

  group('status (R13, R16)', () {
    test('status counts files with a divergent line, not branches', () async {
      // a.md: two divergent branches.
      h.write('a.md', 'A');
      await h.run(['commit']);
      h.write('a.md', 'C');
      await h.run(['commit']);
      await h.putPatch('a.md', 'A', 'D', ts: 1700000001500, by: 'phone');
      await h.putPatch('a.md', 'A', 'T', ts: 1700000001600, by: 'tablet');
      // b.md: an archived branch (rollback).
      h.write('b.md', 'A');
      await h.run(['commit']);
      h.write('b.md', 'B');
      await h.run(['commit']);
      await h.run(['restore', 'b.md', 'HEAD~1']);
      h.write('b.md', 'E');
      await h.run(['commit']);
      // c.md: a merged branch.
      h.write('c.md', 'A');
      await h.run(['commit']);
      h.write('c.md', 'C');
      await h.run(['commit']);
      await h.putPatch('c.md', 'A', 'D', ts: 1700000001500, by: 'phone');
      await h.run(['merge', 'c.md', sha('D'), '--take', 'live']);
      // d.md: nothing.
      h.write('d.md', 'A');
      await h.run(['commit']);

      final res = await h.run(['status']);
      expect(res.code, 0, reason: res.stderr);
      expect(res.stdout, contains('1 file(s) with a divergent line:'));
      expect(res.stdout, contains('a.md'));
      expect(
          res.stdout, contains('branch ${sha('D').substring(0, 12)}  (phone)'));
      expect(res.stdout,
          contains('branch ${sha('T').substring(0, 12)}  (tablet)'));
      expect(res.stdout, contains('forked from ${sha('A').substring(0, 12)}'));
      expect(res.stdout, isNot(contains('b.md')));
      expect(res.stdout, isNot(contains('c.md')));
      expect(res.stdout, isNot(contains('d.md')));
    });
  });

  group('honesty (R14)', () {
    test('the help says where the model is not git', () async {
      final help = await h.run(['--help']);
      expect(help.code, 0);
      expect(help.stdout, contains('approximate between files'));
      expect(help.stdout, contains('no named branches'));
      expect(help.stdout, contains('no message'));
      expect(help.stdout, contains('never a two-parent record'));
      expect(help.stdout, contains('rests on device clocks'));
    });
  });
}

/// Two distinct texts whose sha256 hashes share their first [n] hex
/// characters — found by brute force, which for n = 5 takes a few thousand
/// hashes.
(String, String) _sharingPrefix(int n) {
  final seen = <String, String>{};
  for (var i = 0;; i++) {
    final text = 'candidate $i\n';
    final prefix = sha(text).substring(0, n);
    final other = seen[prefix];
    if (other != null) return (other, text);
    seen[prefix] = text;
  }
}
