import 'dart:async';
import 'dart:io';

import 'package:playwright_protocol/playwright_protocol.dart';
import 'package:playwright_core/playwright_core.dart';
import 'chromium_switches.dart';
import 'cr_connection.dart';
import 'cr_browser.dart';

/// Configuration for launching Chromium.
class ChromiumLaunchOptions {
  final bool headless;
  final String? executablePath;
  final List<String> args;
  final List<String>? ignoreDefaultArgs;
  final Map<String, String>? env;
  final Duration? timeout;
  final String? userDataDir;
  final String? downloadsPath;

  const ChromiumLaunchOptions({
    this.headless = true,
    this.executablePath,
    this.args = const [],
    this.ignoreDefaultArgs,
    this.env,
    this.timeout,
    this.userDataDir,
    this.downloadsPath,
  });
}

/// BrowserType implementation for Chromium.
class ChromiumBrowserType {
  final BrowserRegistry _registry;

  ChromiumBrowserType(this._registry);

  String get name => 'chromium';

  String _executablePath(ChromiumLaunchOptions options) {
    if (options.executablePath != null) return options.executablePath!;
    final path = _registry.executablePath('chromium');
    if (path == null) {
      throw PlaywrightException(
          'Chromium executable not found. Run `playwright install chromium`.');
    }
    return path;
  }

  /// Launch a local Chromium browser instance.
  Future<CrBrowser> launch({ChromiumLaunchOptions options = const ChromiumLaunchOptions()}) async {
    final execPath = _executablePath(options);

    final chromeArgs = <String>[];
    chromeArgs.addAll(ChromiumSwitches.defaultSwitches);

    if (options.headless) {
      chromeArgs.addAll(ChromiumSwitches.headlessSwitches);
    }

    // Combine user args
    if (options.ignoreDefaultArgs != null) {
      chromeArgs.removeWhere((arg) => options.ignoreDefaultArgs!.contains(arg));
    }
    chromeArgs.addAll(options.args);

    // Required for WebSocket transport in Dart (Pipe needs extra FDs not supported natively)
    if (!chromeArgs.any((arg) => arg.startsWith('--remote-debugging-'))) {
      chromeArgs.add('--remote-debugging-port=0');
    }

    String? tempUserDataDir;
    if (options.userDataDir == null) {
      final tempDir = Directory.systemTemp.createTempSync('playwright_chromium_');
      tempUserDataDir = tempDir.path;
      chromeArgs.add('--user-data-dir=$tempUserDataDir');
    } else {
      chromeArgs.add('--user-data-dir=${options.userDataDir}');
    }

    final process = await Process.start(
      execPath,
      chromeArgs,
      environment: options.env,
    );

    // Wait for the WebSocket URL on stderr
    final completer = Completer<String>();
    process.stderr.transform(SystemEncoding().decoder).listen((line) {
      if (line.contains('DevTools listening on ws://')) {
        final match = RegExp(r'ws://[^\s]+').firstMatch(line);
        if (match != null && !completer.isCompleted) {
          completer.complete(match.group(0));
        }
      }
    });

    try {
      final wsUrl = await completer.future.timeout(const Duration(seconds: 15));
      final transport = await WebSocketTransport.connect(wsUrl);
      final connection = CRConnection(transport);

      final browser = await CrBrowser.connect(connection, process, tempUserDataDir);
      return browser;
    } catch (e) {
      process.kill();
      if (tempUserDataDir != null) {
        try {
          Directory(tempUserDataDir).deleteSync(recursive: true);
        } catch (_) {}
      }
      rethrow;
    }
  }
}
