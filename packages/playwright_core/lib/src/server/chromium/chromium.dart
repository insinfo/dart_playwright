import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:playwright_core/playwright_core.dart';
import 'package:playwright_protocol/playwright_protocol.dart';

import '../../transport/browser_pipe_launcher.dart';
import '../../transport/slow_mo_transport.dart';
import '../launch_options.dart';
import 'chromium_switches.dart';
import 'cr_browser.dart';
import 'cr_connection.dart';

/// BrowserType implementation for Chromium.
class ChromiumBrowserType {
  final BrowserRegistry _registry;

  ChromiumBrowserType(this._registry);

  String get name => 'chromium';

  /// The command line Chromium is started with, mirroring upstream's
  /// `defaultArgs`. Exposed so the argument assembly can be tested without
  /// launching a browser.
  List<String> defaultArgs(CoreLaunchOptions options, String userDataDir) {
    for (final arg in options.args) {
      if (arg.startsWith('--user-data-dir')) {
        throw ArgumentError.value(
            arg,
            'args',
            'Pass userDataDir to launchPersistentContext instead of '
                '--user-data-dir');
      }
      if (arg.startsWith('--remote-debugging-')) {
        throw ArgumentError.value(arg, 'args',
            'Playwright manages the remote debugging connection itself');
      }
    }

    final defaults = <String>[
      ...ChromiumSwitches.defaultSwitches,
      if (options.headless) ...ChromiumSwitches.headlessSwitches,
      // Upstream turns the sandbox off unless asked; keeping it on is what
      // `chromiumSandbox: true` buys.
      if (!options.chromiumSandbox) '--no-sandbox',
      ..._proxyArgs(options.proxy),
    ];

    final chromeArgs = options.assembleArgs(defaults);
    // Not part of the ignorable defaults: without them there is no
    // connection and no profile at all.
    chromeArgs.add('--user-data-dir=$userDataDir');
    chromeArgs.add('--remote-debugging-pipe');
    // A persistent context is expected to come with a page already open; a
    // plain launch starts with no window and creates its own contexts.
    chromeArgs
        .add(options.isPersistent ? 'about:blank' : '--no-startup-window');
    return chromeArgs;
  }

  static List<String> _proxyArgs(CoreProxySettings? proxy) {
    if (proxy == null) return const [];
    final settings = proxy.normalized();
    final url = Uri.parse(settings.server);
    return <String>[
      // Chromium resolves hostnames itself even behind a SOCKS proxy, which
      // leaks DNS; upstream blocks that with a host-resolver rule.
      if (url.scheme == 'socks5')
        '--host-resolver-rules=MAP * ~NOTFOUND , EXCLUDE ${url.host}',
      '--proxy-server=${settings.server}',
      '--proxy-bypass-list=${_bypassRules(settings.bypass)}',
    ];
  }

  /// Chromium exempts loopback from every proxy unless told otherwise, so a
  /// proxy on localhost would be skipped without a word. `<-loopback>`
  /// un-exempts it; a caller whose bypass list already mentions loopback has
  /// said what they want and is left alone. Upstream does the same.
  static String _bypassRules(String? bypass) {
    const loopback = [
      'localhost',
      '127.0.0.1',
      '::1',
      '[::]',
      '[::1]',
      '<loopback>',
      '<-loopback>',
    ];
    final hosts = (bypass ?? '')
        .split(',')
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .map((t) => t.startsWith('.') ? '*$t' : t)
        .toList();
    if (!hosts.any(loopback.contains)) hosts.insert(0, '<-loopback>');
    return hosts.join(';');
  }

