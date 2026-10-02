/// The exclusion engine of `vault_folder` (R7) — shared by every host that
/// walks a vault: the daemon's folder service, and the standalone history
/// CLI over a bare folder. One engine compiles every exclusion source — a
/// configured list, and the vault's own ignore files at **any depth** —
/// through the same documented gitignore subset (`vault_daemon` RV8):
///
/// - blank lines and `#` comments are skipped; unsupported forms (leading
///   `!` negation) are skipped as if comments;
/// - a pattern **without** `/` is a basename glob matched against every path
///   segment beneath the directory the ignore file sits in (`*` allowed
///   within the name) — a matching directory name excludes everything under
///   it;
/// - a pattern **with** `/` is a path glob anchored at the directory the
///   ignore file sits in — the vault root for the root file and a configured
///   list (a leading `/` is stripped and equivalent); `*` matches within one
///   path segment, `**` across segments (including zero);
/// - a trailing `/` matches the directory and everything under it.
///
/// **Nesting is additive** (`vault_folder`): a path is excluded if *any*
/// source excludes it. No precedence and no ordering — which holds precisely
/// because negation is absent, so no deeper file can re-include what an
/// ancestor excluded.
///
/// `.hist/` is **not** excluded from sync (RV8) — it is excluded only from
/// history *tracking*, which the history module handles itself.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// The vault's own rule file for what the folder excludes
/// (`vault_daemon` RV8), read at any depth.
const String syncIgnoreFileName = '.syncignore';

/// The rule file history consumes through the same engine — paths that
/// sync but are not history-tracked.
const String histIgnoreFileName = '.histignore';

/// One source of rules: the vault-relative directory it applies beneath
/// (`''` for the vault root) and its effective pattern lines. An ignore file
/// at `notes/.syncignore` is `IgnoreSource('notes', …)`; a configured list
/// is a root source.
class IgnoreSource {
  const IgnoreSource(this.dir, this.patterns);

  /// `/`-separated, no leading or trailing slash; `''` is the vault root.
  final String dir;

  final List<String> patterns;
}

class ExclusionMatcher {
  /// Root-anchored rules only — a configured list, or the root ignore file.
  ExclusionMatcher(Iterable<String> patterns)
      : this.fromSources([IgnoreSource('', patterns.toList())]);

  /// Rules from any number of sources, each anchored at its own directory.
  ExclusionMatcher.fromSources(Iterable<IgnoreSource> sources) {
    for (final source in sources) {
      final base = _normDir(source.dir);
      for (final pattern in source.patterns) {
        final rule = _compile(pattern, base);
        if (rule != null) _rules.add(rule);
      }
    }
  }

  final List<_Rule> _rules = [];

  /// Whether the vault-relative [rel] path (using `/` separators) is excluded
  /// from sync, watching, scanning, and history.
  bool excludes(String rel) {
    final norm = p.posix.joinAll(p.split(rel));
    for (final rule in _rules) {
      if (rule.matches(norm)) return true;
    }
    return false;
  }

  /// Parse ignore-file content into its effective pattern lines: blank lines
  /// and `#` comments dropped, unsupported forms (leading `!`) dropped as if
  /// comments, everything else trimmed and kept verbatim.
  static List<String> parseIgnoreLines(String content) => [
        for (final raw in content.split('\n'))
          if (_isPattern(raw.trim())) raw.trim(),
      ];

  static bool _isPattern(String line) =>
      line.isNotEmpty && !line.startsWith('#') && !line.startsWith('!');

  static String _normDir(String dir) {
    final parts = p.posix.split(dir).where((s) => s.isNotEmpty && s != '.');
    return parts.join('/');
  }

  static _Rule? _compile(String raw, String base) {
    var pattern = raw.trim();
    if (!_isPattern(pattern)) return null;
    // The presence of ANY `/` (leading, interior, or trailing) anchors the
    // pattern at the source's directory — this keeps the profile's
    // historical `dir/`-prefix semantics byte-compatible.
    final anchored = pattern.contains('/');
    final dirOnly = pattern.endsWith('/');
    if (dirOnly) pattern = pattern.substring(0, pattern.length - 1);
    while (pattern.startsWith('/')) {
      pattern = pattern.substring(1); // a leading `/` is stripped, equivalent
    }
    if (pattern.isEmpty) return null;

    if (!anchored) {
      // Basename glob at any depth beneath the source: matches when any
      // path segment matches, so a matching directory name covers
      // everything beneath it.
      return _SegmentRule(base, RegExp('^${_segmentRe(pattern)}\$'));
    }

    // Path glob anchored at the source's directory. A standalone `**`
    // segment spans any number of segments (including zero); `*` stays
    // within one segment.
    final segments = pattern.split('/').where((s) => s.isNotEmpty).toList();
    final buf = StringBuffer('^');
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      final isLast = i == segments.length - 1;
      if (segment == '**') {
        buf.write(isLast ? '.*' : '(?:[^/]+/)*');
      } else {
        buf.write(_segmentRe(segment));
        if (!isLast) buf.write('/');
      }
    }
    buf.write(dirOnly ? r'(?:/.*)?$' : r'$');
    return _PathRule(base, RegExp(buf.toString()));
  }

  /// One path segment's glob as a regex fragment: `*` matches within the
  /// segment, everything else is literal.
  static String _segmentRe(String segment) {
    final buf = StringBuffer();
    for (final ch in segment.split('')) {
      buf.write(ch == '*' ? '[^/]*' : RegExp.escape(ch));
    }
    return buf.toString();
  }
}

