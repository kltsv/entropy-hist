import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:diff_match_patch/diff_match_patch.dart' as dmp;

/// Shared on-disk format of `vault_hist` version files (RV5).
///
/// A version file is named `<utc-epoch-ms>.<type>` — the timestamp 13-digit
/// zero-padded so lexicographic order equals chronology — and consists of
/// `key: value` header lines, one empty line, then the body bytes. Identity
/// and linkage are the sha256 hashes in the headers, never the filename.

/// The four immutable version-file types (`vault_hist` RV5).
enum HistFileType { snapshot, patch, deleted, conflict, merged }

/// Lowercase-hex sha256 over content bytes exactly as-is — the identity of a
/// version (`vault_hist` RV5; no newline normalization).
String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

/// The canonical version filename: 13-digit zero-padded UTC epoch
/// milliseconds, a dot, and the type name (`vault_hist` RV5).
String versionFileName(int epochMillis, HistFileType type) =>
    '${epochMillis.toString().padLeft(13, '0')}.${type.name}';

/// Whether [filename] has the `<epoch-ms>.<type>` shape of a version file.
bool isVersionFileName(String filename) {
  final dot = filename.indexOf('.');
  if (dot <= 0) return false;
  if (int.tryParse(filename.substring(0, dot)) == null) return false;
  final typeName = filename.substring(dot + 1);
  return HistFileType.values.any((t) => t.name == typeName);
}

/// Decodes [bytes] as text, or returns `null` when the content is binary —
/// a NUL byte or invalid UTF-8. Binary content is never versioned
/// (`vault_hist` RV5, RV9).
String? decodeUtf8Text(List<int> bytes) {
  if (bytes.contains(0)) return null;
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return null;
  }
}

/// The pinned diff-match-patch recipe (`vault_hist` C5, RV5): `diff_main`
/// → `diff_cleanupEfficiency` → `patch_make`, all with default settings,
/// serialized with `patch_toText`. This exact sequence is what keeps the Dart
/// writer and the JS reader interoperable; cross-port fixtures pin it.
String makePatchText(String prev, String next) {
  final diffs = dmp.diff(prev, next);
  dmp.cleanupEfficiency(diffs, 4);
  final patches = dmp.patchMake(prev, b: diffs);
  return dmp.patchToText(patches);
}

/// Applies dmp patch text to [base]; returns the result, or `null` when the
/// text does not parse or any hunk fails to apply. Callers must still verify
/// the result's sha256 — dmp applies fuzzily and can succeed with garbage
/// (`vault_hist` RV5).
String? applyPatchText(String patchText, String base) {
  List<dmp.Patch> patches;
  try {
    patches = dmp.patchFromText(patchText);
  } catch (_) {
    return null;
  }
  List<dynamic> result;
  try {
    result = dmp.patchApply(patches, base);
  } catch (_) {
    return null;
  }
  final applied = result[1] as List<dynamic>;
  for (final ok in applied) {
    if (ok != true) return null;
  }
  return result[0] as String;
}

/// Serializes a version file: header lines in canonical order (`version`,
/// `prev`, `writer`, `renamed_from`, `renamed_to` — only the keys that
/// apply), one empty line, then the body bytes. A `deleted` marker simply has
/// an empty body (`vault_hist` RV5).
Uint8List encodeVersionFile({
  String? version,
  String? prev,
  String? writer,
  String? renamedFrom,
  String? renamedTo,
  String? merged,
  String? into,
  List<int> body = const [],
}) {
  final headers = StringBuffer();
  if (version != null) headers.write('version: $version\n');
  if (prev != null) headers.write('prev: $prev\n');
  if (writer != null) headers.write('writer: $writer\n');
  if (renamedFrom != null) headers.write('renamed_from: $renamedFrom\n');
  if (renamedTo != null) headers.write('renamed_to: $renamedTo\n');
  if (merged != null) headers.write('merged: $merged\n');
  if (into != null) headers.write('into: $into\n');
  headers.write('\n');
  final out = BytesBuilder(copy: false)
    ..add(utf8.encode(headers.toString()))
    ..add(body is Uint8List ? body : Uint8List.fromList(body));
  return out.toBytes();
}

/// Index just past the header section (the first blank line); equals
/// `bytes.length` when no blank line exists (a header-only file parsed
/// robustly).
int _headerEnd(List<int> bytes) {
  for (var i = 0; i + 1 < bytes.length; i++) {
    if (bytes[i] == 0x0a && bytes[i + 1] == 0x0a) return i + 2;
  }
  return bytes.length;
}

/// The body bytes of a version file: everything after the first blank line.
Uint8List bodyOf(List<int> bytes) {
  final start = _headerEnd(bytes);
  final list = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  return Uint8List.sublistView(list, start);
}

/// Parsed headers of one version file, plus its filename (`vault_hist`
/// RV5). The filename's timestamp is for humans and sorting only — identity
/// and linkage are [version] / [prev].
class HistFileHeader {
  const HistFileHeader({
    required this.filename,
    required this.type,
    this.version,
    this.prev,
    this.writer,
    this.renamedFrom,
    this.renamedTo,
    this.merged,
    this.into,
  });

  final String filename;
  final HistFileType type;

  /// sha256 of the content this file records (snapshot/patch/conflict).
  final String? version;

  /// sha256 of the state this file links back to (patch/deleted).
  final String? prev;

  /// The client that recorded this version (`vault_hist` RV6).
  final String? writer;

  /// Display link to the path this file was renamed from (`vault_hist`
  /// RV7, snapshot only).
  final String? renamedFrom;

  /// Display link to the path this file was renamed to (`vault_hist`
  /// RV7, deleted only).
  final String? renamedTo;

  /// The leaf hash of a branch this file settles (`merged` only) — the
  /// branch stays exactly as it was; this marker only says it is no longer
  /// open (`vault_hist` RV6).
  final String? merged;

  /// The version the reconciled content became (`merged` only). It is an
  /// ordinary single-parent version on the primary line; nothing here makes
  /// a record with two parents.
  final String? into;

  /// The filename's UTC epoch-ms prefix (for humans and sorting only).
  int get timestampMillis =>
      int.parse(filename.substring(0, filename.indexOf('.')));

  /// Parses [filename] + [bytes] into a header, or returns `null` when the
  /// filename is not `<epoch-ms>.<type>`. Header parsing is robust: any
  /// `key: value` lines before the first blank line count, unknown keys are
  /// ignored.
  static HistFileHeader? tryParse(String filename, List<int> bytes) {
    final dot = filename.indexOf('.');
    if (dot <= 0) return null;
    if (int.tryParse(filename.substring(0, dot)) == null) return null;
    final typeName = filename.substring(dot + 1);
    HistFileType? type;
    for (final t in HistFileType.values) {
      if (t.name == typeName) type = t;
    }
    if (type == null) return null;

    final headerBytes = bytes.sublist(0, _headerEnd(bytes));
    final text = utf8.decode(headerBytes, allowMalformed: true);
    final fields = <String, String>{};
    for (final line in text.split('\n')) {
      final sep = line.indexOf(':');
      if (sep <= 0) continue;
      fields[line.substring(0, sep).trim()] = line.substring(sep + 1).trim();
    }
    return HistFileHeader(
      filename: filename,
      type: type,
      version: fields['version'],
      prev: fields['prev'],
      writer: fields['writer'],
      renamedFrom: fields['renamed_from'],
      renamedTo: fields['renamed_to'],
      merged: fields['merged'],
      into: fields['into'],
    );
  }
}
