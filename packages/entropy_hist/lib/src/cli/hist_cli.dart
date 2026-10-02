import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import '../hist/hist.dart';
import 'package:path/path.dart' as p;

import 'hist_folder.dart';
import 'hist_state.dart';

/// Exit statuses (`vault_hist_cli` — Outputs).
const int exitOk = 0;

/// Something was wrong with the history or the request.
const int exitFailure = 1;

/// A usage error.
const int exitUsage = 64;

/// The history command line (`vault_hist_cli`): a git-shaped surface over a
/// bare folder through the `vault_hist` library alone. Both entry points —
/// the `hist` binary and `entropyd hist` — run this class; the daemon
/// only decides which folder and which writer name.
class HistCli {
  HistCli({
    required this.out,
    required this.err,
    int Function()? now,
    Map<String, String>? environment,
    String? hostname,
  })  : now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
        environment = environment ?? Platform.environment,
        hostname = hostname ?? Platform.localHostname;

  /// Standard output — bytes, because `show` emits content verbatim.
  final Sink<List<int>> out;

  /// Standard error — text for a person.
  final StringSink err;

  /// Injected clock (UTC epoch ms): one `commit` stamps its whole batch with
  /// one reading (R2').
  final int Function() now;

  final Map<String, String> environment;
  final String hostname;

  static const version = '0.1.0';

  /// The environment variable naming this device in `writer:` headers when
  /// `--writer` is not given; the hostname otherwise.
  static const writerEnv = 'HIST_WRITER';

  static const usage = '''
hist — history over a folder, git-shaped, no daemon required

usage: hist [--folder <dir>] [--writer <name>] [--state-dir <dir>]
            [--extensions .md,.txt | '*'] <command> [args]

commands:
  commit [<path>…]                 record the named paths, or everything
                                   that differs from the graph
  log [<path>…] [--all] [--since <date>] [--author <writer>] [-n <count>]
      [--group]                    one file's lines; with no path, the
                                   folder-wide timeline (approximate);
                                   --group folds one commit's versions
  show <path> [<rev>]              print a version's content (default HEAD)
  restore <path> <rev>             write a version over the live file
  diff <path> [<rev>] [<rev>]      unified diff (default HEAD~1 HEAD)
  blame <path> [<rev>]             who wrote each line, and in which version
  merge <path> <branch> [--take live|branch]
  merge <path> --continue | --abort
                                   settle a divergent line: take a side, or
                                   compose a diff3 draft in .hist-state/
  status                           files with a divergent line, unfinished
                                   merges, unsaved live changes

revisions: a full hash; an unambiguous prefix (4+ characters — an ambiguous
one lists its candidates, never guesses); HEAD (the live content's version);
HEAD~n; @{YYYY-MM-DD[THH:MM]} (the version live at that instant).

the folder is the nearest directory at or above the working directory that
holds .hist/ — or the working directory itself. The writer name comes from
--writer, then \$HIST_WRITER, then the hostname; it must be stable and unique
per device.

where this is not git, and why:
  - history is per file: no commit spans files, and there is no index and
    no message — the daemon records most versions automatically and can
    invent none, and a version is always a whole file. "Same writer, same
    time" is one `commit` invocation (log --group).
  - there are no named branches and no tags: a line is its leaf hash. A name
    would be a mutable pointer inside an append-only, conflict-free folder.
  - the folder-wide log is approximate between files: within one file the
    order is the graph's and exact; between files it rests on the recording
    devices' clocks, which are not authoritative.
  - a reconciliation is an ordinary single-parent version plus a `merged`
    marker — never a two-parent record. Reconstruction stays one chain.
  - a date address (@{…}) rests on device clocks.
  - nothing is ever rewritten: no rebase, amend, gc or prune.
''';

  // ---------------------------------------------------------------------------
  // Dispatch
  // ---------------------------------------------------------------------------

