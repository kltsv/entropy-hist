import 'dart:io';

import 'package:entropy_hist/entropy_hist.dart';
import 'package:entropy_hist/src/bridge/hist_bridge.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../harness.dart';

void main() {
  late CliHarness h;
  late HistBridge bridge;
  setUp(() {
    h = CliHarness();
    bridge = HistBridge(now: () => h.clock++);
  });
  tearDown(() => h.dispose());

  Future<Map<String, dynamic>> call(String op,
      [Map<String, Object?> args = const {}]) async {
    final response = await bridge
        .handle({'folder': h.root, 'writer': 'laptop', 'op': op, ...args});
    expect(response['ok'], true, reason: '$response');
    return (response['data'] as Map).cast<String, dynamic>();
  }

  test('verified read surface preserves exact text and graph order', () async {
    h.write('a.md', 'один\nlast');
    await call('commit', {'path': 'a.md'});
    h.write('a.md', 'один\nnew');
    await call('commit', {'path': 'a.md'});
    final log = await call('log', {'path': 'a.md'});
    expect((log['entries'] as List).map((e) => e['hash']),
        [sha('один\nnew'), sha('один\nlast')]);
    expect((await call('show', {'path': 'a.md', 'ref': 'HEAD~1'}))['content'],
        'один\nlast');
    final diff =
        await call('diff', {'path': 'a.md', 'left': 'HEAD~1', 'right': 'HEAD'});
    expect(diff['unified'], contains('-last'));
    expect(diff['unified'], contains('+new'));
    final blamed = await call('blame', {'path': 'a.md'});
    expect((blamed['lines'] as List).last['hash'], sha('один\nnew'));
  });

  test('folder filters, nested ignores and deleted files', () async {
    h.write('a.md', 'A');
    h.write('b.md', 'B');
    h.write('nested/.histignore', 'skip.md');
    h.write('nested/skip.md', 'ignored');
    await call('commit');
    h.delete('b.md');
    await call('commit', {'path': 'b.md'});
    final log =
        await call('log', {'filter': 'b.md', 'author': 'laptop', 'limit': 1});
    expect(log['approximate'], true);
    expect((log['entries'] as List).single['path'], 'b.md');
    expect(await h.store.listPaths(), ['a.md', 'b.md']);
    expect((await call('log', {'since': h.clock + 100}))['entries'], isEmpty);
  });

  test('corruption and unsafe paths fail without exposing content', () async {
    h.write('a.md', 'original');
    await call('commit', {'path': 'a.md'});
    final file = Directory(p.join(h.root, '.hist', 'a.md'))
        .listSync()
        .whereType<File>()
        .first;
    file.writeAsStringSync(
        file.readAsStringSync().replaceFirst('original', 'corrupt'));
    final broken = await bridge.handle({
      'folder': h.root,
      'op': 'show',
      'path': 'a.md',
      'ref': sha('original')
    });
    expect(broken['ok'], false);
    expect((broken['error'] as Map)['code'], 'broken_version');
    expect(broken.containsKey('data'), false);
    final outside = File(p.join(h.tmp.path, 'outside.md'))
      ..writeAsStringSync('safe');
    Link(p.join(h.root, 'link.md')).createSync(outside.path);
    for (final path in ['../outside.md', 'link.md', '.hist-state/private.md']) {
      expect(
          (await bridge
              .handle({'folder': h.root, 'op': 'commit', 'path': path}))['ok'],
          false);
    }
    expect(outside.readAsStringSync(), 'safe');
    file.deleteSync();
    Link(file.path).createSync(outside.path);
    final linked = await bridge.handle({
      'folder': h.root,
      'op': 'show',
      'path': 'a.md',
      'ref': sha('original')
    });
    expect((linked['error'] as Map)['code'], 'unsafe_path');
    final relativeState = await bridge
        .handle({'folder': h.root, 'op': 'status', 'stateDir': 'relative'});
    expect((relativeState['error'] as Map)['code'], 'invalid_state');
  });

  test('restore keeps unrecorded text and refuses a stale preview', () async {
    h.write('a.md', 'A');
    await call('commit', {'path': 'a.md'});
    h.write('a.md', 'B');
    await call('commit', {'path': 'a.md'});
    h.write('a.md', 'C');
    await call(
        'restore', {'path': 'a.md', 'ref': sha('A'), 'expectedLive': sha('C')});
    expect(h.read('a.md'), 'A');
    expect((await call('show', {'path': 'a.md', 'ref': sha('C')}))['content'],
        'C');
    final before = h.mirrorSnapshot();
    final stale = await bridge.handle({
      'folder': h.root,
      'op': 'restore',
      'path': 'a.md',
      'ref': sha('B'),
      'expectedLive': sha('C')
    });
    expect(stale['ok'], false);
    expect((stale['error'] as Map)['code'], 'live_changed');
    expect(h.mirrorSnapshot(), before);
    expect(h.read('a.md'), 'A');
  });

  test('rename records the pending edit and keeps links; deletion is recorded',
      () async {
    h.write('old.md', 'old');
    await call('commit', {'path': 'old.md'});
    h.write('old.md', 'edited');
    h.file('old.md').renameSync(h.file('new.md').path);
    await call('rename', {'path': 'old.md', 'newPath': 'new.md'});
    expect(
        (await call(
            'show', {'path': 'old.md', 'ref': sha('edited')}))['content'],
        'edited');
    expect((await call('log', {'path': 'new.md'}))['renamedFrom'], isNotEmpty);
    h.delete('new.md');
    await call('commit', {'path': 'new.md'});
    expect((await h.headers('new.md')).last.type, HistFileType.deleted);
  });

  Future<void> fork() async {
    h.write('a.md', 'base\n');
    await call('commit', {'path': 'a.md'});
    h.write('a.md', 'ours\n');
    await call('commit', {'path': 'a.md'});
    await h.putPatch('a.md', 'base\n', 'theirs\n', ts: h.clock++, by: 'phone');
  }

  test('merge draft is persistent and unresolved/stale completion is refused',
      () async {
    await fork();
    final draft = await call('merge-start', {
      'path': 'a.md',
      'branch': sha('theirs\n'),
      'expectedLive': sha('ours\n')
    });
    expect(draft['baseContent'], 'base\n');
    expect(draft['text'], contains('<<<<<<<'));
    expect((await call('status'))['drafts'], hasLength(1));
    final unresolved = await bridge.handle({
      'folder': h.root,
      'op': 'merge-continue',
      'path': 'a.md',
      'expectedLive': sha('ours\n'),
      'text': draft['text']
    });
    expect(unresolved['ok'], false);
    expect(h.read('a.md'), 'ours\n');
    await call('draft-save', {'path': 'a.md', 'text': 'resolved\n'});
    expect((await call('draft', {'path': 'a.md'}))['text'], 'resolved\n');
    h.write('a.md', 'racing\n');
    final stale = await bridge.handle({
      'folder': h.root,
      'op': 'merge-continue',
      'path': 'a.md',
      'expectedLive': sha('ours\n'),
      'text': 'resolved\n'
    });
    expect((stale['error'] as Map)['code'], 'live_changed');
    h.write('a.md', 'ours\n');
    await call('merge-continue',
        {'path': 'a.md', 'expectedLive': sha('ours\n'), 'text': 'resolved\n'});
    expect(h.read('a.md'), 'resolved\n');
    expect((await call('status'))['divergent'], isEmpty);
    expect((await call('status'))['drafts'], isEmpty);
  });

  test('take live settles without a live write and abort touches only draft',
      () async {
    await fork();
    await call('merge-start', {
      'path': 'a.md',
      'branch': sha('theirs\n'),
      'expectedLive': sha('ours\n')
    });
    final before = h.mirrorSnapshot();
    await call('merge-abort', {'path': 'a.md'});
    expect(h.mirrorSnapshot(), before);
    expect(h.read('a.md'), 'ours\n');
    await call('merge-take', {
      'path': 'a.md',
      'branch': sha('theirs\n'),
      'take': 'live',
      'expectedLive': sha('ours\n')
    });
    expect(h.read('a.md'), 'ours\n');
    expect((await call('status'))['divergent'], isEmpty);
    await h.putPatch('a.md', 'base\n', 'third\n', ts: h.clock++, by: 'tablet');
    await call('merge-take', {
      'path': 'a.md',
      'branch': sha('third\n'),
      'take': 'branch',
      'expectedLive': sha('ours\n')
    });
    expect(h.read('a.md'), 'third\n');
    expect((await call('status'))['divergent'], isEmpty);
  });
}
