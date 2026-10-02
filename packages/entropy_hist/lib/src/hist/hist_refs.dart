import 'hist_reader.dart';

/// Revision addressing, the way git spells it (`vault_hist` — *The read
/// surface*, history-surface R1): a full hash, an **unambiguous** short
/// prefix, `HEAD`, `HEAD~n`, or `@{<date-or-instant>}`. An ambiguous prefix
/// is an error naming the candidates, never a guess.

/// A revision that does not resolve — unknown, ambiguous, out of range, or
/// naming a live version that does not exist.
class HistRefError implements Exception {
  HistRefError(this.message, {this.candidates = const []});

  final String message;

  /// The full hashes an ambiguous prefix could have meant.
  final List<String> candidates;

  @override
  String toString() => candidates.isEmpty
      ? message
      : '$message\n${candidates.map((c) => '  $c').join('\n')}';
}

/// Shortest prefix accepted — the same floor git uses.
const int minRefPrefixLength = 4;

final _hex = RegExp(r'^[0-9a-fA-F]+$');

/// Resolve [ref] against [graph] to a full version hash.
///
/// - `HEAD` is the live content's version: an error when the live file is
///   unrecorded ("unsaved changes after X") or absent — there is no live
///   version to name.
/// - `HEAD~n` walks the primary line back `n` steps; past the root is an
///   error.
/// - `@{<instant>}` is the primary-line version live at that instant — the
///   latest whose recorded time is not after it. A date alone means the
///   start of that day, local time. This is the one address that rests on
///   the recording devices' clocks, which are not authoritative.
/// - Anything else is a hex prefix (at least [minRefPrefixLength]
///   characters) of exactly one version.
String resolveRef(HistGraph graph, String ref) {
  final r = ref.trim();
  if (r == 'HEAD' || r.startsWith('HEAD~')) {
    final steps = r == 'HEAD' ? 0 : int.tryParse(r.substring('HEAD~'.length));
    if (steps == null || steps < 0) throw HistRefError('not a revision: $ref');
    if (graph.mainLine.isEmpty) {
      final after = graph.unsavedChangesAfter;
      if (after != null) {
        throw HistRefError('HEAD: the live file has unsaved changes after '
            '$after — commit first, or address a version');
      }
      throw HistRefError(graph.versions.isEmpty
          ? 'no history'
          : 'HEAD: no live version (the file is absent or unrecorded)');
    }
    if (steps >= graph.mainLine.length) {
      throw HistRefError('$ref: the primary line has only '
          '${graph.mainLine.length} version(s)');
    }
    return graph.mainLine[graph.mainLine.length - 1 - steps];
  }

  if (r.startsWith('@{') && r.endsWith('}')) {
    final text = r.substring(2, r.length - 1).trim();
    final instant = DateTime.tryParse(text);
    if (instant == null) {
      throw HistRefError(
          'not a date: $text (use YYYY-MM-DD or YYYY-MM-DDTHH:MM)');
    }
    final ms = instant.millisecondsSinceEpoch;
    String? found;
    for (final hash in graph.mainLine) {
      if (graph.versions[hash]!.timestampMillis <= ms) found = hash;
    }
    if (found == null) {
      throw HistRefError(graph.mainLine.isEmpty
          ? 'no live version to date'
          : 'no version of the primary line existed at $text');
    }
    return found;
  }

  if (!_hex.hasMatch(r)) throw HistRefError('not a revision: $ref');
  if (r.length < minRefPrefixLength) {
    throw HistRefError(
        'prefix too short: $ref (at least $minRefPrefixLength characters)');
  }
  final lower = r.toLowerCase();
  final matches = graph.versions.keys.where((h) => h.startsWith(lower)).toList()
    ..sort();
  if (matches.isEmpty) throw HistRefError('no version matches $ref');
  if (matches.length > 1) {
    throw HistRefError('ambiguous revision $ref — candidates:',
        candidates: matches);
  }
  return matches.single;
}