sealed class _Rule {
  _Rule(this.base);

  /// The directory this rule applies beneath (`''` = everywhere).
  final String base;

  /// [norm] relative to [base], or null when the path is not beneath it. An
  /// ignore file never matches the directory it sits in — only what is
  /// under it.
  String? _under(String norm) {
    if (base.isEmpty) return norm;
    if (norm.startsWith('$base/')) return norm.substring(base.length + 1);
    return null;
  }

  bool matches(String norm) {
    final rest = _under(norm);
    return rest != null && rest.isNotEmpty && _matchesRest(rest);
  }

  bool _matchesRest(String rest);
}

/// A basename pattern (no `/`): matches any path segment beneath the source.
class _SegmentRule extends _Rule {
  _SegmentRule(super.base, this.re);
  final RegExp re;

  @override
  bool _matchesRest(String rest) => rest.split('/').any(re.hasMatch);
}

/// An anchored pattern (contains `/`): matches the path relative to the
/// source's directory.
class _PathRule extends _Rule {
  _PathRule(super.base, this.re);
  final RegExp re;

  @override
  bool _matchesRest(String rest) => re.hasMatch(rest);
}

/// One owner-editable ignore file (`.syncignore` / `.histignore`,
/// `vault_daemon` RV8) wherever it sits: its parsed patterns plus the
/// cheap mtime+size re-read a host runs at the start of every pass, so rule
/// edits — including a rule file that itself just arrived via sync — apply on
/// the very next pass.
class IgnoreFile {
  IgnoreFile(this.path);

  /// Absolute path of the ignore file.
  final String path;

  /// The effective patterns as of the last successful [refresh]. A missing
  /// file is simply an empty rule set.
  List<String> patterns = const [];

  static const _absent = -1;
  int _mtime = _absent;
  int _size = _absent;

  /// Whether the file existed at the last [refresh].
  bool get exists => _mtime != _absent;

  /// Re-read the file when its mtime+size changed (two stats per pass — no
  /// content read on the common unchanged path). Returns `true` when the
  /// effective rules may have changed and matchers must be rebuilt.
  bool refresh() {
    final stat = FileStat.statSync(path);
    if (stat.type == FileSystemEntityType.notFound) {
      if (_mtime == _absent && _size == _absent) return false;
      _mtime = _absent;
      _size = _absent;
      final hadRules = patterns.isNotEmpty;
      patterns = const [];
      return hadRules;
    }
    final mtime = stat.modified.millisecondsSinceEpoch;
    if (mtime == _mtime && stat.size == _size) return false;
    try {
      patterns = ExclusionMatcher.parseIgnoreLines(
        File(path).readAsStringSync(),
      );
      _mtime = mtime;
      _size = stat.size;
      return true;
    } on FileSystemException {
      // Unreadable mid-write: keep the previous rules and retry next pass.
      return false;
    } on FormatException {
      // Not valid UTF-8 (torn write): keep the previous rules, retry.
      return false;
    }
  }
}

/// Every ignore file of the given names in a vault, at any depth
/// (`vault_folder` — *Ignore files nest*). A host **offers** the paths it
/// comes across (its own tree walk, a watcher event, a write it performed)
/// so a file that appears anywhere is known; [refresh] then re-reads only
/// what changed, by stat; [sources] hands the engine one anchored source per
/// file. Hosts without a walk of their own call [discover].
class IgnoreFileTree {
  IgnoreFileTree(this.root, {required Iterable<String> names})
      : names = names.toSet();

  /// Absolute path of the vault root.
  final String root;

  /// The basenames tracked (`.syncignore`, `.histignore`).
  final Set<String> names;

  final Map<String, IgnoreFile> _files = {};

  /// Whether [rel] (vault-relative, `/`-separated) names an ignore file.
  bool isIgnoreFile(String rel) =>
      names.contains(rel.substring(rel.lastIndexOf('/') + 1));

  /// The ignore files currently known, vault-relative.
  Iterable<String> get known => _files.keys;

  /// Make [rel] known when it is an ignore file; returns whether it is one.
  /// Reading happens on the next [refresh].
  bool offer(String rel) {
    if (!isIgnoreFile(rel)) return false;
    _files.putIfAbsent(
      rel,
      () => IgnoreFile(p.joinAll([root, ...rel.split('/')])),
    );
    return true;
  }

  /// Walk the whole tree for ignore files — for a host that has no walk of
  /// its own (the standalone CLI). Symlinks are not followed.
  void discover() {
    final dir = Directory(root);
    if (!dir.existsSync()) return;
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (!names.contains(p.basename(entity.path))) continue;
      final rel = p.posix.joinAll(p.split(p.relative(entity.path, from: root)));
      offer(rel);
    }
  }

  /// Stat every known file, re-read the changed ones, drop the vanished.
  /// Returns whether the effective rules changed.
  bool refresh() {
    var changed = false;
    for (final rel in _files.keys.toList()) {
      final file = _files[rel]!;
      if (file.refresh()) changed = true;
      if (!file.exists) _files.remove(rel);
    }
    return changed;
  }

  /// One anchored source per known file named [name], in path order.
  List<IgnoreSource> sources(String name) {
    final rels = _files.keys.where((rel) => rel.endsWith(name)).toList()
      ..sort();
    return [
      for (final rel in rels)
        if (rel.substring(rel.lastIndexOf('/') + 1) == name)
          IgnoreSource(
            rel.contains('/') ? rel.substring(0, rel.lastIndexOf('/')) : '',
            _files[rel]!.patterns,
          ),
    ];
  }
}
