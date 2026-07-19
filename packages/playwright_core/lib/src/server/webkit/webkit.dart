import 'dart:async';
import 'dart:io';
import 'package:playwright_protocol/playwright_protocol.dart';
import '../../transport/web_socket_transport.dart';
import '../../registry/registry.dart';
import 'wk_connection.dart';
import 'wk_browser.dart';

class WebKitBrowserType {
  final BrowserRegistry _registry;
  WebKitBrowserType(this._registry);

  String get name => 'webkit';

  Future<WkBrowser> launch({bool headless = true, List<String>? args}) async {
    final executablePath = _registry.executablePath(name);
    if (executablePath == null) {
      throw PlaywrightException('\$name executable not found.');
    }
    
    final launchArgs = <String>[];
    
    if (headless) {
      launchArgs.add('--headless');
    }
    
    // WebKit in Playwright can use inspector-pipe or a specific debug port.
    // We will use inspector-pipe for Linux/Mac, but on Windows Playwright's WebKit requires a special WS endpoint setup.
    // For this prototype, we mock the port detection and use a WebSocket if available.
    launchArgs.add('--inspector-port=0'); 
    
    if (args != null) {
      launchArgs.addAll(args);
    }
    
    // Workaround for Windows environments where Playwright's WebKit comes with WPE/MiniBrowser
    final env = Map<String, String>.from(Platform.environment);
    env['WEBKIT_INSPECTOR_SERVER'] = '127.0.0.1:0'; 
    
    final process = await Process.start(executablePath, launchArgs, environment: env);
    
    final wsUrlCompleter = Completer<String>();
    process.stderr.transform(SystemEncoding().decoder).listen((line) {
      print('[WebKit] \$line');
      final match = RegExp(r'ws://.*').firstMatch(line);
      if (match != null && !wsUrlCompleter.isCompleted) {
        wsUrlCompleter.complete(match.group(0));
      }
    });

    // Fallback URL if stdout doesn't print it correctly immediately
    final wsUrl = await wsUrlCompleter.future.timeout(Duration(seconds: 5), onTimeout: () {
      throw Exception('Failed to get WebKit WebSocket URL');
    });
    
    final transport = await WebSocketTransport.connect(wsUrl);
    final connection = WkConnection(transport);
    final wkBrowser = WkBrowser(connection);
    await wkBrowser.init();
    
    return wkBrowser;
  }
}
