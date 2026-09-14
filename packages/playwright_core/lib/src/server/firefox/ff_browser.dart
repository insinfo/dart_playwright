import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:playwright_protocol/playwright_protocol.dart';
import '../core_browser.dart';
import '../core_page.dart';
import '../launch_options.dart';
import 'ff_connection.dart';
import 'ff_page.dart';

class FfBrowser extends EventEmitter implements CoreBrowser {
  @override
  String get name => 'firefox';

  final FfConnection connection;
  late final FfSession session;
  final _contexts = <FfBrowserContext>[];
  bool _isClosed = false;

  FfBrowser(this.connection) {
    session = connection.rootSession;

    // In Juggler every page - the ones we ask for and the ones the page opens
    // itself - arrives as Browser.attachedToTarget. That single entry point is
    // what makes popups observable.
    session.on('Browser.attachedToTarget', _onAttachedToTarget);
    session.on('Browser.detachedFromTarget', (params) {
      _pagesByTarget.remove(params['targetId'] as String?);
      final sessionId = params['sessionId'] as String?;
      if (sessionId != null) connection.closeSession(sessionId);
    });
    session.on('Browser.downloadCreated', _onDownloadCreated);
    session.on('Browser.downloadFinished', _onDownloadFinished);
    connection.on('closed', () => _onClosed());
  }

  final _pendingPages = <String, Completer<FfPage>>{};
  final _pagesByTarget = <String, FfPage>{};

  void _onAttachedToTarget(Map<String, dynamic> params) {
    final targetInfo = params['targetInfo'] as Map<String, dynamic>?;
    if (targetInfo == null || targetInfo['type'] != 'page') return;
    final targetId = targetInfo['targetId'] as String;
    if (_pagesByTarget.containsKey(targetId)) return;
    final newSession = connection.createSession(params['sessionId'] as String);
    final page = FfPage(newSession);
    _pagesByTarget[targetId] = page;
    // Uma falha aqui nao pode ser engolida: sem completar o completer com o
    // erro, `newPage()` espera para sempre em vez de saber que a pagina nao
    // nasceu. E manipulador de evento, entao ninguem aguarda este future.
    _adoptPage(page, targetId, targetInfo).catchError((Object error,
        StackTrace stack) {
      final completer = _pendingPages.remove(targetId);
      if (completer != null && !completer.isCompleted) {
        completer.completeError(error, stack);
      }
    });
  }

  Future<void> _adoptPage(FfPage page, String targetId,
      Map<String, dynamic> targetInfo) async {
    // Page.ready is Juggler's equivalent of "the session is usable"; nothing
    // else can be sent to the page before it.
    await page.initialize();
    final contextId = targetInfo['browserContextId'] as String?;
    final context = _contextFor(contextId);
    if (context != null) {
      // The page must carry the context's init scripts and bindings before
      // anyone can navigate it.
      page.browserContext = context;
      await context.initializePage(page);
      final openerId = targetInfo['openerId'] as String?;
      context.registerPage(page,
          opener: openerId == null ? null : _pagesByTarget[openerId]);
    }
    final completer = _pendingPages.remove(targetId);
    if (completer != null && !completer.isCompleted) completer.complete(page);
  }

  void _onDownloadCreated(Map<String, dynamic> params) {
    final uuid = params['uuid'] as String?;
    if (uuid == null) return;
    final context = _contextFor(params['browserContextId'] as String?);
    if (context == null) return;
    final page = _pagesByTarget[params['pageTargetId'] as String?];
    context.registerDownload(
      CoreDownload(
        uuid: uuid,
        url: params['url'] as String? ?? '',
        downloadPath: p.join(context.downloadsDirectory, uuid),
        // Juggler is the only engine that names the file up front.
        suggestedFilename: params['suggestedFileName'] as String?,
        cancel: () async {
          await session.send('Browser.cancelDownload', {'uuid': uuid});
        },
      ),
      page: page,
    );
  }

  void _onDownloadFinished(Map<String, dynamic> params) {
    final uuid = params['uuid'] as String?;
    if (uuid == null) return;
    for (final context in _contexts) {
      final download = context.downloads[uuid];
      if (download == null) continue;
      download.markFinished(params['canceled'] == true
          ? 'canceled'
          : params['error'] as String?);
      return;
    }
  }

  String? _downloadsDirectory;

