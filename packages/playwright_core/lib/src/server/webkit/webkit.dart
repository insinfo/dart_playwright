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
    
    // Mirrors upstream webkit.ts defaultArgs (non-persistent launch).
    final launchArgs = <String>['--inspector-pipe'];

    if (Platform.isWindows) {
      launchArgs.add('--disable-accelerated-compositing');
    }
    if (headless) {
      launchArgs.add('--headless');
    }
    // Without this, WebKit opens a startup window — which aborts on
    // display-less Linux even in headless mode.
    launchArgs.add('--no-startup-window');

    if (args != null) {
      launchArgs.addAll(args);
    }
    
    final transport =
        await launchBrowserWithInspectorPipe(executablePath, launchArgs);
    try {
      final connection = WkConnection(transport);
      final environment = Map<String, String>.from(Platform.environment);
      environment['CURL_OPT_NO_AUTOMATION_WARNING'] = '1';
      final wkBrowser = WkBrowser(connection);
      await wkBrowser.init();

      return wkBrowser;
    } catch (e) {
      await transport.close();
      rethrow;
    }
  }
}
