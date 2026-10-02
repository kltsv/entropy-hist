import 'dart:io';

import 'package:entropy_hist/entropy_hist.dart';

/// The `hist` binary (`vault_hist_cli`): the history command line over a
/// bare folder — no daemon, no server, no credentials, no registration.
/// Everything lives in the tested library; this only wires it to the
/// process.
Future<void> main(List<String> args) async {
  final cli = HistCli(out: stdout, err: stderr);
  exitCode = await cli.run(args, cwd: Directory.current.path);
  await stdout.flush();
}
