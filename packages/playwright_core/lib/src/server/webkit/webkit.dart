import 'dart:async';
import 'dart:io';
import 'package:playwright_protocol/playwright_protocol.dart';
import '../../transport/browser_pipe_launcher.dart';
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
      throw PlaywrightException('$name executable not found.');
    }
    
    final launchArgs = <String>[];
    
    if (headless) {
      launchArgs.add('--headless');
    }
    
    // WebKit uses inspector-pipe just like Firefox/Chromium
    launchArgs.add('--inspector-pipe');
    
    if (args != null) {
      launchArgs.addAll(args);
    }
    
    if (Platform.isWindows) {
      launchArgs.add('--disable-accelerated-compositing');
    }
    
    final transport =
        await launchBrowserWithInspectorPipe(executablePath, launchArgs);
    try {
      final connection = WkConnection(transport);
      final wkBrowser = WkBrowser(connection);
      await wkBrowser.init();

      return wkBrowser;
    } catch (e) {
      await transport.close();
      rethrow;
    }
  }
}
