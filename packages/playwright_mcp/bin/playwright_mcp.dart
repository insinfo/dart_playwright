import 'dart:io';

import 'package:playwright_mcp/playwright_mcp.dart';

/// Serves the Model Context Protocol over stdio.
///
/// Usage: `dart run playwright_mcp [--browser chromium|firefox|webkit]
/// [--headed]`
void main(List<String> args) async {
  var browserName = 'chromium';
  var headless = true;

  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--browser':
        if (i + 1 >= args.length) {
          stderr.writeln('--browser needs a value');
          exit(2);
        }
        browserName = args[++i];
      case '--headed':
        headless = false;
      case '--help':
      case '-h':
        stdout.writeln('playwright_mcp [--browser chromium|firefox|webkit] '
            '[--headed]');
        exit(0);
      default:
        stderr.writeln('Unknown argument: ${args[i]}');
        exit(2);
    }
  }

  if (!const ['chromium', 'firefox', 'webkit'].contains(browserName)) {
    stderr.writeln('Unknown browser: $browserName');
    exit(2);
  }

  final server = PlaywrightMcpServer(
    session: BrowserSession(browserName: browserName, headless: headless),
  );
  try {
    // stdout is the protocol channel, so every diagnostic goes to stderr.
    stderr.writeln('playwright_mcp serving $browserName over stdio');
    await server.serve();
  } finally {
    await server.dispose();
  }
}
