import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../cli/hist_cli.dart';
import '../cli/hist_folder.dart';
import '../hist/hist.dart';

class BridgeError implements Exception {
  BridgeError(this.code, this.message);
  final String code;
  final String message;
}

/// One request over the existing history library/CLI, never a daemon.
class HistBridge {
  HistBridge({int Function()? now})
      : now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final int Function() now;

  Future<Map<String, Object?>> handle(Map<String, Object?> request) async {
    try {
      final root = _string(request, 'folder');
      if (!p.isAbsolute(root) || !Directory(root).existsSync()) {
        throw BridgeError(
            'invalid_folder', 'Choose an existing absolute vault folder.');
      }
      final resolved = Directory(root).resolveSymbolicLinksSync();
      final extensions = request['extensions'] == null
          ? <String>['.md']
          : (request['extensions'] as List).cast<String>();
      final stateDir = request['stateDir'] as String? ??
          p.join(resolved, '.hist-state', 'obsidian');
      if (!p.isAbsolute(stateDir)) {
        throw BridgeError(
            'invalid_state', 'Use an absolute local state directory.');
      }
      final folder = HistFolder(
        root: resolved,
        stateDir: stateDir,
        writerName: request['writer'] as String? ??
            'Obsidian@${Platform.localHostname}',
        extensions: extensions,
        now: now,
      );
      _noLinks(folder.root, '.hist');
      final stateRel = p.relative(folder.stateDir, from: folder.root);
      final stateInVault = p.isWithin(folder.root, folder.stateDir) ||
          p.equals(folder.root, folder.stateDir);
      if (stateInVault &&
          stateRel != '.hist-state' &&
          !stateRel.startsWith('.hist-state${p.separator}')) {
        throw BridgeError('invalid_state',
            'Local draft state must be outside the vault or under .hist-state/.');
      }
      if (stateInVault) _noLinks(folder.root, stateRel);
      _noLinks(folder.stateDir, 'heads.json');
      final rawPath = request['path'] as String?;
      final path = rawPath == null ? null : _path(folder, rawPath);
      final data =
          await _dispatch(folder, _string(request, 'op'), path, request);
      return {'ok': true, 'data': data};
    } on BridgeError catch (e) {
      return _failure(e.code, e.message);
    } on BrokenVersion catch (e) {
      return _failure('broken_version', e.toString());
    } on HistRefError catch (e) {
      return _failure('invalid_revision', e.toString());
    } on HistCliError catch (e) {
      return _failure('history_error', e.message);
    } on FileSystemException catch (e) {
      return _failure('io_error', e.toString());
    } catch (e) {
      return _failure('invalid_request', e.toString());
    }
  }

  static Map<String, Object?> _failure(String code, String message) => {
        'ok': false,
        'error': {'code': code, 'message': message}
      };

  static String _string(Map<String, Object?> request, String key) {
    final value = request[key];
    if (value is! String || value.isEmpty) {
      throw BridgeError('invalid_request', 'A nonempty $key is required.');
    }
    return value;
  }

  static void _noLinks(String root, String rel) {
    var current = root;
    for (final part in p.split(rel)) {
      current = p.join(current, part);
      if (FileSystemEntity.typeSync(current, followLinks: false) ==
          FileSystemEntityType.link) {
        throw BridgeError(
            'unsafe_path', 'History operations do not follow symlinks: $rel');
      }
    }
  }

  static String _path(HistFolder folder, String input,
      {bool requireTracked = true}) {
    if (input.contains('\\') ||
        input.contains('\u0000') ||
        p.posix.isAbsolute(input) ||
        input.split('/').any((s) => s == '..' || s == '.' || s.isEmpty)) {
      throw BridgeError(
          'unsafe_path', 'Use a vault-relative file path: $input');
    }
    final rel = folder.relativize(input, cwd: folder.root);
    _noLinks(folder.root, rel);
    _noLinks(folder.root, p.join('.hist', rel));
    _noLinks(folder.stateDir, p.join('merge', '$rel.draft'));
    _noLinks(folder.stateDir, p.join('merge', '$rel.json'));
    final history = Directory(p.join(folder.root, '.hist', rel));
    if (history.existsSync() &&
        history.listSync(followLinks: false).any((e) => e is Link)) {
      throw BridgeError(
          'unsafe_path', 'History records cannot be symlinks: $input');
    }
    if (requireTracked && !folder.tracks(rel)) {
      throw BridgeError('not_tracked',
          '$input is excluded by history extensions or ignore rules.');
    }
    return rel;
  }

