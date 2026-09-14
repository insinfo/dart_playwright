import 'package:playwright_core/playwright_core.dart';
import 'package:playwright_protocol/playwright_protocol.dart';
import 'package:playwright_core/src/server/core_browser.dart';
import 'package:playwright_core/src/server/chromium/chromium.dart';
import 'package:playwright_core/src/server/firefox/firefox.dart';
import 'package:playwright_core/src/server/launch_options.dart';
import 'package:playwright_core/src/server/webkit/webkit.dart';
import 'browser.dart';
import 'browser_context.dart';

/// Proxy settings for a browser or for a single context.
///
/// `server` is `scheme://host:port` — `http`, `https` and `socks5` — and a
/// bare `host:port` is read as `http://host:port`. `bypass` is a
/// comma-separated list of hosts that skip the proxy.
///
/// The field names are in backticks rather than square brackets because
/// dartdoc cannot resolve a reference to a field of a record type, and the
/// CI `Docs` job fails the build on any unresolved reference.
typedef ProxySettings = ({
  String server,
  String? bypass,
  String? username,
  String? password,
});

/// Launcher for a specific browser type (chromium, firefox, webkit).
abstract class BrowserType {
  /// The name of the browser.
  String get name;

  /// Launch a local browser instance.
  ///
  /// [channel] picks a branded Chromium the machine already has — `chrome`,
  /// `msedge`, `chrome-beta`, `msedge-dev`, … — instead of the bundled
  /// build; it is Chromium-only, as is [chromiumSandbox]. [firefoxUserPrefs]
  /// writes `about:config` preferences and is Firefox-only. Passing one to
  /// the wrong engine throws rather than being ignored.
  ///
  /// [executablePath] overrides the binary entirely. [args] are extra
  /// command-line arguments; [ignoreDefaultArgs] drops individual defaults
  /// and [ignoreAllDefaultArgs] drops all of them.
  ///
  /// [env] replaces the browser process environment, [downloadsPath] and
  /// [tracesDir] say where downloads and traces are written, [timeout]
  /// bounds startup (`Duration.zero` disables it) and [slowMo] pauses before
  /// every protocol command so a headed run can be watched.
  ///
  /// [proxy] routes every context of this browser; a single context can
  /// override it with `newContext(proxy: ...)`.
  ///
  /// [handleSIGINT], [handleSIGTERM] and [handleSIGHUP] decide which
  /// interruptions of this Dart process take the browser down with it. Leave
  /// them on unless you intend the browser to outlive an interrupted run —
  /// turning them off is how processes are orphaned.
  Future<Browser> launch({
    bool headless,
    String? channel,
    List<String> args,
    List<String> ignoreDefaultArgs,
    bool ignoreAllDefaultArgs,
    String? executablePath,
    String? userDataDir,
    List<String> extensionPaths,
    Map<String, String>? env,
    String? downloadsPath,
    String? tracesDir,
    Duration timeout,
    Duration? slowMo,
    bool chromiumSandbox,
    Map<String, dynamic>? firefoxUserPrefs,
    ProxySettings? proxy,
    bool handleSIGINT,
    bool handleSIGTERM,
    bool handleSIGHUP,
  });

  /// Launch a browser on the on-disk profile at [userDataDir] and return its
  /// context directly — there is no [Browser] to create contexts from,
  /// because the profile *is* the context.
  ///
  /// Everything the profile holds survives the run: cookies, localStorage,
  /// history, installed extensions, a logged-in session. That is the point,
  /// and it is also the difference in lifetime: closing the returned context
  /// closes the browser, and the profile directory is the caller's to keep
  /// or delete.
  ///
  /// The context options are the ones [Browser.newContext] takes.
  Future<BrowserContext> launchPersistentContext(
    String userDataDir, {
    bool headless,
    String? channel,
    List<String> args,
    List<String> ignoreDefaultArgs,
    bool ignoreAllDefaultArgs,
    String? executablePath,
    List<String> extensionPaths,
    Map<String, String>? env,
    String? downloadsPath,
    String? tracesDir,
    Duration timeout,
    Duration? slowMo,
    bool chromiumSandbox,
    Map<String, dynamic>? firefoxUserPrefs,
    ProxySettings? proxy,
    bool handleSIGINT,
    bool handleSIGTERM,
    bool handleSIGHUP,
    ({int width, int height})? viewport,
    String? userAgent,
    bool acceptDownloads,
    String? locale,
    String? timezoneId,
    String? colorScheme,
    String? reducedMotion,
    String? forcedColors,
    double? deviceScaleFactor,
    bool isMobile,
    bool hasTouch,
    bool offline,
    Map<String, String>? extraHTTPHeaders,
    ({String username, String password, String? origin})? httpCredentials,
    ({double latitude, double longitude, double accuracy})? geolocation,
    List<String>? permissions,
  });