  Future<int> run(List<String> args, {required String cwd}) async {
    final ArgResults g;
    try {
      g = _globalParser().parse(args);
    } on FormatException catch (e) {
      return _usageError(e.message);
    }
    if (g.flag('version')) {
      _say(version);
      return exitOk;
    }
    if (g.flag('help')) {
      _say(usage);
      return exitOk;
    }
    if (g.rest.isEmpty) {
      _say(usage);
      return exitUsage;
    }
    final verb = g.rest.first;
    final rest = g.rest.sublist(1);
    try {
      switch (verb) {
        case 'help':
          _say(usage);
          return exitOk;
        case 'commit':
          return await _commit(rest, g, cwd);
        case 'log':
          return await _log(rest, g, cwd);
        case 'show':
          return await _show(rest, g, cwd);
        case 'restore':
          return await _restore(rest, g, cwd);
        case 'diff':
          return await _diff(rest, g, cwd);
        case 'blame':
          return await _blame(rest, g, cwd);
        case 'merge':
          return await _merge(rest, g, cwd);
        case 'status':
          return await _status(rest, g, cwd);
        default:
          return _usageError('unknown command: $verb');
      }
    } on FormatException catch (e) {
      return _usageError(e.message);
    } on HistCliError catch (e) {
      _fail(e.message);
      return e.usage ? exitUsage : exitFailure;
    } on HistRefError catch (e) {
      _fail(e.toString());
      return exitFailure;
    } on BrokenVersion catch (e) {
      _fail('broken: ${e.path} @ ${e.versionHash} — ${e.reason}');
      return exitFailure;
    }
  }

  // ---------------------------------------------------------------------------
  // Verbs
  // ---------------------------------------------------------------------------

