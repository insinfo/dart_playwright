import 'dart:io';
import 'package:playwright_mcp/src/mcp_server.dart';

void main(List<String> args) async {
  try {
    final server = PlaywrightMcpServer();
    await server.start();
  } catch (e, st) {
    stderr.writeln('Fatal error starting Playwright MCP Server: \$e');
    stderr.writeln(st);
    exit(1);
  }
}
