import 'dart:convert';

import 'package:diff_match_patch/diff_match_patch.dart' as dmp;

import 'hist_log.dart';
import 'hist_reader.dart';

/// Line-level differencing over reconstructed content (`vault_hist` — *The
/// read surface*, history-surface R4, R5, R9''): a unified diff between two
/// versions, and blame — each line attributed to the version that introduced
/// it. Both are renderings over **verified** content, never replays of the
/// stored character-level patches, whose application is fuzzy.
///
/// The line diff drives diff-match-patch's `diff()` in **line mode**: each
/// distinct line becomes one code unit, the diff runs over those, and the
/// runs are rehydrated — the same trick dmp's own `diff_linesToChars` plays,
/// done here because the port does not export it. No new dependency.

enum LineOp { equal, insert, delete }

/// One run of lines with one fate. Lines keep their trailing newline (the
/// last line of a text may lack one).
class LineEdit {
  const LineEdit(this.op, this.lines);

  final LineOp op;
  final List<String> lines;
}

/// Split [text] into lines, each keeping its `\n`; a final line without one
/// is kept as is.
List<String> splitLines(String text) {
  final out = <String>[];
  var start = 0;
  while (start < text.length) {
    var end = text.indexOf('\n', start);
    end = end == -1 ? text.length : end + 1;
    out.add(text.substring(start, end));
    start = end;
  }
  return out;
}

/// The line-level diff of [a] → [b], exact (no timeout).
List<LineEdit> lineDiff(String a, String b) {
  final lineArray = <String>[''];
  final lineIndex = <String, int>{};
  String munge(String text) {
    final buf = StringBuffer();
    for (final line in splitLines(text)) {
      final idx = lineIndex.putIfAbsent(line, () {
        lineArray.add(line);
        return lineArray.length - 1;
      });
      buf.writeCharCode(idx);
    }
    return buf.toString();
  }

  final chars1 = munge(a);
  final chars2 = munge(b);
  final diffs = dmp.diff(chars1, chars2, checklines: false, timeout: 0);
  return [
    for (final d in diffs)
      if (d.text.isNotEmpty)
        LineEdit(
          switch (d.operation) {
            dmp.DIFF_INSERT => LineOp.insert,
            dmp.DIFF_DELETE => LineOp.delete,
            _ => LineOp.equal,
          },
          [for (final cu in d.text.codeUnits) lineArray[cu]],
        ),
  ];
}

/// A unified diff of [a] → [b] with [context] lines around each change, or
/// the empty string when the two are identical.
String unifiedDiff(
  String a,
  String b, {
  required String labelA,
  required String labelB,
  int context = 3,
}) {
  final ops = <(LineOp, String)>[
    for (final edit in lineDiff(a, b))
      for (final line in edit.lines) (edit.op, line),
  ];
  final changes = [
    for (var i = 0; i < ops.length; i++)
      if (ops[i].$1 != LineOp.equal) i,
  ];
  if (changes.isEmpty) return '';

  // Group changes into hunks: two changes share a hunk when their context
  // windows touch or overlap.
  final hunks = <(int, int)>[];
  var start = _max(0, changes.first - context);
  var end = _min(ops.length - 1, changes.first + context);
  for (final c in changes.skip(1)) {
    if (c - context <= end + 1) {
      end = _min(ops.length - 1, c + context);
    } else {
      hunks.add((start, end));
      start = _max(0, c - context);
      end = _min(ops.length - 1, c + context);
    }
  }
  hunks.add((start, end));

  final out = StringBuffer()
    ..writeln('--- $labelA')
    ..writeln('+++ $labelB');
  var aPos = 0; // lines of `a` consumed before index i
  var bPos = 0;
  var i = 0;
  for (final (hs, he) in hunks) {
    for (; i < hs; i++) {
      if (ops[i].$1 != LineOp.insert) aPos++;
      if (ops[i].$1 != LineOp.delete) bPos++;
    }
    var aCount = 0;
    var bCount = 0;
    final body = StringBuffer();
    for (var j = hs; j <= he; j++) {
      final (op, line) = ops[j];
      final prefix = switch (op) {
        LineOp.equal => ' ',
        LineOp.insert => '+',
        LineOp.delete => '-',
      };
      body.write('$prefix$line');
      if (!line.endsWith('\n')) body.write('\n\\ No newline at end of file\n');
      if (op != LineOp.insert) aCount++;
      if (op != LineOp.delete) bCount++;
    }
    out
      ..writeln('@@ -${_range(aPos, aCount)} +${_range(bPos, bCount)} @@')
      ..write(body);
    for (; i <= he; i++) {
      if (ops[i].$1 != LineOp.insert) aPos++;
      if (ops[i].$1 != LineOp.delete) bPos++;
    }
  }
  return out.toString();
}

String _range(int before, int count) {
  final start = count == 0 ? before : before + 1;
  return count == 1 ? '$start' : '$start,$count';
}

int _max(int a, int b) => a > b ? a : b;
int _min(int a, int b) => a < b ? a : b;

/// One line of a version, attributed (`vault_hist` R5).
class BlameLine {
  const BlameLine({
    required this.text,
    required this.hash,
    required this.writers,
    required this.timestampMillis,
  });

  /// The line, with its trailing newline when it has one.
  final String text;

  /// The version that introduced this line.
  final String hash;

  /// That version's writers (several when two devices recorded it).
  final List<String> writers;

  final int timestampMillis;
}

/// Blame [hash] of [path]: replay the chain from the root to the version,
/// each step reconstructed and verified, carrying every surviving line's
/// attribution forward through a line diff of the step. Throws
/// [BrokenVersion] when any step fails verification.
Future<List<BlameLine>> blame(
  HistReader reader,
  HistGraph graph,
  String path,
  String hash,
) async {
  final chain = graph.mainLine.isNotEmpty && graph.mainLine.last == hash
      ? graph.mainLine
      : lineTo(graph, hash);
  if (chain.isEmpty) {
    throw BrokenVersion(path, hash, 'no snapshot ancestor reachable');
  }
  List<BlameLine> current = const [];
  String? previousText;
  for (final step in chain) {
    final version = graph.versions[step]!;
    final text = utf8.decode(await reader.materialize(path, step));
    BlameLine own(String line) => BlameLine(
          text: line,
          hash: step,
          writers: version.writers.toList()..sort(),
          timestampMillis: version.timestampMillis,
        );
    if (previousText == null) {
      current = [for (final line in splitLines(text)) own(line)];
    } else {
      final next = <BlameLine>[];
      var carried = 0;
      for (final edit in lineDiff(previousText, text)) {
        switch (edit.op) {
          case LineOp.equal:
            next.addAll(current.sublist(carried, carried + edit.lines.length));
            carried += edit.lines.length;
          case LineOp.delete:
            carried += edit.lines.length;
          case LineOp.insert:
            next.addAll(edit.lines.map(own));
        }
      }
      current = next;
    }
    previousText = text;
  }
  return current;
}