  static Map<String, Object?> _branch(HistBranch branch, HistGraph graph) => {
        'leaf': branch.leaf,
        'kind': branch.kind.name,
        'writers': branch.writers,
        'hashes': branch.hashes,
        'fork': forkPoint(graph, branch.leaf),
      };

  static Map<String, Object?> _entry(HistLogEntry entry, HistGraph graph) => {
        'path': entry.path,
        'hash': entry.hash,
        'timestamp': entry.timestampMillis,
        'writers': entry.writers,
        'live': entry.isLive,
        'snapshot': entry.isSnapshot,
        'broken': graph.versions[entry.hash]?.broken ?? true,
        'parents': [
          for (final e in graph.edges)
            if (e.version == entry.hash) e.prev
        ],
        'branch': entry.branch == null ? null : _branch(entry.branch!, graph),
      };

  Future<Map<String, Object?>> _dispatch(HistFolder folder, String op,
      String? path, Map<String, Object?> request) async {
    if (op == 'log') return _log(folder, path, request);
    if (op == 'status') return _status(folder);
    if (op == 'commit') {
      if (path == null) {
        for (final item in await folder.everything()) {
          _path(folder, item);
        }
      }
      final message = await _cli(folder, ['commit', if (path != null) path]);
      return {'message': message};
    }
    if (path == null) {
      throw BridgeError('invalid_request', '$op requires a path.');
    }
    switch (op) {
      case 'show':
        return _content(folder, path, request['ref'] as String? ?? 'HEAD');
      case 'diff':
        final left = await _content(
            folder, path, request['left'] as String? ?? 'HEAD~1');
        final right =
            await _content(folder, path, request['right'] as String? ?? 'HEAD');
        final a = left['content'] as String;
        final b = right['content'] as String;
        return {
          'left': left,
          'right': right,
          'unified': unifiedDiff(a, b,
              labelA: 'a/$path (${left['hash']})',
              labelB: 'b/$path (${right['hash']})'),
          'edits': [
            for (final e in lineDiff(a, b)) {'op': e.op.name, 'lines': e.lines}
          ],
        };
      case 'blame':
        final graph = await folder.graphOf(path);
        final hash = resolveRef(graph, request['ref'] as String? ?? 'HEAD');
        final lines = await blame(folder.reader, graph, path, hash);
        return {
          'hash': hash,
          'lines': [
            for (var i = 0; i < lines.length; i++)
              {
                'line': i + 1,
                'text': lines[i].text,
                'hash': lines[i].hash,
                'writers': lines[i].writers,
                'timestamp': lines[i].timestampMillis,
              }
          ]
        };
      case 'restore':
        _guard(folder, path, request);
        final target = await _content(folder, path, _string(request, 'ref'));
        await _preserve(folder, path);
        _guard(folder, path, request);
        return {
          'message':
              await _cli(folder, ['restore', path, target['hash'] as String])
        };
      case 'rename':
        return _rename(folder, path, _string(request, 'newPath'));
      case 'draft':
        return _draft(folder, path);
      case 'draft-save':
        final draft = folder.state.readDraft(path);
        if (draft == null) {
          throw BridgeError('no_draft', '$path has no merge draft.');
        }
        if (draft.$1.path != path) {
          throw BridgeError(
              'invalid_state', 'Draft metadata belongs to another path.');
        }
        final text = request['text'];
        if (text is! String) {
          throw BridgeError('invalid_request', 'Draft text is required.');
        }
        folder.state.writeDraft(draft.$1, text);
        return {'saved': true};
      case 'merge-abort':
        return {
          'message': await _cli(folder, ['merge', path, '--abort'])
        };
      case 'merge-start':
      case 'merge-take':
        _guard(folder, path, request);
        final branch = _string(request, 'branch');
        // Materialize the branch before preserving live content or writing anything.
        await _content(folder, path, branch);
        await _preserve(folder, path);
        _guard(folder, path, request);
        final args = ['merge', path, branch];
        if (op == 'merge-take') {
          final take = _string(request, 'take');
          if (take != 'live' && take != 'branch') {
            throw BridgeError('invalid_request', 'Choose live or branch.');
          }
          args.addAll(['--take', take]);
        }
        final message = await _cli(folder, args);
        return op == 'merge-start'
            ? _draft(folder, path)
            : {'message': message};
      case 'merge-continue':
        _guard(folder, path, request);
        final existing = folder.state.readDraft(path);
        if (existing == null) {
          throw BridgeError('no_draft', '$path has no merge draft.');
        }
        if (existing.$1.path != path) {
          throw BridgeError(
              'invalid_state', 'Draft metadata belongs to another path.');
        }
        if (folder.liveHash(path) != existing.$1.live) {
          throw BridgeError('live_changed',
              'The live note changed since this draft was prepared. Abort and merge again.');
        }
        final text = request['text'];
        if (text is! String) {
          throw BridgeError(
              'invalid_request', 'Resolved draft text is required.');
        }
        if (hasConflictRegion(text)) {
          throw BridgeError('unresolved',
              'Resolve all conflict markers before applying the draft.');
        }
        folder.state.writeDraft(existing.$1, text);
        return {
          'message': await _cli(folder, ['merge', path, '--continue'])
        };
      default:
        throw BridgeError('invalid_request', 'Unknown history operation: $op');
    }
  }

