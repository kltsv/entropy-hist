import 'hist_diff.dart';
import 'hist_reader.dart';

/// The reconciliation inputs (`vault_hist` — *The reconciliation inputs*,
/// history-surface R9', R9'', R10): the fork point of a branch, and a
/// three-way `diff3` over exact, verified content with explicit conflict
/// regions. Never a replay of stored patches — dmp applies them fuzzily and
/// returns plausible garbage without error.

/// The nearest ancestor of [branchLeaf] on the primary line, following
/// `prev` links back from the leaf; `null` when the branch shares no
/// ancestor with the live line (a separate life, or a line anchored before
/// another's history arrived) — side-choosing only, then.
String? forkPoint(HistGraph graph, String branchLeaf) {
  final onMain = graph.mainLine.toSet();
  if (onMain.isEmpty || !graph.versions.containsKey(branchLeaf)) return null;
  if (onMain.contains(branchLeaf)) return branchLeaf;
  final parents = <String, List<String>>{};
  for (final e in graph.edges) {
    (parents[e.version] ??= []).add(e.prev);
  }
  final visited = <String>{branchLeaf};
  var frontier = [branchLeaf];
  while (frontier.isNotEmpty) {
    final next = <String>[];
    for (final node in frontier) {
      for (final prev in (parents[node] ?? const <String>[]).toList()..sort()) {
        if (!visited.add(prev)) continue;
        if (onMain.contains(prev)) return prev;
        next.add(prev);
      }
    }
    frontier = next;
  }
  return null;
}

/// The outcome of a three-way merge: the composed text, and how many
/// conflict regions it carries for the owner to resolve.
class Diff3Result {
  const Diff3Result(this.text, this.conflicts);

  final String text;
  final int conflicts;

  bool get isClean => conflicts == 0;
}

/// The line a conflict region opens and closes with; `--continue` refuses a
/// draft while any remain. Detected by these two markers only — a lone
/// `=======` is also a Markdown heading underline and must not count.
const String conflictOpen = '<<<<<<< ';
const String conflictClose = '>>>>>>> ';

/// Whether [text] still carries an unresolved conflict region.
bool hasConflictRegion(String text) => splitLines(text)
    .any((l) => l.startsWith(conflictOpen) || l.startsWith(conflictClose));

/// A three-way merge of [ours] and [theirs] against their common ancestor
/// [base], line by line: a region only one side changed takes that side; a
/// region both changed identically takes it once; a region both changed —
/// or whose changes touch — differently becomes an explicit conflict
/// region with the live lines, the ancestor's and the branch's. It never
/// guesses.
Diff3Result diff3(
  String base,
  String ours,
  String theirs, {
  String labelOurs = 'live',
  String labelBase = 'base',
  String labelTheirs = 'branch',
}) {
  final baseLines = splitLines(base);
  final oursHunks = _hunks(base, ours);
  final theirsHunks = _hunks(base, theirs);

  final out = StringBuffer();
  var conflicts = 0;
  var pos = 0; // base lines emitted so far
  var i = 0; // next hunk of ours
  var j = 0; // next hunk of theirs

  void copyBase(int upTo) {
    for (; pos < upTo; pos++) {
      out.write(baseLines[pos]);
    }
  }

  while (i < oursHunks.length || j < theirsHunks.length) {
    final nextO = i < oursHunks.length ? oursHunks[i].start : null;
    final nextT = j < theirsHunks.length ? theirsHunks[j].start : null;
    final start = nextO == null
        ? nextT!
        : nextT == null
            ? nextO
            : (nextO < nextT ? nextO : nextT);
    copyBase(start);

    // Gather every hunk from either side that overlaps or touches the
    // region, growing it until neither side adds one.
    var end = start;
    var oCount = 0;
    var tCount = 0;
    var grew = true;
    while (grew) {
      grew = false;
      while (i + oCount < oursHunks.length &&
          _touches(oursHunks[i + oCount], start, end)) {
        end = _max(end, oursHunks[i + oCount].end);
        oCount++;
        grew = true;
      }
      while (j + tCount < theirsHunks.length &&
          _touches(theirsHunks[j + tCount], start, end)) {
        end = _max(end, theirsHunks[j + tCount].end);
        tCount++;
        grew = true;
      }
    }

    final oursRegion =
        _sideRegion(baseLines, oursHunks.sublist(i, i + oCount), start, end);
    final theirsRegion =
        _sideRegion(baseLines, theirsHunks.sublist(j, j + tCount), start, end);
    if (tCount == 0 || _same(oursRegion, theirsRegion)) {
      oursRegion.forEach(out.write);
    } else if (oCount == 0) {
      theirsRegion.forEach(out.write);
    } else {
      conflicts++;
      out.write('$conflictOpen$labelOurs\n');
      _writeBlock(out, oursRegion);
      out.write('||||||| $labelBase\n');
      _writeBlock(out, baseLines.sublist(start, end));
      out.write('=======\n');
      _writeBlock(out, theirsRegion);
      out.write('$conflictClose$labelTheirs\n');
    }
    pos = end;
    i += oCount;
    j += tCount;
  }
  copyBase(baseLines.length);
  return Diff3Result(out.toString(), conflicts);
}

/// A side's replacement of base lines `[start, end)` by [lines].
class _Hunk {
  const _Hunk(this.start, this.end, this.lines);

  final int start;
  final int end;
  final List<String> lines;
}

/// The hunks of `base → side`: every run of non-equal edits, as the base
/// range it replaces and the lines it puts there.
List<_Hunk> _hunks(String base, String side) {
  final hunks = <_Hunk>[];
  var pos = 0;
  int? start;
  final replacement = <String>[];
  for (final edit in lineDiff(base, side)) {
    switch (edit.op) {
      case LineOp.equal:
        if (start != null) {
          hunks.add(_Hunk(start, pos, List.of(replacement)));
          start = null;
          replacement.clear();
        }
        pos += edit.lines.length;
      case LineOp.delete:
        start ??= pos;
        pos += edit.lines.length;
      case LineOp.insert:
        start ??= pos;
        replacement.addAll(edit.lines);
    }
  }
  if (start != null) hunks.add(_Hunk(start, pos, List.of(replacement)));
  return hunks;
}

/// Overlapping or adjacent — touching changes are not guessed apart.
bool _touches(_Hunk h, int start, int end) => h.start <= end && h.end >= start;

/// What one side makes of base lines `[start, end)`: its hunks applied,
/// the rest copied.
List<String> _sideRegion(
    List<String> base, List<_Hunk> hunks, int start, int end) {
  final out = <String>[];
  var p = start;
  for (final h in hunks) {
    out.addAll(base.sublist(p, h.start));
    out.addAll(h.lines);
    p = h.end;
  }
  out.addAll(base.sublist(p, end));
  return out;
}

bool _same(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var k = 0; k < a.length; k++) {
    if (a[k] != b[k]) return false;
  }
  return true;
}

/// A conflict block's lines, each terminated — a final line without a
/// newline would otherwise glue to the next marker.
void _writeBlock(StringBuffer out, List<String> lines) {
  for (final line in lines) {
    out.write(line);
    if (!line.endsWith('\n')) out.write('\n');
  }
}

int _max(int a, int b) => a > b ? a : b;
