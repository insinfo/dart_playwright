// Part of the Dart port of the Playwright trace viewer UI.

/// Opens a trace archive in the viewer.
///
///     dart run playwright_trace_viewer_ui:show_trace trace.zip
///
/// It reads the archive, binds an `HttpServer` on the loopback address and
/// prints the URL. Upstream's `show-trace` uploads nothing and neither does
/// this: the trace never leaves the machine, which is the whole reason a
/// local server is worth having over the hosted viewer.
library;

import 'dart:async';
import 'dart:io';

import 'package:playwright_trace_viewer_ui/server.dart';

Future<void> main(List<String> args) async {
  final options = _parse(args);
  if (options == null) {
    stderr.writeln('Usage: show_trace <trace.zip> [--port N] [--host H] '
        '[--no-open] [--live]');
    exitCode = 64;
    return;
  }

  final file = File(options.trace);
  if (!await file.exists()) {
    stderr.writeln('No such trace: ${options.trace}');
    exitCode = 66;
    return;
  }

  final trace = await LoadedTrace.open(file.absolute.path, live: options.live);
  final assets = await ViewerAssets.load();
  final server = TraceViewerServer(trace, assets);
  await server.start(host: options.host, port: options.port);

  stdout.writeln('Listening on ${server.url}');
  if (options.open) await _openInBrowser(server.url);
  // The process stays up until it is interrupted; there is nothing else for
  // it to wait on.
  await ProcessSignal.sigint.watch().first;
  await server.close();
}

class _Options {
  final String trace;
  final String host;
  final int port;
  final bool open;
  final bool live;

  const _Options(this.trace, this.host, this.port, this.open, this.live);
}

_Options? _parse(List<String> args) {
  String? trace;
  var host = '127.0.0.1';
  var port = 0;
  var open = true;
  var live = false;
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--port' && i + 1 < args.length) {
      port = int.tryParse(args[++i]) ?? 0;
    } else if (arg == '--host' && i + 1 < args.length) {
      host = args[++i];
    } else if (arg == '--no-open') {
      open = false;
    } else if (arg == '--live') {
      live = true;
    } else if (!arg.startsWith('-')) {
      trace = arg;
    }
  }
  if (trace == null) return null;
  // A CI or agent run has no browser to open and no one to see it.
  if (Platform.environment['CLAUDECODE'] != null ||
      Platform.environment['COPILOT_CLI'] != null ||
      Platform.environment['CI'] != null) {
    open = false;
  }
  return _Options(trace, host, port, open, live);
}

Future<void> _openInBrowser(String url) async {
  try {
    if (Platform.isWindows) {
      await Process.run('cmd', ['/c', 'start', '', url]);
    } else if (Platform.isMacOS) {
      await Process.run('open', [url]);
    } else {
      await Process.run('xdg-open', [url]);
    }
  } on Object {
    // No browser to open is not a failure; the URL was printed.
  }
}