  /// A temporary directory for this browser's downloads.
  String defaultDownloadsDirectory() {
    final launchPath = launchDownloadsPath;
    if (launchPath != null) {
      Directory(launchPath).createSync(recursive: true);
      return launchPath;
    }
    return _downloadsDirectory ??= Directory.systemTemp
        .createTempSync('playwright-dart-downloads')
        .path;
  }

  /// The context for [browserContextId], falling back to the profile's own
  /// context.
  ///
  /// The fallback is not a nicety: the engines report a real id for the
  /// default context, not a missing one, so a persistent context would never
  /// recognise its own pages by id alone and every `newPage()` there would
  /// time out waiting for a session that was quietly discarded. Upstream
  /// takes the same fallback. For a non-persistent browser there is no
  /// default context, so an unknown id still means "not ours".
  FfBrowserContext? _contextFor(String? browserContextId) {
    for (final context in _contexts) {
      if (context.browserContextId == browserContextId) return context;
    }
    return _defaultContextOrNull;
  }

  FfBrowserContext? get _defaultContextOrNull {
    for (final context in _contexts) {
      if (context.browserContextId == null) return context;
    }
    return null;
  }

  /// Where this browser's downloads land when a context does not say.
  String? launchDownloadsPath;

  /// Where trace artifacts are written.
  String? tracesDir;

  /// The throwaway profile to delete when the browser closes, if any.
  String? tempUserDataDir;

  /// The default context of a persistent launch, or null for a plain launch.
  FfBrowserContext? get defaultContext => _defaultContextOrNull;

  /// [persistentContext] attaches to Firefox's own default profile context —
  /// the one the `-profile` directory belongs to — instead of ignoring it.
  Future<void> init(
      {bool persistentContext = false,
      CoreContextOptions contextOptions = const CoreContextOptions(),
      CoreProxySettings? proxy}) async {
    await session.send('Browser.enable', {
      'attachToDefaultContext': persistentContext,
    });
    if (proxy != null) {
      await session.send(
          'Browser.setBrowserProxy', jugglerProxyOptions(proxy.normalized()));
    }
    if (persistentContext) {
      final context = FfBrowserContext(this, null, contextOptions);
      _contexts.add(context);
      await applyContextOptions(null, contextOptions);
      await applyDownloadOptions(context);
    }
  }

  @override
  Future<String> version() async {
    final result = await session.send('Browser.getInfo');
    return result['userAgent'] ?? 'Firefox Juggler';
  }

  @override
  List<CoreBrowserContext> get contexts => List.unmodifiable(_contexts);

  @override
  bool get isConnected => !_isClosed;

  @override
  Future<CoreBrowserContext> createBrowserContext(
      {CoreContextOptions options = const CoreContextOptions()}) async {
    final result = await session.send('Browser.createBrowserContext', {
      'removeOnDetach': true,
    });
    final browserContextId = result['browserContextId'] as String;
    await applyContextOptions(browserContextId, options);
    final context = FfBrowserContext(this, browserContextId, options);
    _contexts.add(context);
    await applyDownloadOptions(context);
    return context;
  }

  /// Juggler takes the proxy apart rather than as a URL, and names SOCKS5
  /// `socks`.
  static Map<String, dynamic> jugglerProxyOptions(CoreProxySettings proxy) {
    final url = Uri.parse(proxy.server);
    final type = switch (url.scheme) {
      'socks5' => 'socks',
      'https' => 'https',
      _ => 'http',
    };
    var port = url.port;
    if (port == 0) port = url.scheme == 'https' ? 443 : 80;
    return <String, dynamic>{
      'type': type,
      'host': url.host,
      'port': port,
      'bypass': proxy.bypass == null
          ? <String>[]
          : proxy.bypass!.split(',').map((d) => d.trim()).toList(),
      if (proxy.username != null) 'username': proxy.username,
      if (proxy.password != null) 'password': proxy.password,
    };
  }