  Future<Map<String, Object?>> _log(
      HistFolder folder, String? path, Map<String, Object?> request) async {
    final paths = path == null ? await folder.historyPaths() : [path];
    final entries = <Map<String, Object?>>[];
    HistGraph? selected;
    for (final item in paths) {
      _path(folder, item);
      final graph = await folder.graphOf(item);
      if (path != null) selected = graph;
      entries.addAll(logOf(graph, path: item, all: true)
          .entries
          .map((e) => _entry(e, graph)));
    }
    if (path == null) {
      entries.sort((a, b) {
        final t = (b['timestamp'] as int).compareTo(a['timestamp'] as int);
        if (t != 0) return t;
        final byPath = (a['path'] as String).compareTo(b['path'] as String);
        return byPath != 0
            ? byPath
            : (a['hash'] as String).compareTo(b['hash'] as String);
      });
    }
    final filter = request['filter'] as String? ?? '';
    final author = request['author'] as String?;
    final since = (request['since'] as num?)?.toInt();
    final limit = (request['limit'] as num?)?.toInt() ?? 200;
    if (limit < 1 || limit > 10000) {
      throw BridgeError(
          'invalid_request', 'Limit must be between 1 and 10000.');
    }
    final kept = entries
        .where((e) =>
            (e['path'] as String)
                .toLowerCase()
                .contains(filter.toLowerCase()) &&
            (author == null ||
                author.isEmpty ||
                (e['writers'] as List).contains(author)) &&
            (since == null || (e['timestamp'] as int) >= since))
        .toList();
    Map<String, Object?> link(HistRenameLink l) =>
        {'path': l.path, 'hash': l.versionHash, 'timestamp': l.timestampMillis};
    return {
      'path': path,
      'entries': kept.take(limit).toList(),
      'total': kept.length,
      'approximate': path == null,
      'liveHash': path == null ? null : folder.liveHash(path),
      'exists': path != null && folder.fileOf(path).existsSync(),
      'unrecorded': path != null &&
          folder.liveHash(path) != null &&
          !(selected?.versions.containsKey(folder.liveHash(path)) ?? false),
      'unsavedAfter': selected?.unsavedChangesAfter,
      'branches': selected == null
          ? <Object>[]
          : [for (final b in selected.branches) _branch(b, selected)],
      'renamedFrom': selected?.renamedFrom.map(link).toList() ?? [],
      'renamedTo': selected?.renamedTo.map(link).toList() ?? [],
    };
  }

  Future<Map<String, Object?>> _content(
      HistFolder folder, String path, String ref) async {
    if (ref == 'WORKING') {
      final bytes = folder.liveBytes(path);
      if (bytes == null) throw BridgeError('absent', '$path is deleted.');
      final text = decodeUtf8Text(bytes);
      if (text == null) {
        throw BridgeError('not_text', '$path contains binary content.');
      }
      return {'hash': sha256Hex(bytes), 'content': text};
    }
    final graph = await folder.graphOf(path);
    final hash = resolveRef(graph, ref);
    return {
      'hash': hash,
      'content': utf8.decode(await folder.reader.materialize(path, hash))
    };
  }

