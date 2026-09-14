import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'browser_session.dart';
import 'mcp_tool.dart';
import 'tools/browser_tools.dart';

/// JSON-RPC and MCP error codes this server can return.
abstract final class McpErrorCodes {
  static const parseError = -32700;
  static const invalidRequest = -32600;
  static const methodNotFound = -32601;
  static const invalidParams = -32602;
  static const internalError = -32603;

  /// MCP's own code for "I do not speak that protocol revision"
  /// (`UnsupportedProtocolVersionError`).
  static const unsupportedProtocolVersion = -32022;
}

/// An MCP server exposing this Playwright port as tools, over stdio.
///
/// It is **dual-era**, in the specification's terms:
///
/// - *Modern* clients (revision `2026-07-28` and later) declare the protocol
///   version on every request, in
///   `params._meta["io.modelcontextprotocol/protocolVersion"]`, and may call
///   `server/discover` — which servers MUST implement — to learn what this
///   server supports. A version this server does not speak is refused with
///   `UnsupportedProtocolVersionError` (-32022), carrying the supported list.
/// - *Legacy* clients (`2025-11-25` and earlier) open with an `initialize`
///   handshake. The reply echoes the client's version when it is supported,
///   and otherwise names this server's newest legacy version, which is all a
///   legacy client can act on.
///
/// Embed it in your own program, register your own tools with
/// [registerTool], and call [serve].
class PlaywrightMcpServer {
  /// Protocol revisions this server speaks, newest first.
  ///
  /// `2026-07-28` is the modern, per-request-metadata revision; the rest are
  /// handshake-based and reached through `initialize`.
  static const supportedProtocolVersions = <String>[
    '2026-07-28',
    '2025-11-25',
    '2025-06-18',
    '2025-03-26',
    '2024-11-05',
  ];

  /// The newest handshake-based revision, used when a legacy client asks for
  /// one this server does not speak.
  static const latestLegacyProtocolVersion = '2025-11-25';

  /// The `_meta` key a modern request declares its protocol version under.
  static const protocolVersionMetaKey =
      'io.modelcontextprotocol/protocolVersion';

  static const serverName = 'playwright-dart-mcp';
  static const serverVersion = '0.1.0';

  final BrowserSession session;
  final Map<String, McpTool> _tools = {};

  /// The protocol version a legacy client settled on, or null while no
  /// `initialize` has arrived.
  String? negotiatedProtocolVersion;

  PlaywrightMcpServer({
    BrowserSession? session,
    List<McpTool>? tools,
  }) : session = session ?? BrowserSession() {
    for (final tool in tools ?? defaultTools()) {
      registerTool(tool);
    }
  }

  /// Adds a tool, replacing any tool of the same name.
  void registerTool(McpTool tool) => _tools[tool.name] = tool;

  /// The registered tools, by name.
  Map<String, McpTool> get tools => Map.unmodifiable(_tools);

  /// Reads newline-delimited JSON-RPC from [input] and writes replies to
  /// [output], returning when [input] ends.
  ///
  /// Defaults to stdin and stdout, which is the stdio transport.
  Future<void> serve({Stream<List<int>>? input, IOSink? output}) async {
    final source = input ?? stdin;
    final sink = output ?? stdout;

    await for (final line
        in source.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;
      final reply = await handleLine(line);
      // A notification produces no reply at all; JSON-RPC forbids one.
      if (reply != null) {
        sink.writeln(jsonEncode(reply));
        await sink.flush();
      }
    }
  }

