import 'dart:convert';

import 'browser_session.dart';

/// What a tool hands back to the client.
///
/// The shape is MCP's `CallToolResult`: a list of content blocks plus an
/// `isError` flag. A failed tool is reported this way, not as a JSON-RPC
/// error, so the model can read what went wrong and try something else.
class McpResult {
  final Map<String, dynamic> _data;

  McpResult._(this._data);

  /// A text result.
  factory McpResult.text(String text) {
    return McpResult._({
      'content': [
        {'type': 'text', 'text': text}
      ],
      'isError': false,
    });
  }

  /// An image result, base64-encoded as MCP requires.
  factory McpResult.image(List<int> bytes, {String mimeType = 'image/png'}) {
    return McpResult._({
      'content': [
        {
          'type': 'image',
          'data': base64Encode(bytes),
          'mimeType': mimeType,
        }
      ],
      'isError': false,
    });
  }

  /// A failure the model should see and can act on.
  factory McpResult.error(String message) {
    return McpResult._({
      'content': [
        {'type': 'text', 'text': message}
      ],
      'isError': true,
    });
  }

  Map<String, dynamic> toJson() => _data;
}

/// A tool the server exposes over MCP.
///
/// Implement this and register it with `PlaywrightMcpServer.registerTool` to
/// add your own tool to the server.
abstract class McpTool {
  /// The name the client calls, e.g. `browser_click`.
  String get name;

  /// One line the model reads to decide whether to call this tool.
  String get description;

  /// A JSON Schema object describing [execute]'s arguments.
  Map<String, dynamic> get inputSchema;

  /// Runs the tool.
  ///
  /// Throwing is fine: the server turns it into an error result the model can
  /// read. Return [McpResult.error] when the failure is expected and you want
  /// to word it yourself.
  Future<McpResult> execute(BrowserSession session, Map<String, dynamic> args);
}

/// Reads a required string argument, with a message that names the tool.
String requireString(
    Map<String, dynamic> args, String key, String toolName) {
  final value = args[key];
  if (value is! String || value.isEmpty) {
    throw ArgumentError('$toolName requires a non-empty "$key" argument');
  }
  return value;
}
