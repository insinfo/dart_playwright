/// A Model Context Protocol server that drives a real browser through the
/// Dart port of Playwright.
///
/// Run it as a program (`dart run playwright_mcp`), or embed it:
///
/// ```dart
/// final server = PlaywrightMcpServer(
///   session: BrowserSession(browserName: 'firefox'),
/// );
/// server.registerTool(MyTool());
/// await server.serve();
/// ```
library playwright_mcp;

export 'src/browser_session.dart'
    show BrowserSession, ConsoleEntry, NetworkEntry;
export 'src/mcp_server.dart' show McpErrorCodes, PlaywrightMcpServer;
export 'src/mcp_tool.dart' show McpResult, McpTool, requireString;
export 'src/tools/browser_tools.dart' show defaultTools;
export 'src/tools/snapshot.dart'
    show renderSnapshot, resolveTarget, snapshotScript, targetSchemaProperties;