  static void _guard(
      HistFolder folder, String path, Map<String, Object?> request) {
    if (!request.containsKey('expectedLive')) {
      throw BridgeError(
          'invalid_request', 'A previewed expectedLive hash is required.');
    }
    if (folder.liveHash(path) != request['expectedLive']) {
      throw BridgeError('live_changed',
          'The live note changed after the preview. Refresh and review it again.');
    }
  }

  Future<void> _preserve(HistFolder folder, String path) async {
    final bytes = folder.liveBytes(path);
    if (bytes == null) return;
    if (decodeUtf8Text(bytes) == null) {
      throw BridgeError('not_text', 'Cannot replace binary content.');
    }
    await _cli(folder, ['commit', path]);
  }

  Future<Map<String, Object?>> _rename(
      HistFolder folder, String oldPath, String input) async {
    final newPath = _path(folder, input, requireTracked: false);
    final bytes = folder.liveBytes(newPath);
    if (!folder.tracks(newPath) ||
        bytes == null ||
        decodeUtf8Text(bytes) == null) {
      if (await folder.hasHistory(oldPath)) {
        await _cli(folder, ['commit', oldPath]);
      }
      return {'recorded': false};
    }
    if (await folder.hasHistory(oldPath)) {
      await folder.writer
          .commit(oldPath, bytes, previousHash: folder.state.head(oldPath));
      await folder.writer.recordRename(oldPath, newPath, bytes);
      folder.state.forgetHead(oldPath);
      folder.state.setHead(newPath, sha256Hex(bytes));
    } else {
      await _cli(folder, ['commit', newPath]);
    }
    return {'recorded': true};
  }

  Future<Map<String, Object?>> _draft(HistFolder folder, String path) async {
    final draft = folder.state.readDraft(path);
    if (draft == null) return {'exists': false};
    final meta = draft.$1;
    if (meta.path != path) {
      throw BridgeError(
          'invalid_state', 'Draft metadata belongs to another path.');
    }
    return {
      'exists': true,
      ...meta.toJson(),
      'text': draft.$2,
      'liveHash': folder.liveHash(path),
      'baseContent': meta.base == null
          ? ''
          : (await _content(folder, path, meta.base!))['content'],
      'liveContent': (await _content(folder, path, meta.live))['content'],
      'branchContent': (await _content(folder, path, meta.branch))['content'],
    };
  }

  Future<Map<String, Object?>> _status(HistFolder folder) async {
    final divergent = <Object>[];
    final unrecorded = <String>[];
    final paths = await folder.everything();
    for (final path in paths) {
      _path(folder, path);
      final graph = await folder.graphOf(path);
      final branches =
          graph.branches.where((b) => b.kind == HistBranchKind.divergent);
      if (branches.isNotEmpty) {
        divergent.add({
          'path': path,
          'branches': [for (final b in branches) _branch(b, graph)]
        });
      }
      final live = folder.liveHash(path);
      if (live != null && !graph.versions.containsKey(live)) {
        unrecorded.add(path);
      }
    }
    return {
      'divergent': divergent,
      'unrecorded': unrecorded,
      'paths': paths,
      'drafts': [for (final d in folder.state.drafts()) d.toJson()]
    };
  }

  Future<String> _cli(HistFolder folder, List<String> args) async {
    final output = _ByteSink();
    final errors = StringBuffer();
    final cli = HistCli(
        out: output,
        err: errors,
        now: now,
        hostname: folder.writerName,
        environment: const {});
    final code = await cli.run([
      '--folder',
      folder.root,
      '--state-dir',
      folder.stateDir,
      '--writer',
      folder.writerName,
      '--extensions',
      folder.writer.extensions.join(','),
      ...args,
    ], cwd: folder.root);
    if (code != 0) throw BridgeError('history_error', errors.toString().trim());
    return utf8.decode(output.bytes.takeBytes()).trim();
  }
}

class _ByteSink implements Sink<List<int>> {
  final bytes = BytesBuilder(copy: false);
  @override
  void add(List<int> data) => bytes.add(data);
  @override
  void close() {}
}
