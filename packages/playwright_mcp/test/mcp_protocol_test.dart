import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';
import 'package:playwright_mcp/playwright_mcp.dart';
import 'package:test/test.dart';

import 'test_server.dart';

/// Drives the MCP server the way a client does: as a separate process
/// speaking newline-delimited JSON-RPC 2.0 over stdio.
///
/// Calling the Dart functions directly would prove the tools work, not that
/// the server speaks MCP, so the whole flow runs through the pipe.
class McpClient {
  final Process _process;
  final StreamQueue<String> _lines;
  var _nextId = 0;

  McpClient._(this._process, this._lines);

  static Future<McpClient> start({String browser = 'chromium'}) async {
    final process = await Process.start(
      Platform.resolvedExecutable,
      ['run', 'playwright_mcp', '--browser', browser],
      workingDirectory: _packageRoot,
    );
    // The server writes diagnostics to stderr; surface them if a test hangs.
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => printOnFailure('[server] $line'));
    final lines = StreamQueue<String>(process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .where((line) => line.trim().isNotEmpty));
    return McpClient._(process, lines);
  }

  static String get _packageRoot {
    // The test runs from the package directory or the workspace root.
    final here = Directory.current.path;
    if (here.endsWith('playwright_mcp')) return here;
    return '$here${Platform.pathSeparator}packages'
        '${Platform.pathSeparator}playwright_mcp';
  }

  /// Sends a request and waits for its reply.
  Future<Map<String, dynamic>> request(String method,
      [Map<String, dynamic>? params]) async {
    final id = ++_nextId;
    _send({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    });
    final reply = await _nextMessage();
    expect(reply['id'], equals(id), reason: 'reply out of order: $reply');
    return reply;
  }

  /// Sends a notification, which must not be answered.
  void notify(String method, [Map<String, dynamic>? params]) {
    _send({
      'jsonrpc': '2.0',
      'method': method,
      if (params != null) 'params': params,
    });
  }

  /// Writes a raw line, for the malformed-input cases.
  void sendRaw(String line) => _process.stdin.writeln(line);

  void _send(Map<String, dynamic> message) =>
      _process.stdin.writeln(jsonEncode(message));

  Future<Map<String, dynamic>> _nextMessage() async {
    final line = await _lines.next.timeout(const Duration(seconds: 120));
    try {
      return jsonDecode(line) as Map<String, dynamic>;
    } on FormatException catch (error) {
      // Anything that is not a protocol message on stdout is a bug worth
      // naming: a stdio server's stdout is the protocol channel, and one
      // stray diagnostic line breaks every client. Say which line it was.
      throw StateError('Non-protocol output on the server stdout: '
          '"$line" ($error)');
    }
  }

  /// The next message, or null when nothing arrives within [within].
  Future<Map<String, dynamic>?> nextOrNull(
      {Duration within = const Duration(seconds: 2)}) async {
    final hasNext =
        await _lines.hasNext.timeout(within, onTimeout: () => false);
    if (!hasNext) return null;
    return jsonDecode(await _lines.next) as Map<String, dynamic>;
  }

  Future<void> close() async {
    await _process.stdin.close();
    await _process.exitCode.timeout(const Duration(seconds: 30), onTimeout: () {
      _process.kill();
      return -1;
    });
  }
}