  /// Applies [options] to the Juggler context [browserContextId], or to the
  /// profile's default context when that is null.
  ///
  /// Juggler applies all of these context-wide, before any page exists,
  /// which is why Firefox needs no per-page emulation at all. The default
  /// context is addressed by leaving `browserContextId` off the message.
  Future<void> applyContextOptions(
      String? browserContextId, CoreContextOptions options) async {
    final ctx = <String, dynamic>{
      if (browserContextId != null) 'browserContextId': browserContextId,
    };
    // Juggler applies all of these context-wide, before any page exists,
    // which is why Firefox needs no per-page emulation at all.
    if (options.userAgent != null) {
      await session.send('Browser.setUserAgentOverride', {
        ...ctx,
        'userAgent': options.userAgent,
      });
    }
    final viewport = options.viewport;
    if (viewport != null) {
      await session.send('Browser.setDefaultViewport', {
        ...ctx,
        'viewport': {
          'viewportSize': {
            'width': viewport.width,
            'height': viewport.height,
          },
          'deviceScaleFactor': options.deviceScaleFactor ?? 1,
          'isMobile': options.isMobile,
        },
      });
    }
    if (options.locale != null) {
      await session.send('Browser.setLocaleOverride', {
        ...ctx,
        'locale': options.locale,
      });
    }
    if (options.timezoneId != null) {
      await session.send('Browser.setTimezoneOverride', {
        ...ctx,
        'timezoneId': options.timezoneId,
      });
    }
    if (options.colorScheme != null) {
      await session.send('Browser.setColorScheme', {
        ...ctx,
        'colorScheme': options.colorScheme,
      });
    }
    if (options.reducedMotion != null) {
      await session.send('Browser.setReducedMotion', {
        ...ctx,
        'reducedMotion': options.reducedMotion,
      });
    }
    if (options.forcedColors != null) {
      await session.send('Browser.setForcedColors', {
        ...ctx,
        'forcedColors': options.forcedColors,
      });
    }
    if (options.hasTouch) {
      await session.send('Browser.setTouchOverride', {
        ...ctx,
        'hasTouch': true,
      });
    }
    if (options.offline) {
      await session.send('Browser.setOnlineOverride', {
        ...ctx,
        'override': 'offline',
      });
    }
    final headers = options.extraHTTPHeaders;
    if (headers != null && headers.isNotEmpty) {
      // Juggler takes an array of {name, value}, not an object.
      await session.send('Browser.setExtraHTTPHeaders', {
        ...ctx,
        'headers': [
          for (final entry in headers.entries)
            {'name': entry.key, 'value': entry.value},
        ],
      });
    }
    final credentials = options.httpCredentials;
    if (credentials != null) {
      await session.send('Browser.setHTTPCredentials', {
        ...ctx,
        'credentials': {
          'username': credentials.username,
          'password': credentials.password,
          if (credentials.origin != null) 'origin': credentials.origin,
        },
      });
    }
    final geolocation = options.geolocation;
    if (geolocation != null) {
      await session.send('Browser.setGeolocationOverride', {
        ...ctx,
        'geolocation': {
          'latitude': geolocation.latitude,
          'longitude': geolocation.longitude,
          'accuracy': geolocation.accuracy,
        },
      });
    }
    final proxy = options.proxy?.normalized();
    if (proxy != null && browserContextId != null) {
      await session.send('Browser.setContextProxy', {
        ...ctx,
        ...jugglerProxyOptions(proxy),
      });
    }
    final permissions = options.permissions;
    if (permissions != null && permissions.isNotEmpty) {
      await session.send('Browser.grantPermissions', {
        ...ctx,
        // Upstream keys permissions by origin and defaults to '*', meaning
        // every origin; an empty string matches nothing.
        'origin': '*',
        'permissions':
            CorePermissions.resolve(CorePermissions.firefox, permissions),
      });
    }
  }

  /// Points the context's downloads at its directory, or refuses them.
  Future<void> applyDownloadOptions(FfBrowserContext context) async {
    await session.send('Browser.setDownloadOptions', {
      if (context.browserContextId != null)
        'browserContextId': context.browserContextId,
      'downloadOptions': {
        'behavior': context.options.acceptDownloads ? 'saveToDisk' : 'cancel',
        if (context.options.acceptDownloads)
          'downloadsDir': context.downloadsDirectory,
      },
    });
  }

  /// Waits for the page attached to [targetId] (created via Browser.newPage)
  /// to finish being adopted by its context.
  Future<FfPage> waitForPage(String targetId) {
    final completer =
        _pendingPages.putIfAbsent(targetId, () => Completer<FfPage>());
    return completer.future
        .timeout(const Duration(seconds: 30), onTimeout: () {
      _pendingPages.remove(targetId);
      throw PlaywrightException('Timeout waiting for Firefox page session');
    });
  }

