import 'dart:async';
import 'dart:io';

import 'package:playwright_protocol/playwright_protocol.dart';
import 'package:playwright_core/playwright_core.dart';
import '../../transport/browser_pipe_launcher.dart';
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

    // CDP over fd3/fd4, exactly like upstream Playwright. Chromium reads the
    // fds installed by our lpReserved2 (Windows) or FIFO/sh (POSIX) launchers
    // and frames messages with a trailing \0 — the same framing as the
    // Firefox/WebKit inspector pipes.
    if (!chromeArgs.any((arg) => arg.startsWith('--remote-debugging-'))) {
      chromeArgs.add('--remote-debugging-pipe');
    }

    String? tempUserDataDir;
    if (options.userDataDir == null) {
      final tempDir = Directory.systemTemp.createTempSync('playwright_chromium_');
      tempUserDataDir = tempDir.path;
      chromeArgs.add('--user-data-dir=$tempUserDataDir');
    } else {
      chromeArgs.add('--user-data-dir=${options.userDataDir}');
    }

    final transport = await launchBrowserWithInspectorPipe(execPath, chromeArgs);

    try {
      final connection = CRConnection(transport);
      final browser = await CrBrowser.connect(connection, null, tempUserDataDir);
      return browser;
    } catch (e) {
      await transport.close();
      if (tempUserDataDir != null) {
        try {
          Directory(tempUserDataDir).deleteSync(recursive: true);
        } catch (_) {}
      }
      rethrow;
    }
  }
}
