import 'dart:convert';
import 'dart:io';

import 'package:entropy_hist/src/bridge/hist_bridge.dart';

Future<void> main() async {
  Map<String, Object?> response;
  try {
    final bytes = <int>[];
    await for (final chunk in stdin) {
      bytes.addAll(chunk);
      if (bytes.length > 64 * 1024 * 1024) {
        throw const FormatException('Request exceeds 64 MiB.');
      }
    }
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Expected one JSON request object.');
    }
    response = await HistBridge().handle(value);
  } catch (e) {
    response = {
      'ok': false,
      'error': {'code': 'invalid_request', 'message': e.toString()}
    };
  }
  stdout.writeln(jsonEncode(response));
  exitCode = response['ok'] == true ? 0 : 1;
  await stdout.flush();
}