  /// Attach to a Chromium that is already running with a CDP endpoint.
  ///
  /// [endpointURL] is either the browser's WebSocket debugger URL
  /// (`ws://…/devtools/browser/…`) or the HTTP address it was started on with
  /// `--remote-debugging-port=9222`, in which case `/json/version` is read to
  /// find the WebSocket URL.
  ///
  /// The browser is not ours: [Browser.close] drops the connection and leaves
  /// it running, and its already-open pages show up in the first context.
  ///
  /// **Chromium only.** This speaks the Chrome DevTools Protocol, which is
  /// not a gap in this port but in the other two engines: Firefox speaks
  /// Juggler and WebKit its own inspector protocol, and neither implements
  /// CDP. Calling this on them throws, as it does upstream.
  Future<Browser> connectOverCDP(
    String endpointURL, {
    Map<String, String>? headers,
    Duration timeout,
    Duration? slowMo,
  });
}

class BrowserTypeImpl implements BrowserType {
  @override
  final String name;
  final BrowserRegistry _registry;

  BrowserTypeImpl(this.name, this._registry);

  CoreProxySettings? _proxy(ProxySettings? proxy) => proxy == null
      ? null
      : CoreProxySettings(
          server: proxy.server,
          bypass: proxy.bypass,
          username: proxy.username,
          password: proxy.password,
        );

  CoreLaunchOptions _options({
    required bool headless,
    required String? channel,
    required List<String> args,
    required List<String> ignoreDefaultArgs,
    required bool ignoreAllDefaultArgs,
    required String? executablePath,
    required String? userDataDir,
    required List<String> extensionPaths,
    required Map<String, String>? env,
    required String? downloadsPath,
    required String? tracesDir,
    required Duration timeout,
    required Duration? slowMo,
    required bool chromiumSandbox,
    required Map<String, dynamic>? firefoxUserPrefs,
    required ProxySettings? proxy,
    required bool handleSIGINT,
    required bool handleSIGTERM,
    required bool handleSIGHUP,
    CoreContextOptions persistentContextOptions = const CoreContextOptions(),
  }) {
    var effectiveArgs = args;
    var effectiveIgnored = ignoreDefaultArgs;

    if (extensionPaths.isNotEmpty) {
      if (name != 'chromium') {
        throw ArgumentError.value(extensionPaths, 'extensionPaths',
            'Loading unpacked extensions is a Chromium option; $name has no '
                'equivalent switch');
      }
      if (userDataDir == null) {
        throw ArgumentError('Chromium extensions require userDataDir');
      }
      effectiveArgs = [
        ...args,
        '--enable-extensions',
        '--disable-extensions-except=${extensionPaths.join(',')}',
        '--load-extension=${extensionPaths.join(',')}',
      ];
      effectiveIgnored = [...ignoreDefaultArgs, '--disable-extensions'];
    }

    return CoreLaunchOptions(
      headless: headless,
      channel: channel,
      executablePath: executablePath,
      args: effectiveArgs,
      ignoreDefaultArgs: effectiveIgnored,
      ignoreAllDefaultArgs: ignoreAllDefaultArgs,
      env: env,
      downloadsPath: downloadsPath,
      tracesDir: tracesDir,
      timeout: timeout,
      slowMo: slowMo,
      chromiumSandbox: chromiumSandbox,
      firefoxUserPrefs: firefoxUserPrefs,
      proxy: _proxy(proxy),
      handleSIGINT: handleSIGINT,
      handleSIGTERM: handleSIGTERM,
      handleSIGHUP: handleSIGHUP,
      userDataDir: userDataDir,
      persistentContextOptions: persistentContextOptions,
    );
  }

  Future<CoreBrowser> _launchCore(CoreLaunchOptions options) async {
    switch (name) {
      case 'chromium':
        return ChromiumBrowserType(_registry).launch(options: options);
      case 'firefox':
        return FirefoxBrowserType(_registry).launch(options: options);
      case 'webkit':
        return WebKitBrowserType(_registry).launch(options: options);
    }
    throw UnimplementedError('Browser $name is not fully ported yet.');
  }