  /// Handles one line of JSON-RPC, returning the reply or null for a
  /// notification. Exposed so a program can drive the server over any
  /// transport, and so the protocol can be tested without a process.
  Future<Map<String, dynamic>?> handleLine(String line) async {
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } catch (error) {
      return _error(null, McpErrorCodes.parseError, 'Parse error: $error');
    }
    if (decoded is! Map<String, dynamic>) {
      // Batches are not supported; say so rather than failing obscurely.
      return _error(null, McpErrorCodes.invalidRequest,
          'Invalid Request: expected a single JSON-RPC object');
    }
    return handleMessage(decoded);
  }

  /// Handles one decoded JSON-RPC message.
  Future<Map<String, dynamic>?> handleMessage(
      Map<String, dynamic> message) async {
    final id = message.containsKey('id') ? message['id'] : null;
    final isNotification = !message.containsKey('id') || message['id'] == null;

    if (message['jsonrpc'] != '2.0') {
      if (isNotification) return null;
      return _error(id, McpErrorCodes.invalidRequest,
          'Invalid Request: "jsonrpc" must be "2.0"');
    }

    final method = message['method'];
    if (method is! String || method.isEmpty) {
      if (isNotification) return null;
      return _error(id, McpErrorCodes.invalidRequest,
          'Invalid Request: "method" must be a non-empty string');
    }

    final params = message['params'];
    if (params != null && params is! Map<String, dynamic>) {
      if (isNotification) return null;
      return _error(id, McpErrorCodes.invalidParams,
          'Invalid params: "params" must be an object');
    }
    final args = (params as Map<String, dynamic>?) ?? const {};

    // Notifications never get a reply, known or not. That is the rule the
    // old implementation applied inconsistently.
    if (isNotification) {
      _handleNotification(method, args);
      return null;
    }

    // `initialize` is the legacy handshake and carries its version in the
    // params, not in `_meta`.
    if (method == 'initialize') return _handleInitialize(id, args);

    final versionError = _checkProtocolVersion(id, args);
    if (versionError != null) return versionError;

    switch (method) {
      case 'server/discover':
        return _handleDiscover(id);
      case 'ping':
        return {'jsonrpc': '2.0', 'id': id, 'result': <String, dynamic>{}};
      case 'tools/list':
        return _handleToolsList(id);
      case 'tools/call':
        return _handleToolsCall(id, args);
      default:
        return _error(id, McpErrorCodes.methodNotFound,
            'Method not found: $method');
    }
  }

  void _handleNotification(String method, Map<String, dynamic> params) {
    // `notifications/initialized` closes the legacy handshake and needs no
    // action here; everything else is ignored on purpose.
  }

  /// Refuses a modern request whose declared protocol version is not one of
  /// [supportedProtocolVersions].
  ///
  /// A request without the `_meta` key is let through: a legacy client sends
  /// none, and rejecting it would break the handshake era.
  Map<String, dynamic>? _checkProtocolVersion(
      Object? id, Map<String, dynamic> params) {
    final meta = params['_meta'];
    if (meta is! Map) return null;
    final requested = meta[protocolVersionMetaKey];
    if (requested == null) return null;
    if (requested is String && supportedProtocolVersions.contains(requested)) {
      return null;
    }
    return {
      'jsonrpc': '2.0',
      'id': id,
      'error': {
        'code': McpErrorCodes.unsupportedProtocolVersion,
        'message': 'Unsupported protocol version',
        'data': {
          'supported': supportedProtocolVersions,
          'requested': requested,
        },
      },
    };
  }

  Map<String, dynamic> _handleDiscover(Object? id) {
    return {
      'jsonrpc': '2.0',
      'id': id,
      'result': {
        'resultType': 'complete',
        'supportedVersions': supportedProtocolVersions,
        'capabilities': {
          'tools': <String, dynamic>{},
        },
        '_meta': {
          'io.modelcontextprotocol/serverInfo': {
            'name': serverName,
            'version': serverVersion,
          },
        },
        'instructions':
            'Drives a real browser (Chromium, Firefox or WebKit) through the '
            'Dart port of Playwright. Call browser_snapshot first: it returns '
            'the page as roles, names and element references, and the other '
            'tools take those references.',
      },
    };
  }

  Map<String, dynamic> _handleInitialize(
      Object? id, Map<String, dynamic> params) {
    final requested = params['protocolVersion'];
    // The handshake rule: echo the client's version when it is supported,
    // otherwise answer with ours and let the client decide whether to go on.
    final version = requested is String &&
            supportedProtocolVersions.contains(requested)
        ? requested
        : latestLegacyProtocolVersion;
    negotiatedProtocolVersion = version;
    return {
      'jsonrpc': '2.0',
      'id': id,
      'result': {
        'protocolVersion': version,
        'capabilities': {
          'tools': {'listChanged': false},
        },
        'serverInfo': {
          'name': serverName,
          'version': serverVersion,
        },
        'instructions':
            'Call browser_snapshot first: it returns the page as roles, names '
            'and element references, and the other tools take those '
            'references.',
      },
    };
  }

  Map<String, dynamic> _handleToolsList(Object? id) {
    return {
      'jsonrpc': '2.0',
      'id': id,
      'result': {
        'tools': [
          for (final tool in _tools.values)
            {
              'name': tool.name,
              'description': tool.description,
              'inputSchema': tool.inputSchema,
            },
        ],
      },
    };
  }

  Future<Map<String, dynamic>> _handleToolsCall(
      Object? id, Map<String, dynamic> params) async {
    final toolName = params['name'];
    if (toolName is! String || toolName.isEmpty) {
      return _error(id, McpErrorCodes.invalidParams,
          'Invalid params: "name" must be a non-empty string');
    }
    final rawArguments = params['arguments'];
    if (rawArguments != null && rawArguments is! Map<String, dynamic>) {
      return _error(id, McpErrorCodes.invalidParams,
          'Invalid params: "arguments" must be an object');
    }

    final tool = _tools[toolName];
    if (tool == null) {
      return _error(id, McpErrorCodes.methodNotFound,
          'Unknown tool: $toolName');
    }

    try {
      final result = await tool.execute(
          session, (rawArguments as Map<String, dynamic>?) ?? const {});
      return {'jsonrpc': '2.0', 'id': id, 'result': result.toJson()};
    } catch (error) {
      // A tool that fails is reported as a tool result, not a JSON-RPC error:
      // the model has to be able to read what went wrong and try again.
      return {
        'jsonrpc': '2.0',
        'id': id,
        'result': McpResult.error('$toolName failed: $error').toJson(),
      };
    }
  }

  Map<String, dynamic> _error(Object? id, int code, String message) => {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': code, 'message': message},
      };

  /// Closes the browser this server opened, if any.
  Future<void> dispose() => session.close();
}
