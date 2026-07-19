import 'dart:async';
import 'dart:io';
import 'package:playwright_protocol/playwright_protocol.dart';
import '../../transport/web_socket_transport.dart';
import '../../registry/registry.dart';
import 'ff_connection.dart';
import 'ff_browser.dart';

class FirefoxBrowserType {
  final BrowserRegistry _registry;
  FirefoxBrowserType(this._registry);

  String get name => 'firefox';

  Future<FfBrowser> launch({bool headless = true, List<String>? args}) async {
    final executablePath = _registry.executablePath(name);
    if (executablePath == null) {
      throw PlaywrightException('\$name executable not found.');
    }
    
    final launchArgs = <String>[
      '-no-remote',
      '-wait-for-browser',
      '-foreground',
      '-juggler-pipe', // We will use juggler 0 (WebSocket) instead of pipe for Windows support
    ];
    
    if (headless) {
      launchArgs.add('-headless');
    }
    
    // For Windows Dart, WebSocket is better. Juggler supports -juggler <port>
    final wsArgs = List<String>.from(launchArgs)
      ..remove('-juggler-pipe')
      ..addAll(['-juggler', '0']); // 0 means pick any free port
      
    if (args != null) {
      wsArgs.addAll(args);
    }
    
    final process = await Process.start(executablePath, wsArgs);
    
    // Parse the Juggler listening port from stdout/stderr
    final wsUrlCompleter = Completer<String>();
    process.stderr.transform(SystemEncoding().decoder).listen((line) {
      print('[Firefox] \$line');
      final match = RegExp(r'Juggler listening on (ws://.*)').firstMatch(line);
      if (match != null && !wsUrlCompleter.isCompleted) {
        wsUrlCompleter.complete(match.group(1));
      }
    });

    final wsUrl = await wsUrlCompleter.future;
    
    final transport = await WebSocketTransport.connect(wsUrl);
    final connection = FfConnection(transport);
    final ffBrowser = FfBrowser(connection);
    await ffBrowser.init();
    
    return ffBrowser; // Wait, public API expects Browser. We need to wrap it.
  }
}