  @override
  Future<void> close() async {
    // Ask Firefox to shut down gracefully; fall back to killing the process
    // if it does not comply in time.
    try {
      await session.send('Browser.close').timeout(const Duration(seconds: 3));
    } catch (_) {}
    await connection.transport.close();
    // `close()` returning has to mean disconnected. The transport announces
    // its closure through a stream, so _onClosed would otherwise land a tick
    // later and `isConnected()` would still say true right after the await.
    // _onClosed is idempotent, so the stream event that follows is a no-op.
    _onClosed();
  }

  void _cleanupTempProfile() {
    final dir = tempUserDataDir;
    if (dir == null) return;
    tempUserDataDir = null;
    try {
      Directory(dir).deleteSync(recursive: true);
    } catch (_) {}
  }

  void _onClosed() {
    if (_isClosed) return;
    _isClosed = true;
    final downloads = _downloadsDirectory;
    if (downloads != null) {
      try {
        Directory(downloads).deleteSync(recursive: true);
      } catch (_) {}
    }
    for (final context in _contexts.toList()) {
      context.notifyClosed();
    }
    _contexts.clear();
    emit('disconnected', true);
    disposeStreams();
    _cleanupTempProfile();
  }
}

/// An isolated Firefox (Juggler) browser context.
class FfBrowserContext extends EventEmitter
    with BrowserContextStorage, CoreBrowserContextBindings
    implements CoreBrowserContext {
  final FfBrowser browser;

  /// Null for the default context of a persistent launch: Juggler addresses
  /// that one by leaving `browserContextId` off the message entirely.
  final String? browserContextId;
  final CoreContextOptions options;
  bool _closed = false;

  FfBrowserContext(this.browser, this.browserContextId, this.options);

  @override
  String get engineName => 'firefox';

  /// Whether this is the profile's own context rather than one we created.
  bool get isDefault => browserContextId == null;

  /// Where this context's downloads land.
  late final String downloadsDirectory =
      options.downloadsPath ?? browser.defaultDownloadsDirectory();

  @override
  bool get isClosed => _closed;

  @override
  Future<CorePage> newPage() async {
    if (_closed) throw PlaywrightException('Context closed');
    final Map<String, dynamic> result;
    try {
      result = await browser.session.send('Browser.newPage', {
        if (browserContextId != null) 'browserContextId': browserContextId,
      });
    } catch (error) {
      // Juggler validates the timezone when it builds the page, not when the
      // override is set, so this is where a bad one surfaces.
      if ('$error'.contains('Failed to override timezone')) {
        throw PlaywrightException(
            'Invalid timezone ID: ${options.timezoneId}');
      }
      rethrow;
    }
    // The page itself is built and registered by the attachedToTarget
    // handler, the same path a popup takes.
    return browser.waitForPage(result['targetId'] as String);
  }

  @override
  Future<List<Map<String, dynamic>>> cookies([List<String>? urls]) async {
    final result = await browser.session.send('Browser.getCookies', {
      if (browserContextId != null) 'browserContextId': browserContextId,
    });
    return (result['cookies'] as List).cast<Map<String, dynamic>>();
  }

  @override
  Future<void> addCookies(List<Map<String, dynamic>> cookies) async {
    await browser.connection.send('Browser.setCookies', {
      if (browserContextId != null) 'browserContextId': browserContextId,
      'cookies': rewriteCookies(cookies),
    });
  }

  @override
  Future<void> clearCookies() async {
    await browser.session.send('Browser.clearCookies', {
      if (browserContextId != null) 'browserContextId': browserContextId,
    });
  }

  @override
  Future<Map<String, dynamic>> storageState() => collectStorageState();

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // Stopping a screencast needs the page that is being filmed; do it while
    // the pages are still there, which is the order upstream's
    // `BrowserContext.close` uses too.
    await finishVideos();
    if (isDefault) {
      // The default context belongs to the profile, not to us: there is no
      // context to remove, and closing it means closing the browser — which
      // is what upstream does for a persistent context too.
      trackedPages.clear();
      browser._contexts.remove(this);
      notifyClosed();
      await browser.close();
      return;
    }
    // Removing the context closes its pages (removeOnDetach: true semantics
    // apply to disconnect; removal is explicit here).
    await browser.session.send('Browser.removeBrowserContext', {
      'browserContextId': browserContextId,
    });
    trackedPages.clear();
    browser._contexts.remove(this);
    notifyClosed();
  }
}
