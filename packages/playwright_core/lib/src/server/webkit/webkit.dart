import 'dart:async';
import 'dart:io';

import 'package:playwright_protocol/playwright_protocol.dart';

import '../../registry/registry.dart';
import '../../transport/browser_pipe_launcher.dart';
import '../../transport/slow_mo_transport.dart';
import '../../transport/transport.dart';
import '../launch_options.dart';
import 'wk_browser.dart';
import 'wk_connection.dart';

class WebKitBrowserType {
  final BrowserRegistry _registry;
  WebKitBrowserType(this._registry);

  String get name => 'webkit';

  /// The command line WebKit is started with, mirroring upstream's
  /// `defaultArgs`.
  List<String> defaultArgs(CoreLaunchOptions options, String userDataDir) {
    for (final arg in options.args) {
      if (arg.startsWith('--user-data-dir')) {
        throw ArgumentError.value(
            arg,
            'args',
            'Pass userDataDir to launchPersistentContext instead of '
                '--user-data-dir');
      }
    }

    final defaults = <String>[
      '--inspector-pipe',
      if (Platform.isWindows) '--disable-accelerated-compositing',
      if (options.headless) '--headless',
      ..._proxyArgs(options.proxy),
    ];

    final args = options.assembleArgs(defaults);
    if (options.isPersistent) {
      args.add('--user-data-dir=$userDataDir');
      args.add('about:blank');
    } else {
      // Without this WebKit opens a startup window, which aborts on a
      // display-less Linux even in headless mode.
      args.add('--no-startup-window');
    }
    return args;
  }

  /// WebKit takes its proxy through different switches per platform: the
  /// macOS and Linux builds use the network process's own options, the
  /// Windows build goes through curl.
  static List<String> _proxyArgs(CoreProxySettings? proxy) {
    if (proxy == null) return const [];
    final settings = proxy.normalized();
    if (Platform.isWindows) {
      return <String>[
        '--curl-proxy=${settings.server.replaceFirst('socks5://', 'socks5h://')}',
        if (settings.bypass != null) '--curl-noproxy=${settings.bypass}',
      ];
    }
    if (Platform.isMacOS) {
      return <String>[
        '--proxy=${settings.server}',
        if (settings.bypass != null) '--proxy-bypass-list=${settings.bypass}',
      ];
    }
    return <String>[
      '--proxy=${settings.server}',
      if (settings.bypass != null)
        ...settings.bypass!.split(',').map((t) => '--ignore-host=${t.trim()}'),
    ];
  }

  Future<WkBrowser> launch(
      {CoreLaunchOptions options = const CoreLaunchOptions()}) async {
    options.validateFor(name);
    final executablePath =
        options.resolveExecutable(name, _registry.executablePath);
    final profile = options.resolveUserDataDir(name);
    final launchArgs = defaultArgs(options, profile.dir);

    final environment = <String, String>{
      ...(options.processEnvironment ?? Platform.environment),
      'CURL_OPT_NO_AUTOMATION_WARNING': '1',
    };

    ConnectionTransport transport = await launchBrowserWithInspectorPipe(
      executablePath,
      launchArgs,
      environment: environment,
      handleSIGINT: options.handleSIGINT,
      handleSIGTERM: options.handleSIGTERM,
      handleSIGHUP: options.handleSIGHUP,
    );
    if (options.slowMo != null) {
      transport = SlowMoTransport(transport, options.slowMo!);
    }

    try {
      final connection = WkConnection(transport);
      final wkBrowser = WkBrowser(connection);
      wkBrowser.launchDownloadsPath = options.downloadsPath;
      wkBrowser.tracesDir = options.tracesDir;
      wkBrowser.tempUserDataDir =
          profile.temporary.isEmpty ? null : profile.temporary.first;
      final init = wkBrowser.init(
          persistentContext: options.isPersistent,
          contextOptions: options.persistentContextOptions);
      await (options.timeout == Duration.zero
          ? init
          : init.timeout(options.timeout,
              onTimeout: () => throw PlaywrightException(
                  'Timed out after ${options.timeout.inMilliseconds}ms waiting '
                  'for WebKit to start.')));
      return wkBrowser;
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
