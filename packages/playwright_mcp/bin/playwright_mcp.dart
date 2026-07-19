import 'dart:io';
import 'package:playwright_mcp/src/mcp_server.dart';

void main(List<String> args) async {
  String browserName = 'chromium';
  for (int i = 0; i < args.length; i++) {
    if (args[i] == '--browser' && i + 1 < args.length) {
      browserName = args[i + 1];
    }
  }
  
  try {
    final server = PlaywrightMcpServer();
    await server.start(browserName: browserName);
  } catch (e, st) {
    stderr.writeln('Fatal error starting Playwright MCP Server: $e');
    stderr.writeln(st);
    exit(1);
  }
}