  /// `commit [<path>…]` (R19, R2'): the named paths, or everything that
  /// differs from the graph, all stamped with one time.
  Future<int> _commit(List<String> args, ArgResults g, String cwd) async {
    final v = _verbParser().parse(args);
    final folder = _folder(g, v, cwd);
    final at = now();
    final explicit = v.rest.isNotEmpty;
    final paths = explicit
        ? [for (final a in v.rest) folder.relativize(a, cwd: cwd)]
        : await folder.everything();

    var recorded = 0;
    var failed = 0;
    for (final path in paths) {
      if (!folder.tracks(path)) {
        if (explicit) {
          _fail('$path: not tracked — the extension list or an ignore file '
              'excludes it');
          failed++;
        }
        continue;
      }
      final bytes = folder.liveBytes(path);
      if (bytes == null && !await folder.hasHistory(path)) {
        if (explicit) {
          _fail('$path: no such file');
          failed++;
        }
        continue;
      }
      if (bytes != null && decodeUtf8Text(bytes) == null) {
        if (explicit) _fail('$path: binary content is never versioned');
        continue;
      }
      final wrote = await folder.writer.commit(
        path,
        bytes,
        // What this machine last recorded or restored — consulted by the
        // library only ahead of the graph's guess, and only if the folder
        // holds it (`vault_hist` commit rules).
        previousHash: folder.state.head(path),
        at: at,
      );
      if (bytes == null) {
        folder.state.forgetHead(path);
        _say(wrote ? 'deleted   $path' : 'unchanged $path (absent)');
      } else {
        final hash = sha256Hex(bytes);
        folder.state.setHead(path, hash);
        if (wrote) {
          final asRoot = await _recordedAsNewRoot(folder, path, hash);
          _say('recorded  $path  ${_short(hash)}'
              '${asRoot ? '  (as a new root — no base could be named; '
                  'several lines were open: see `hist merge`)' : ''}');
        } else {
          _say('unchanged $path');
        }
      }
      if (wrote) recorded++;
    }
    _say('${paths.length} path(s) checked, $recorded recorded');
    return failed > 0 ? exitFailure : exitOk;
  }

  /// Whether the version just written for [hash] became a root snapshot in
  /// a folder that already held other versions — the library's documented
  /// outcome when no base could be named.
  Future<bool> _recordedAsNewRoot(
      HistFolder folder, String path, String hash) async {
    final headers = await folder.store.listHeaders(path);
    final mine = headers.where((h) => h.version == hash).toList();
    if (mine.isEmpty || mine.any((h) => h.type == HistFileType.patch)) {
      return false;
    }
    return headers.any((h) => h.version != null && h.version != hash);
  }

  /// `log [<path>…] [--all] [--since] [--author] [-n]` (R2).
  Future<int> _log(List<String> args, ArgResults g, String cwd) async {
    final parser = _verbParser()
      ..addFlag('all',
          negatable: false, help: 'include every branch, with kind and writers')
      ..addOption('since', help: 'only versions at or after this date')
      ..addOption('author', help: 'only versions by this writer')
      ..addOption('limit', abbr: 'n', help: 'at most this many entries')
      ..addFlag('group',
          negatable: false,
          help: 'folder-wide: fold versions with the same writer and time — '
              'one commit invocation — into one block');
    final v = parser.parse(args);
    final folder = _folder(g, v, cwd);
    final since = _parseSince(v.option('since'));
    final limit = _parseLimit(v.option('limit'));
    final author = v.option('author');
    if (v.rest.isEmpty) {
      return _folderLog(folder,
          all: v.flag('all'),
          since: since,
          author: author,
          limit: limit,
          group: v.flag('group'));
    }

    for (final arg in v.rest) {
      final path = folder.relativize(arg, cwd: cwd);
      final graph = await folder.graphOf(path);
      if (graph.versions.isEmpty) {
        _say('$path: no history');
        continue;
      }
      final log = logOf(graph, path: path, all: v.flag('all'))
          .where(sinceMillis: since, author: author, limit: limit);
      _renderLog(log, graph, exists: folder.fileOf(path).existsSync());
    }
    return exitOk;
  }

  /// The folder-wide log (R6): one timeline merging every tracked file's
  /// versions, newest first, every entry naming its path and writer. It is
  /// **explicitly approximate and says so** — within one file the order is
  /// the graph's; between files it rests on device clocks — and it is never
  /// presented as commits. `--group` folds versions with the same writer and
  /// the same time: exactly what one `commit` invocation wrote (R2'), never
  /// a window.
  Future<int> _folderLog(
    HistFolder folder, {
    required bool all,
    int? since,
    String? author,
    int? limit,
    required bool group,
  }) async {
    var entries = <HistLogEntry>[];
    for (final path in await folder.historyPaths()) {
      final graph = await folder.graphOf(path);
      if (graph.versions.isEmpty) continue;
      entries.addAll(logOf(graph, path: path, all: all).entries);
    }
    entries.sort((a, b) {
      final byTime = b.timestampMillis.compareTo(a.timestampMillis);
      if (byTime != 0) return byTime;
      final byPath = a.path.compareTo(b.path);
      return byPath != 0 ? byPath : a.hash.compareTo(b.hash);
    });
    if (since != null) {
      entries = entries.where((e) => e.timestampMillis >= since).toList();
    }
    if (author != null) {
      entries = entries.where((e) => e.writers.contains(author)).toList();
    }
    if (limit != null) entries = entries.take(limit).toList();

    _say('folder-wide log — approximate between files: within one file the '
        'order is the graph\'s and exact; between files it rests on the '
        'recording devices\' clocks, which are not authoritative. These are '
        'versions, not commits: history is per file.');
    if (entries.isEmpty) {
      _say('  (no versions)');
      return exitOk;
    }
    String describe(HistLogEntry e) {
      final branch = e.branch;
      return '${_short(e.hash)}  ${e.path}'
          '${branch != null ? '  (branch ${_short(branch.leaf)} ${branch.kind.name})' : ''}'
          '${e.isLive ? '  live' : ''}';
    }

    if (!group) {
      for (final e in entries) {
        _say('  ${_short(e.hash)}  ${_time(e.timestampMillis)}  '
            '${e.writers.join(', ')}  ${e.path}'
            '${e.branch != null ? '  (branch ${_short(e.branch!.leaf)} ${e.branch!.kind.name})' : ''}'
            '${e.isLive ? '  live' : ''}');
      }
      return exitOk;
    }
    // Same writer, same time: one invocation — a fact, not a heuristic.
    var i = 0;
    while (i < entries.length) {
      final head = entries[i];
      final key = (head.timestampMillis, head.writers.join(','));
      var j = i;
      while (j < entries.length &&
          (entries[j].timestampMillis, entries[j].writers.join(',')) == key) {
        j++;
      }
      // Milliseconds shown: the grouping key is the exact stamp, and two
      // invocations within one second must not look like one.
      _say('${_time(head.timestampMillis, withMillis: true)}  '
          '${head.writers.join(', ')}  '
          '(${j - i} version${j - i == 1 ? '' : 's'})');
      for (final e in entries.sublist(i, j)) {
        _say('  ${describe(e)}');
      }
      i = j;
    }
    return exitOk;
  }

  void _renderLog(HistLog log, HistGraph graph, {required bool exists}) {
    _say(log.path);
    if (log.unsavedChangesAfter != null) {
      _say('  (unsaved changes after ${_short(log.unsavedChangesAfter!)} — '
          'the live file is not a recorded version)');
    } else if (!log.hasPrimaryLine) {
      _say(exists
          ? '  (no live version — every line is a branch)'
          : '  (no live file — every line is a branch)');
    }
    HistBranch? current;
    for (final e in log.entries) {
      final branch = e.branch;
      if (branch != null && !identical(branch, current)) {
        current = branch;
        final fork = forkPoint(graph, branch.leaf);
        _say('  branch ${_short(branch.leaf)}  ${branch.kind.name}'
            '  (${branch.writers.join(', ')})'
            '${fork != null ? '  forked from ${_short(fork)}' : ''}'
            '${branch.endedAtMillis != null ? '  ended ${_time(branch.endedAtMillis!)}' : ''}');
      }
      final indent = branch == null ? '  ' : '    ';
      _say('$indent${_short(e.hash)}  ${_time(e.timestampMillis)}  '
          '${e.writers.join(', ')}'
          '${e.isLive ? '  live' : ''}'
          '${e.isSnapshot && !e.isLive ? '  snapshot' : ''}');
    }
  }

  /// `show <path> [<rev>]` (R3): the content, verified, or broken.
  Future<int> _show(List<String> args, ArgResults g, String cwd) async {
    final v = _verbParser().parse(args);
    final folder = _folder(g, v, cwd);
    if (v.rest.isEmpty || v.rest.length > 2) {
      throw HistCliError('usage: hist show <path> [<rev>]', usage: true);
    }
    final path = folder.relativize(v.rest.first, cwd: cwd);
    final ref = v.rest.length > 1 ? v.rest[1] : 'HEAD';
    final graph = await folder.graphOf(path);
    if (graph.versions.isEmpty) throw HistCliError('$path: no history');
    final hash = resolveRef(graph, ref);
    out.add(await folder.reader.materialize(path, hash));
    return exitOk;
  }

  /// `restore <path> <rev>`: the version over the live file; nothing is
  /// recorded — a restore to a known version is a pointer move.
  Future<int> _restore(List<String> args, ArgResults g, String cwd) async {
    final v = _verbParser().parse(args);
    final folder = _folder(g, v, cwd);
    if (v.rest.length != 2) {
      throw HistCliError('usage: hist restore <path> <rev>', usage: true);
    }
    final path = folder.relativize(v.rest.first, cwd: cwd);
    final graph = await folder.graphOf(path);
    if (graph.versions.isEmpty) throw HistCliError('$path: no history');
    final hash = resolveRef(graph, v.rest[1]);
    final bytes = await folder.reader.materialize(path, hash);
    folder.writeLive(path, bytes);
    folder.state.setHead(path, hash);
    _say('restored $path to ${_short(hash)}');
    return exitOk;
  }

  /// `diff <path> [<rev>] [<rev>]` (R4): a unified diff over two verified
  /// reconstructions — `HEAD~1 HEAD` by default, `<rev> HEAD` with one.
  Future<int> _diff(List<String> args, ArgResults g, String cwd) async {
    final v = _verbParser().parse(args);
    final folder = _folder(g, v, cwd);
    if (v.rest.isEmpty || v.rest.length > 3) {
      throw HistCliError('usage: hist diff <path> [<rev>] [<rev>]',
          usage: true);
    }
    final path = folder.relativize(v.rest.first, cwd: cwd);
    final graph = await folder.graphOf(path);
    if (graph.versions.isEmpty) throw HistCliError('$path: no history');
    final (refA, refB) = switch (v.rest.length) {
      1 => ('HEAD~1', 'HEAD'),
      2 => (v.rest[1], 'HEAD'),
      _ => (v.rest[1], v.rest[2]),
    };
    final a = resolveRef(graph, refA);
    final b = resolveRef(graph, refB);
    final textA = utf8.decode(await folder.reader.materialize(path, a));
    final textB = utf8.decode(await folder.reader.materialize(path, b));
    out.add(utf8.encode(unifiedDiff(
      textA,
      textB,
      labelA: 'a/$path (${_short(a)})',
      labelB: 'b/$path (${_short(b)})',
    )));
    return exitOk;
  }

  /// `blame <path> [<rev>]` (R5): each line with the version and writer
  /// that introduced it.
  Future<int> _blame(List<String> args, ArgResults g, String cwd) async {
    final v = _verbParser().parse(args);
    final folder = _folder(g, v, cwd);
    if (v.rest.isEmpty || v.rest.length > 2) {
      throw HistCliError('usage: hist blame <path> [<rev>]', usage: true);
    }
    final path = folder.relativize(v.rest.first, cwd: cwd);
    final graph = await folder.graphOf(path);
    if (graph.versions.isEmpty) throw HistCliError('$path: no history');
    final hash = resolveRef(graph, v.rest.length > 1 ? v.rest[1] : 'HEAD');
    final lines = await blame(folder.reader, graph, path, hash);
    final width = lines.fold<int>(
        0,
        (w, l) =>
            l.writers.join(',').length > w ? l.writers.join(',').length : w);
    for (final line in lines) {
      final text = line.text.endsWith('\n')
          ? line.text.substring(0, line.text.length - 1)
          : line.text;
      _say('${_short(line.hash)}  ${line.writers.join(',').padRight(width)}  '
          '${_time(line.timestampMillis)}  $text');
    }
    return exitOk;
  }

  /// The three forms of `merge` (R8–R13, R15, R17): settle a branch by
  /// taking a side (`--take live|branch`), compose a `diff3` draft, or
  /// finish (`--continue`) / discard (`--abort`) one.
  Future<int> _merge(List<String> args, ArgResults g, String cwd) async {
    final parser = _verbParser()
      ..addOption('take',
          allowed: ['live', 'branch'],
          help: 'settle by taking one side whole instead of composing')
      ..addFlag('continue', negatable: false, help: 'commit the resolved draft')
      ..addFlag('abort', negatable: false, help: 'discard the draft');
    final v = parser.parse(args);
    final folder = _folder(g, v, cwd);
    if (v.rest.isEmpty) {
      throw HistCliError(
          'usage: hist merge <path> <branch> [--take live|branch] | '
          'hist merge <path> --continue | --abort',
          usage: true);
    }
    final path = folder.relativize(v.rest.first, cwd: cwd);
    if (v.flag('abort')) return _mergeAbort(folder, path);
    if (v.flag('continue')) return await _mergeContinue(folder, path);
    if (v.rest.length != 2) {
      throw HistCliError('merge: name the branch to settle (a revision on it)',
          usage: true);
    }

    final graph = await folder.graphOf(path);
    if (graph.versions.isEmpty) throw HistCliError('$path: no history');
    if (graph.mainLine.isEmpty) {
      throw HistCliError(graph.unsavedChangesAfter != null
          ? '$path: the live file has unsaved changes after '
              '${_short(graph.unsavedChangesAfter!)} — commit first'
          : '$path: no live version to reconcile against');
    }
    final live = graph.mainLine.last;
    final named = resolveRef(graph, v.rest[1]);
    final branch = graph.branches
        .where((b) => b.hashes.contains(named))
        .cast<HistBranch?>()
        .firstWhere((_) => true, orElse: () => null);
    if (branch == null) {
      throw HistCliError(
          '${_short(named)} is on the primary line — nothing to settle');
    }
    switch (branch.kind) {
      case HistBranchKind.merged:
        _say('${_short(branch.leaf)} is already settled — a marker names '
            'it; nothing to do');
        return exitOk;
      case HistBranchKind.archived:
        throw HistCliError(
            '${_short(branch.leaf)} is an archived line — the owner\'s own '
            'discarded state (a rollback, or a past life), with nothing to '
            'reconcile. Only divergent lines are offered (R8)');
      case HistBranchKind.divergent:
        break;
    }

    final take = v.option('take');
    if (take == 'live') {
      // Leave mine as it is (R17): the marker alone, naming the branch and
      // the live version. It propagates, so every device stops counting.
      await folder.writer.merge(path, branch.leaf, live);
      _say('settled $path: branch ${_short(branch.leaf)} kept in history, '
          'live version ${_short(live)} unchanged (marker written)');
      return exitOk;
    }
    if (take == 'branch') {
      // A restore of the leaf — already recorded, so the pointer moves and
      // no edge is written — plus a marker settling the line that was live.
      final bytes = await folder.reader.materialize(path, branch.leaf);
      folder.writeLive(path, bytes);
      folder.state.setHead(path, branch.leaf);
      await folder.writer.merge(path, live, branch.leaf);
      _say('settled $path: live is now ${_short(branch.leaf)}; the former '
          'line ${_short(live)} is settled (marker written)');
      return exitOk;
    }

    // The three-way merge (R9'') — a draft, resumable (R15).
    final fork = forkPoint(graph, branch.leaf);
    if (fork == null) {
      throw HistCliError(
          '$path: ${_short(branch.leaf)} shares no ancestor with the live '
          'line (separate lives, or a line anchored before the other\'s '
          'history arrived) — a three-way merge has no base. Settle it by '
          'taking a side: --take live, or --take branch (R10)');
    }
    final existing = folder.state.readDraft(path);
    if (existing != null) {
      throw HistCliError(
          '$path: an unfinished merge draft exists — resolve and '
          '`hist merge $path --continue`, or `--abort` it first:\n  '
          '${folder.state.draftPathOf(path)}');
    }
    final base = utf8.decode(await folder.reader.materialize(path, fork));
    final ours = utf8.decode(await folder.reader.materialize(path, live));
    final theirs =
        utf8.decode(await folder.reader.materialize(path, branch.leaf));
    final result = diff3(
      base,
      ours,
      theirs,
      labelOurs: 'live ${_short(live)}',
      labelBase: 'base ${_short(fork)}',
      labelTheirs: 'branch ${_short(branch.leaf)}',
    );
    folder.state.writeDraft(
      MergeDraft(
        path: path,
        live: live,
        branch: branch.leaf,
        base: fork,
        createdMillis: now(),
        conflicts: result.conflicts,
      ),
      result.text,
    );
    _say('draft written: ${folder.state.draftPathOf(path)}');
    _say(result.isClean
        ? 'no conflict regions — review the draft, then: '
            'hist merge $path --continue'
        : '${result.conflicts} conflict region(s) between <<<<<<< and '
            '>>>>>>> — resolve them in any editor, then: '
            'hist merge $path --continue   (or --abort)');
    return exitOk;
  }

  Future<int> _mergeContinue(HistFolder folder, String path) async {
    final draft = folder.state.readDraft(path);
    if (draft == null) throw HistCliError('$path: no merge draft to continue');
    final (meta, text) = draft;
    if (hasConflictRegion(text)) {
      final lines = splitLines(text);
      final at = [
        for (var i = 0; i < lines.length; i++)
          if (lines[i].startsWith(conflictOpen)) i + 1,
      ];
      throw HistCliError('$path: the draft still has ${at.length} conflict '
          'region(s) (opening at line${at.length == 1 ? '' : 's'} '
          '${at.join(', ')}) — resolve them, or --abort:\n  '
          '${folder.state.draftPathOf(path)}');
    }
    final liveNow = folder.liveHash(path);
    if (liveNow != meta.live) {
      throw HistCliError('$path: the live file changed since the draft was '
          'written (was ${_short(meta.live)}, now '
          '${liveNow == null ? 'absent' : _short(liveNow)}) — --abort and '
          'merge again');
    }
    final bytes = utf8.encode(text);
    final previous = await folder.reader.materialize(path, meta.live);
    folder.writeLive(path, bytes);
    final hash = sha256Hex(bytes);
    await folder.writer.commit(path, bytes, previous: previous, at: now());
    await folder.writer.merge(path, meta.branch, hash);
    folder.state.setHead(path, hash);
    folder.state.discardDraft(path);
    _say('merged $path: live is now ${_short(hash)}; branch '
        '${_short(meta.branch)} settled (marker written)');
    return exitOk;
  }

  int _mergeAbort(HistFolder folder, String path) {
    if (folder.state.readDraft(path) == null) {
      throw HistCliError('$path: no merge draft to abort');
    }
    folder.state.discardDraft(path);
    _say('draft discarded: $path (nothing was written to history or the '
        'live file)');
    return exitOk;
  }

  /// `status` (R13, R16): files with a divergent line, unfinished drafts,
  /// unsaved live changes — derived from the graphs, nothing stored.
  Future<int> _status(List<String> args, ArgResults g, String cwd) async {
    final v = _verbParser().parse(args);
    final folder = _folder(g, v, cwd);
    final divergent = <String, List<HistBranch>>{};
    final unsaved = <String, String>{};
    final graphs = <String, HistGraph>{};
    for (final path in await folder.historyPaths()) {
      final graph = await folder.graphOf(path);
      graphs[path] = graph;
      final open = graph.branches
          .where((b) => b.kind == HistBranchKind.divergent)
          .toList();
      if (open.isNotEmpty) divergent[path] = open;
      final after = graph.unsavedChangesAfter;
      if (after != null) unsaved[path] = after;
    }
    final drafts = folder.state.drafts();

    if (divergent.isEmpty) {
      _say('no divergent lines — nothing to reconcile');
    } else {
      _say('${divergent.length} file(s) with a divergent line:');
      for (final entry in divergent.entries) {
        _say('  ${entry.key}');
        for (final b in entry.value) {
          final fork = forkPoint(graphs[entry.key]!, b.leaf);
          _say('    branch ${_short(b.leaf)}  (${b.writers.join(', ')})'
              '${fork != null ? '  forked from ${_short(fork)}' : '  no common ancestor'}');
        }
      }
    }
    if (drafts.isNotEmpty) {
      _say('${drafts.length} unfinished merge(s):');
      for (final d in drafts) {
        _say('  ${d.path}  draft: ${folder.state.draftPathOf(d.path)}'
            '${d.conflicts > 0 ? '  (${d.conflicts} region(s) to resolve)' : ''}');
      }
    }
    if (unsaved.isNotEmpty) {
      _say('${unsaved.length} file(s) with unsaved changes:');
      for (final entry in unsaved.entries) {
        _say('  ${entry.key}  after ${_short(entry.value)}');
      }
    }
    return exitOk;
  }

  // ---------------------------------------------------------------------------
  // Options and the folder
  // ---------------------------------------------------------------------------

  ArgParser _globalParser() {
    final parser = ArgParser(allowTrailingOptions: false)
      ..addFlag('help', abbr: 'h', negatable: false)
      ..addFlag('version', negatable: false);
    _addGlobals(parser);
    return parser;
  }

  /// A verb's parser: its own options plus the globals, so `hist log
  /// --folder x` works as well as `hist --folder x log`.
  ArgParser _verbParser() {
    final parser = ArgParser();
    _addGlobals(parser);
    return parser;
  }

  void _addGlobals(ArgParser parser) => parser
    ..addOption('folder', help: 'the folder (default: located from cwd)')
    ..addOption('state-dir',
        help: "this machine's working state (default: <folder>/.hist-state)")
    ..addOption('writer', help: 'writer name for version headers')
    ..addOption('extensions',
        help: 'comma-separated tracked extensions (default .md); * for any '
            'text file');

  HistFolder _folder(ArgResults g, ArgResults v, String cwd) {
    String? opt(String name) =>
        v.wasParsed(name) ? v.option(name) : g.option(name);
    String abs(String path) => p.isAbsolute(path) ? path : p.join(cwd, path);

    final folderOpt = opt('folder');
    final root = folderOpt != null ? abs(folderOpt) : HistFolder.locate(cwd);
    final stateDir = opt('state-dir');
    final extensions = opt('extensions')
        ?.split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    return HistFolder(
      root: root,
      stateDir: stateDir == null ? null : abs(stateDir),
      writerName: opt('writer') ?? environment[writerEnv] ?? hostname,
      extensions: extensions ?? const ['.md'],
      now: now,
    );
  }

  int? _parseSince(String? text) {
    if (text == null) return null;
    final instant = DateTime.tryParse(text);
    if (instant == null) {
      throw HistCliError('--since: not a date: $text', usage: true);
    }
    return instant.millisecondsSinceEpoch;
  }

  int? _parseLimit(String? text) {
    if (text == null) return null;
    final n = int.tryParse(text);
    if (n == null || n < 0) {
      throw HistCliError('-n: not a count: $text', usage: true);
    }
    return n;
  }

  // ---------------------------------------------------------------------------
  // Output
  // ---------------------------------------------------------------------------

  void _say(String line) => out.add(utf8.encode('$line\n'));

  void _fail(String message) => err.writeln('hist: $message');

  int _usageError(String message) {
    _fail(message);
    err.writeln(usage);
    return exitUsage;
  }

  static String _short(String hash) =>
      hash.length > 12 ? hash.substring(0, 12) : hash;

  /// Local time, `yyyy-MM-dd HH:mm:ss` (`.SSS` with [withMillis]).
  static String _time(int millis, {bool withMillis = false}) {
    final t = DateTime.fromMillisecondsSinceEpoch(millis).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}'
        '${withMillis ? '.${t.millisecond.toString().padLeft(3, '0')}' : ''}';
  }
}
