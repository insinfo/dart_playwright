import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:playwright_protocol/playwright_protocol.dart';

import '../../registry/registry.dart';
import '../../transport/browser_pipe_launcher.dart';
import '../../transport/slow_mo_transport.dart';
import '../../transport/transport.dart';
import '../launch_options.dart';
import 'ff_browser.dart';
import 'ff_connection.dart';

class FirefoxBrowserType {
  final BrowserRegistry _registry;
  FirefoxBrowserType(this._registry);

  String get name => 'firefox';

  /// The command line Firefox is started with, mirroring upstream's
  /// `defaultArgs`.
  List<String> defaultArgs(CoreLaunchOptions options, String userDataDir) {
    for (final arg in options.args) {
      if (arg.startsWith('-profile') || arg.startsWith('--profile')) {
        throw ArgumentError.value(arg, 'args',
            'Pass userDataDir to launchPersistentContext instead of -profile');
      }
      if (arg.startsWith('-juggler')) {
        throw ArgumentError.value(
            arg, 'args', 'Playwright manages the Juggler pipe itself');
      }
    }

    final defaults = <String>[
      '-no-remote',
      if (options.headless)
        '-headless'
      else ...[
        '-wait-for-browser',
        // -foreground is macOS-only; elsewhere it only produces a warning.
        if (Platform.isMacOS) '-foreground',
      ],
    ];

    final args = options.assembleArgs(defaults);
    args.addAll(['-profile', userDataDir]);
    args.add('-juggler-pipe');
    // A persistent context opens a window; a plain launch stays silent and
    // creates its contexts over the protocol.
    args.add(options.isPersistent ? 'about:blank' : '-silent');
    return args;
  }

  /// Writes `user.js` into the profile so Firefox picks up the caller's
  /// `about:config` preferences.
  ///
  /// The proxy does not go here: Juggler sets it over the protocol with
  /// `Browser.setBrowserProxy`, which is what upstream does and what makes
  /// a per-context override possible at all.
  void prepareUserDataDir(CoreLaunchOptions options, String userDataDir) {
    final prefs = options.firefoxUserPrefs;
    if (prefs == null || prefs.isEmpty) return;
    final buffer = StringBuffer();
    prefs.forEach((key, value) {
      buffer.writeln('user_pref(${jsonEncode(key)}, ${jsonEncode(value)});');
    });
    File(p.join(userDataDir, 'user.js')).writeAsStringSync(buffer.toString());
  }

  Future<FfBrowser> launch(
      {CoreLaunchOptions options = const CoreLaunchOptions()}) async {
    options.validateFor(name);
    final executablePath =
        options.resolveExecutable(name, _registry.executablePath);
    final profile = options.resolveUserDataDir(name);
    prepareUserDataDir(options, profile.dir);
    final launchArgs = defaultArgs(options, profile.dir);

    ConnectionTransport transport = await launchBrowserWithInspectorPipe(
      executablePath,
      launchArgs,
      environment: options.processEnvironment,
      handleSIGINT: options.handleSIGINT,
      handleSIGTERM: options.handleSIGTERM,
      handleSIGHUP: options.handleSIGHUP,
    );
    if (options.slowMo != null) {
      transport = SlowMoTransport(transport, options.slowMo!);
    }

    try {
      final connection = FfConnection(transport);
      final ffBrowser = FfBrowser(connection);
      ffBrowser.launchDownloadsPath = options.downloadsPath;
      ffBrowser.tracesDir = options.tracesDir;
      ffBrowser.tempUserDataDir =
          profile.temporary.isEmpty ? null : profile.temporary.first;
      final init = ffBrowser.init(
          persistentContext: options.isPersistent,
          contextOptions: options.persistentContextOptions,
          proxy: options.proxy);
      await (options.timeout == Duration.zero
          ? init
          : init.timeout(options.timeout,
              onTimeout: () => throw PlaywrightException(
                  'Timed out after ${options.timeout.inMilliseconds}ms waiting '
                  'for Firefox to start.')));
      return ffBrowser;
    } catch (e) {
      await transport.close();
      for (final dir in profile.temporary) {
        try {
          Directory(dir).deleteSync(recursive: true);
        } catch (_) {}
      }
      rethrow;
    }
  }
}
