import 'dart:async';
import 'dart:io';
import 'package:playwright_protocol/playwright_protocol.dart';
import '../../registry/registry.dart';
import '../../transport/browser_pipe_launcher.dart';
import 'ff_connection.dart';
import 'ff_browser.dart';

class FirefoxBrowserType {
  final BrowserRegistry _registry;
  FirefoxBrowserType(this._registry);

  String get name => 'firefox';

  Future<FfBrowser> launch({bool headless = true, List<String>? args}) async {
    final executablePath = _registry.executablePath(name);
    if (executablePath == null) {
      throw PlaywrightException('$name executable not found.');
    }
    
    final launchArgs = <String>[
      '-no-remote',
      '-wait-for-browser',
      // -foreground is a macOS-only flag; other platforms warn about it.
      if (Platform.isMacOS) '-foreground',
      '-juggler-pipe',
    ];
    
    if (headless) {
      launchArgs.add('-headless');
    }
    
    if (args != null) {
      launchArgs.addAll(args);
    }
    
    final tempDir = Directory.systemTemp.createTempSync('playwright_firefox_');
    if (!launchArgs.contains('-profile') && !launchArgs.contains('--profile')) {
      launchArgs.addAll(['-profile', tempDir.path]);
    }

    final transport =
        await launchBrowserWithInspectorPipe(executablePath, launchArgs);
    try {
      final connection = FfConnection(transport);
      final ffBrowser = FfBrowser(connection);
      await ffBrowser.init();
      return ffBrowser;
    } catch (e) {
      await transport.close();
      rethrow;
    }
  }
}