  @override
  Future<Browser> launch({
    bool headless = true,
    String? channel,
    List<String> args = const [],
    List<String> ignoreDefaultArgs = const [],
    bool ignoreAllDefaultArgs = false,
    String? executablePath,
    String? userDataDir,
    List<String> extensionPaths = const [],
    Map<String, String>? env,
    String? downloadsPath,
    String? tracesDir,
    Duration timeout = const Duration(seconds: 30),
    Duration? slowMo,
    bool chromiumSandbox = false,
    Map<String, dynamic>? firefoxUserPrefs,
    ProxySettings? proxy,
    bool handleSIGINT = true,
    bool handleSIGTERM = true,
    bool handleSIGHUP = true,
  }) async {
    final options = _options(
      headless: headless,
      channel: channel,
      args: args,
      ignoreDefaultArgs: ignoreDefaultArgs,
      ignoreAllDefaultArgs: ignoreAllDefaultArgs,
      executablePath: executablePath,
      userDataDir: userDataDir,
      extensionPaths: extensionPaths,
      env: env,
      downloadsPath: downloadsPath,
      tracesDir: tracesDir,
      timeout: timeout,
      slowMo: slowMo,
      chromiumSandbox: chromiumSandbox,
      firefoxUserPrefs: firefoxUserPrefs,
      proxy: proxy,
      handleSIGINT: handleSIGINT,
      handleSIGTERM: handleSIGTERM,
      handleSIGHUP: handleSIGHUP,
    );
    return BrowserImpl(await _launchCore(options));
  }

  @override
  Future<BrowserContext> launchPersistentContext(
    String userDataDir, {
    bool headless = true,
    String? channel,
    List<String> args = const [],
    List<String> ignoreDefaultArgs = const [],
    bool ignoreAllDefaultArgs = false,
    String? executablePath,
    List<String> extensionPaths = const [],
    Map<String, String>? env,
    String? downloadsPath,
    String? tracesDir,
    Duration timeout = const Duration(seconds: 30),
    Duration? slowMo,
    bool chromiumSandbox = false,
    Map<String, dynamic>? firefoxUserPrefs,
    ProxySettings? proxy,
    bool handleSIGINT = true,
    bool handleSIGTERM = true,
    bool handleSIGHUP = true,
    ({int width, int height})? viewport,
    String? userAgent,
    bool acceptDownloads = true,
    String? locale,
    String? timezoneId,
    String? colorScheme,
    String? reducedMotion,
    String? forcedColors,
    double? deviceScaleFactor,
    bool isMobile = false,
    bool hasTouch = false,
    bool offline = false,
    Map<String, String>? extraHTTPHeaders,
    ({String username, String password, String? origin})? httpCredentials,
    ({double latitude, double longitude, double accuracy})? geolocation,
    List<String>? permissions,
  }) async {
    if (isMobile && viewport == null) {
      throw ArgumentError('isMobile needs a viewport');
    }
    final contextOptions = CoreContextOptions(
      viewport: viewport,
      userAgent: userAgent,
      acceptDownloads: acceptDownloads,
      downloadsPath: downloadsPath,
      locale: locale,
      timezoneId: timezoneId,
      colorScheme: colorScheme,
      reducedMotion: reducedMotion,
      forcedColors: forcedColors,
      deviceScaleFactor: deviceScaleFactor,
      isMobile: isMobile,
      hasTouch: hasTouch,
      offline: offline,
      extraHTTPHeaders: extraHTTPHeaders,
      httpCredentials: httpCredentials,
      geolocation: geolocation,
      permissions: permissions,
    );

    final options = _options(
      headless: headless,
      channel: channel,
      args: args,
      ignoreDefaultArgs: ignoreDefaultArgs,
      ignoreAllDefaultArgs: ignoreAllDefaultArgs,
      executablePath: executablePath,
      userDataDir: userDataDir,
      extensionPaths: extensionPaths,
      env: env,
      downloadsPath: downloadsPath,
      tracesDir: tracesDir,
      timeout: timeout,
      slowMo: slowMo,
      chromiumSandbox: chromiumSandbox,
      firefoxUserPrefs: firefoxUserPrefs,
      proxy: proxy,
      handleSIGINT: handleSIGINT,
      handleSIGTERM: handleSIGTERM,
      handleSIGHUP: handleSIGHUP,
      persistentContextOptions: contextOptions,
    );

    final browser = await _launchCore(options);
    final context = browser.contexts.isEmpty ? null : browser.contexts.first;
    if (context == null) {
      // The engine came up without its profile context. Nothing usable can
      // come of that, and leaving the browser running would strand it.
      await browser.close();
      throw PlaywrightException(
          '$name started but did not expose its persistent context.');
    }
    return BrowserContextImpl.forCore(context);
  }

  @override
  Future<Browser> connectOverCDP(
    String endpointURL, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 30),
    Duration? slowMo,
  }) async {
    if (name != 'chromium') {
      throw PlaywrightException(
          'connectOverCDP speaks the Chrome DevTools Protocol, which $name '
          'does not implement. CDP connections are Chromium-only.');
    }
    final browser = await ChromiumBrowserType(_registry).connectOverCDP(
      endpointURL,
      headers: headers,
      timeout: timeout,
      slowMo: slowMo,
    );
    return BrowserImpl(browser);
  }
}