  /// Launch a local Chromium browser instance.
  ///
  /// With [CoreLaunchOptions.userDataDir] set this is a persistent launch:
  /// the browser comes up on that on-disk profile and its default context is
  /// the one the caller gets.
  Future<CrBrowser> launch(
      {CoreLaunchOptions options = const CoreLaunchOptions()}) async {
    options.validateFor(name);
    final execPath = options.resolveExecutable(name, _registry.executablePath);
    final profile = options.resolveUserDataDir(name);
    final chromeArgs = defaultArgs(options, profile.dir);

    var transport = await launchBrowserWithInspectorPipe(
      execPath,
      chromeArgs,
      environment: options.processEnvironment,
      handleSIGINT: options.handleSIGINT,
      handleSIGTERM: options.handleSIGTERM,
      handleSIGHUP: options.handleSIGHUP,
    );
    if (options.slowMo != null) {
      transport = SlowMoTransport(transport, options.slowMo!);
    }

    try {
      final connection = CRConnection(transport);
      final connect = CrBrowser.connect(
        connection,
        null,
        profile.temporary.isEmpty ? null : profile.temporary.first,
        persistentContext: options.isPersistent,
        contextOptions: options.persistentContextOptions,
        downloadsPath: options.downloadsPath,
        tracesDir: options.tracesDir,
      );
      return await (options.timeout == Duration.zero
          ? connect
          : connect.timeout(options.timeout,
              onTimeout: () => throw PlaywrightException(
                  'Timed out after ${options.timeout.inMilliseconds}ms waiting '
                  'for Chromium to start.')));
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

  /// Connect to a Chromium that is already running with a CDP endpoint.
  ///
  /// [endpointURL] is either the browser's WebSocket debugger URL
  /// (`ws://…/devtools/browser/…`) or the HTTP address the browser was
  /// started on with `--remote-debugging-port` (`http://localhost:9222`), in
  /// which case `/json/version` is read to find the WebSocket URL.
  ///
  /// This is Chromium-only, and not an oversight of this port: it speaks the
  /// Chrome DevTools Protocol, which Firefox (Juggler) and WebKit (the
  /// WebKit inspector protocol) do not implement. Upstream's `BrowserType`
  /// answers the same call with "CDP connections are only supported by
  /// Chromium".
  Future<CrBrowser> connectOverCDP(
    String endpointURL, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 30),
    Duration? slowMo,
  }) async {
    final wsEndpoint = await _resolveCdpEndpoint(endpointURL, headers, timeout);

    ConnectionTransport transport =
        await WebSocketTransport.connect(wsEndpoint, headers: headers);
    if (slowMo != null) transport = SlowMoTransport(transport, slowMo);

    try {
      final connection = CRConnection(transport);
      // The browser is not ours: it has a default context full of pages the
      // user already opened, and closing it must leave it running.
      return await CrBrowser.connect(
        connection,
        null,
        null,
        persistentContext: true,
        ownsBrowserProcess: false,
      ).timeout(timeout,
          onTimeout: () => throw PlaywrightException(
              'Timed out after ${timeout.inMilliseconds}ms connecting to '
              '$endpointURL.'));
    } catch (e) {
      await transport.close();
      rethrow;
    }
  }

  /// Turns an HTTP endpoint into the browser's WebSocket debugger URL, the
  /// way `connectOverCDP('http://localhost:9222')` is expected to work.
  Future<String> _resolveCdpEndpoint(String endpointURL,
      Map<String, String>? headers, Duration timeout) async {
    final uri = Uri.parse(endpointURL);
    if (uri.scheme == 'ws' || uri.scheme == 'wss') return endpointURL;
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw PlaywrightException(
          'Unsupported endpoint URL scheme "${uri.scheme}". Use ws://, wss://, '
          'http:// or https://.');
    }

    final versionUrl = uri.replace(
      path: uri.path.endsWith('/')
          ? '${uri.path}json/version/'
          : '${uri.path}/json/version/',
    );
    final client = HttpClient();
    try {
      final request = await client.getUrl(versionUrl).timeout(timeout);
      headers?.forEach(request.headers.set);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) {
        throw PlaywrightException(
            'GET $versionUrl returned ${response.statusCode}. Is Chromium '
            'running with --remote-debugging-port?');
      }
      final body = await response
          .transform(const SystemEncoding().decoder)
          .join()
          .timeout(timeout);
      final json = jsonDecode(body);
      if (json is! Map || json['webSocketDebuggerUrl'] is! String) {
        throw PlaywrightException(
            '$versionUrl did not report a webSocketDebuggerUrl.');
      }
      return json['webSocketDebuggerUrl'] as String;
    } on PlaywrightException {
      rethrow;
    } catch (e) {
      throw PlaywrightException('Failed to read $versionUrl: $e');
    } finally {
      client.close(force: true);
    }
  }
}