void main() {
  group('MCP over stdio', () {
    late TestServer server;

    setUpAll(() async {
      server = await TestServer.start();
    });

    tearDownAll(() async {
      await server.stop();
    });

    test('Handshake legado: initialize, initialized, tools/list, tools/call',
        () async {
      final client = await McpClient.start();
      addTearDown(client.close);

      final initialize = await client.request('initialize', {
        'protocolVersion': '2025-06-18',
        'capabilities': <String, dynamic>{},
        'clientInfo': {'name': 'dart-test', 'version': '1.0.0'},
      });
      final init = initialize['result'] as Map<String, dynamic>;
      // The server echoes a version it supports.
      expect(init['protocolVersion'], equals('2025-06-18'));
      expect((init['capabilities'] as Map)['tools'], isNotNull);
      expect(
          (init['serverInfo'] as Map)['name'], equals('playwright-dart-mcp'));

      // A notification must not be answered at all.
      client.notify('notifications/initialized');

      final list = await client.request('tools/list');
      final tools = ((list['result'] as Map)['tools'] as List)
          .cast<Map<String, dynamic>>();
      expect(tools.length, greaterThanOrEqualTo(20));
      expect(tools.map((t) => t['name']), contains('browser_navigate'));
      expect(tools.map((t) => t['name']), contains('browser_snapshot'));
      for (final tool in tools) {
        expect(tool['description'], isA<String>());
        expect((tool['inputSchema'] as Map)['type'], equals('object'));
      }

      // A call that really drives a browser and returns page content.
      final call = await client.request('tools/call', {
        'name': 'browser_navigate',
        'arguments': {'url': server.url('/title')},
      });
      final result = call['result'] as Map<String, dynamic>;
      expect(result['isError'], isFalse);
      final text = ((result['content'] as List).first as Map)['text'] as String;
      expect(text, contains('/title'));
      expect(text, contains('Test Page Title'));
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('Negociacao moderna: server/discover e versao nao suportada',
        () async {
      final client = await McpClient.start();
      addTearDown(client.close);

      final discover = await client.request('server/discover', {
        '_meta': {
          'io.modelcontextprotocol/protocolVersion': '2026-07-28',
          'io.modelcontextprotocol/clientInfo': {
            'name': 'dart-test',
            'version': '1.0.0',
          },
        },
      });
      final result = discover['result'] as Map<String, dynamic>;
      expect(result['supportedVersions'], contains('2026-07-28'));
      expect((result['capabilities'] as Map)['tools'], isNotNull);
      expect(
          ((result['_meta'] as Map)['io.modelcontextprotocol/serverInfo']
              as Map)['name'],
          equals('playwright-dart-mcp'));

      // A version the server does not speak is refused with the code the
      // specification assigns, and the reply says what it does speak.
      final refused = await client.request('tools/list', {
        '_meta': {'io.modelcontextprotocol/protocolVersion': '1900-01-01'},
      });
      final error = refused['error'] as Map<String, dynamic>;
      expect(error['code'], equals(McpErrorCodes.unsupportedProtocolVersion));
      expect((error['data'] as Map)['requested'], equals('1900-01-01'));
      expect((error['data'] as Map)['supported'], contains('2026-07-28'));

      // A supported modern version goes through.
      final ok = await client.request('tools/list', {
        '_meta': {'io.modelcontextprotocol/protocolVersion': '2026-07-28'},
      });
      expect(ok['result'], isNotNull);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('initialize com versao desconhecida responde a versao do servidor',
        () async {
      final client = await McpClient.start();
      addTearDown(client.close);

      final initialize = await client.request('initialize', {
        'protocolVersion': '1999-01-01',
      });
      // A legacy client cannot fall forward, so the server names its own.
      expect((initialize['result'] as Map)['protocolVersion'],
          equals(PlaywrightMcpServer.latestLegacyProtocolVersion));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('Caminhos de erro: JSON invalido, metodo e ferramenta inexistentes',
        () async {
      final client = await McpClient.start();
      addTearDown(client.close);

      client.sendRaw('{ this is not json');
      final parseError =
          await client.nextOrNull(within: const Duration(seconds: 20));
      expect(parseError, isNotNull);
      expect((parseError!['error'] as Map)['code'],
          equals(McpErrorCodes.parseError));
      expect(parseError['id'], isNull);

      final unknownMethod = await client.request('no/such/method');
      expect((unknownMethod['error'] as Map)['code'],
          equals(McpErrorCodes.methodNotFound));

      final unknownTool = await client.request('tools/call', {
        'name': 'browser_does_not_exist',
        'arguments': <String, dynamic>{},
      });
      expect((unknownTool['error'] as Map)['code'],
          equals(McpErrorCodes.methodNotFound));

      // A missing required argument is a tool error the model can read, not
      // a transport error.
      final missingArgument = await client.request('tools/call', {
        'name': 'browser_navigate',
        'arguments': <String, dynamic>{},
      });
      final result = missingArgument['result'] as Map<String, dynamic>;
      expect(result['isError'], isTrue);
      expect(
          ((result['content'] as List).first as Map)['text'], contains('url'));

      // Malformed params are refused as invalid params.
      final badParams = await client.request('tools/call', {'name': 42});
      expect((badParams['error'] as Map)['code'],
          equals(McpErrorCodes.invalidParams));
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('Notificacao desconhecida nao recebe resposta', () async {
      final client = await McpClient.start();
      addTearDown(client.close);

      client.notify('notifications/something_unknown');
      // Nothing must come back for a notification, known or not.
      expect(await client.nextOrNull(), isNull);

      // The connection is still usable afterwards.
      final ping = await client.request('ping');
      expect(ping['result'], isNotNull);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('Fluxo de agente: snapshot, clique por ref e leitura do console',
        () async {
      final client = await McpClient.start();
      addTearDown(client.close);

      await client.request('initialize', {'protocolVersion': '2025-06-18'});
      client.notify('notifications/initialized');

      await client.request('tools/call', {
        'name': 'browser_navigate',
        'arguments': {'url': server.url('/button')},
      });

      final snapshot = await client.request('tools/call', {
        'name': 'browser_snapshot',
        'arguments': <String, dynamic>{},
      });
      final tree = (((snapshot['result'] as Map)['content'] as List).first
          as Map)['text'] as String;
      expect(tree, contains('button'));
      expect(tree, contains('[ref='));

      // Pull a ref out of the snapshot and act on it, which is the whole
      // point of the snapshot format.
      final ref = RegExp(r'- button [^\n]*\[ref=(e\d+)\]').firstMatch(tree);
      expect(ref, isNotNull, reason: 'no button ref in snapshot:\n$tree');

      final click = await client.request('tools/call', {
        'name': 'browser_click',
        'arguments': {'ref': ref!.group(1)},
      });
      expect((click['result'] as Map)['isError'], isFalse);

      // The click was a real, trusted one: the page records event.isTrusted.
      final evaluated = await client.request('tools/call', {
        'name': 'browser_evaluate',
        'arguments': {'expression': '() => window.__clicked'},
      });
      expect(
          (((evaluated['result'] as Map)['content'] as List).first
              as Map)['text'],
          equals('true'));
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
