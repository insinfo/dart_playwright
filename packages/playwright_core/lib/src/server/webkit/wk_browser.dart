import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:playwright_protocol/playwright_protocol.dart';
import '../core_browser.dart';
import '../core_page.dart';
import 'wk_connection.dart';
import 'wk_page.dart';

class WkBrowser extends EventEmitter implements CoreBrowser {
  @override
  String get name => 'webkit';

  @override
  final WkConnection connection;
  final _contexts = <WkBrowserContext>[];
  bool _isClosed = false;

  /// Pages by pageProxy id, so a popup can find the page that opened it.
  final _pagesByProxy = <String, WkPage>{};

  /// One completer per pageProxy id, completed once the page is initialized,
  /// emulated and registered on its context.
  final _pageCompleters = <String, Completer<WkPage>>{};

  WkBrowser(this.connection) {
    connection.on('closed', () => _onClosed());
    // Every page - requested or opened by the page itself - is announced here
    // before its session carries any traffic.
    connection.on('Playwright.pageProxyCreated', _onPageProxyCreated);
    connection.on('Playwright.downloadCreated', _onDownloadCreated);
    connection.on('Playwright.downloadFilenameSuggested', (params) {
      final uuid = params['uuid'] as String?;
      final filename = params['suggestedFilename'] as String?;
      if (uuid == null || filename == null) return;
      for (final context in _contexts) {
        context.downloads[uuid]?.filenameSuggested(filename);
      }
    });
    connection.on('Playwright.downloadFinished', _onDownloadFinished);
    connection.on('Playwright.pageProxyDestroyed', (params) {
      _pagesByProxy.remove(params['pageProxyId'] as String?);
    });
  }

  void _onPageProxyCreated(Map<String, dynamic> params) {
    final pageProxyId = params['pageProxyId'] as String?;
    if (pageProxyId == null || _pagesByProxy.containsKey(pageProxyId)) return;
    _adoptPageProxy(pageProxyId, params).catchError((Object _) {});
  }

  Future<void> _adoptPageProxy(
      String pageProxyId, Map<String, dynamic> params) async {
    final contextId = params['browserContextId'] as String?;
    final context = _contextFor(contextId);
    if (context == null) return;

    // The session was created eagerly by the connection when the
    // pageProxyCreated message arrived, so no event is lost here.
    final session = connection.pageProxySession(pageProxyId);
    try {
      await session.waitForTarget(timeout: const Duration(seconds: 30));

      final page = WkPage(session, browserContextId: contextId);
      await page.initialize();
      await context.applyContextOptions(session);
      // The page must carry the context's init scripts and bindings before
      // anyone can navigate it.
      page.browserContext = context;
      await context.initializePage(page);

      final openerId = params['openerId'] as String?;
      _pagesByProxy[pageProxyId] = page;
      context.registerPage(page,
          opener: openerId == null ? null : _pagesByProxy[openerId]);

      final completer = _pageCompleters.remove(pageProxyId);
      if (completer != null && !completer.isCompleted) completer.complete(page);
    } catch (error, stack) {
      // Mesma razao do Chromium: ninguem aguarda o future de um manipulador de
      // evento, entao uma falha na inicializacao deixaria `newPage()` esperando
      // para sempre em vez de receber o erro.
      final completer = _pageCompleters.remove(pageProxyId);
      if (completer != null && !completer.isCompleted) {
        completer.completeError(error, stack);
      } else {
        rethrow;
      }
    }
  }

  void _onDownloadCreated(Map<String, dynamic> params) {
    final uuid = params['uuid'] as String?;
    if (uuid == null) return;
    // Unlike Chromium and Firefox, WebKit does not name the context here;
    // only the pageProxy that started the download, so the context has to
    // come from the page.
    final page = _pagesByProxy[params['pageProxyId'] as String?];
    final context = page?.browserContext as WkBrowserContext? ??
        (_contexts.length == 1 ? _contexts.first : null);
    if (context == null) return;
    // WebKit is the one engine that does not know the filename yet; it
    // arrives later as Playwright.downloadFilenameSuggested.
    context.registerDownload(
      CoreDownload(
        uuid: uuid,
        url: params['url'] as String? ?? '',
        downloadPath: p.join(context.downloadsDirectory, uuid),
        cancel: () async {
          await connection.send('Playwright.cancelDownload', {'uuid': uuid});
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
      final error = params['error'] as String?;
      download.markFinished(error != null && error.isNotEmpty ? error : null);
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
  WkBrowserContext? _contextFor(String? browserContextId) {
    for (final context in _contexts) {
      if (context.browserContextId == browserContextId) return context;
    }
    return _defaultContextOrNull;
  }

  WkBrowserContext? get _defaultContextOrNull {
    for (final context in _contexts) {
      if (context.browserContextId == null) return context;
    }
    return null;
  }

  /// The page for [pageProxyId], waiting for it to be fully adopted.
  Future<WkPage> pageForProxy(String pageProxyId,
      {Duration timeout = const Duration(seconds: 30)}) {
    final existing = _pagesByProxy[pageProxyId];
    if (existing != null) return Future.value(existing);
    final completer =
        _pageCompleters.putIfAbsent(pageProxyId, () => Completer<WkPage>());
    return completer.future.timeout(timeout, onTimeout: () {
      _pageCompleters.remove(pageProxyId);
      throw PlaywrightException(
          'Timeout waiting for the WebKit page of proxy $pageProxyId');
    });
  }

  /// Where this browser's downloads land when a context does not say.
  String? launchDownloadsPath;

  /// Where trace artifacts are written.
  String? tracesDir;

  /// The throwaway profile to delete when the browser closes, if any.
  String? tempUserDataDir;

  /// The default context of a persistent launch, or null for a plain launch.
  WkBrowserContext? get defaultContext => _defaultContextOrNull;

  /// [persistentContext] adopts WebKit's own default context — the one the
  /// `--user-data-dir` profile belongs to — as the context we hand back.
  Future<void> init(
      {bool persistentContext = false,
      CoreContextOptions contextOptions =
          const CoreContextOptions()}) async {
    await connection.send('Playwright.enable', {});
    if (persistentContext) {
      final context = WkBrowserContext(this, null, contextOptions);
      _contexts.add(context);
      await applyContextOptions(context);
    }
  }

  @override
  Future<void> close() async {
    // Ask WebKit to shut down gracefully; fall back to killing the process
    // if it does not comply in time.
    try {
      await connection
          .send('Playwright.close', {}).timeout(const Duration(seconds: 3));
    } catch (_) {}
    await connection.transport.close();
    // `close()` returning has to mean disconnected. The transport announces
    // its closure through a stream, so _onClosed would otherwise land a tick
    // later and `isConnected()` would still say true right after the await.
    // _onClosed is idempotent, so the stream event that follows is a no-op.
    _onClosed();
  }

  @override
  Future<String> version() async {
    // The WebKit inspector protocol has no Browser domain; the closest
    // equivalent is the user agent of a live page. Report the engine name.
    return 'WebKit';
  }

  @override
  List<CoreBrowserContext> get contexts => List.unmodifiable(_contexts);

  @override
  bool get isConnected => !_isClosed;

  @override
  Future<CoreBrowserContext> createBrowserContext(
      {CoreContextOptions options = const CoreContextOptions()}) async {
    final proxy = options.proxy?.normalized();
    // Known limitation of the Windows build: it routes through curl, whose
    // proxy behaves as if it were process-wide, so creating a context
    // without a proxy after one with a proxy stops the earlier context from
    // using it. Ordering is the only workaround; there is no protocol
    // command to re-apply a context's proxy afterwards.
    final result = await connection.send('Playwright.createContext', {
      if (proxy != null)
        // The Windows build resolves SOCKS host names only with socks5h.
        'proxyServer': Platform.isWindows
            ? proxy.server.replaceFirst('socks5://', 'socks5h://')
            : proxy.server,
      if (proxy?.bypass != null) 'proxyBypassList': proxy!.bypass,
    });
    final context =
        WkBrowserContext(this, result['browserContextId'] as String, options);
    _contexts.add(context);
    await applyContextOptions(context);
    return context;
  }

  /// Applies [context]'s options to it. The default context of a persistent
  /// launch carries no id, and WebKit addresses that one by leaving
  /// `browserContextId` off the message.
  Future<void> applyContextOptions(WkBrowserContext context) async {
    final options = context.options;
    final ctx = <String, dynamic>{
      if (context.browserContextId != null)
        'browserContextId': context.browserContextId,
    };
    // WebKit only applies permissions when a page exists, so validate the
    // names now: otherwise an unknown one would surface much later, from a
    // call that has nothing to do with permissions.
    final requested = options.permissions;
    if (requested != null && requested.isNotEmpty) {
      CorePermissions.resolve(CorePermissions.webkit, requested);
    }
    if (options.locale != null) {
      await connection.send('Playwright.setLanguages', {
        ...ctx,
        'languages': [options.locale],
      });
    }
    final geolocation = options.geolocation;
    if (geolocation != null) {
      await connection.send('Playwright.setGeolocationOverride', {
        ...ctx,
        'geolocation': {
          // WebKit is the only engine that demands a timestamp.
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'latitude': geolocation.latitude,
          'longitude': geolocation.longitude,
          'accuracy': geolocation.accuracy,
        },
      });
    }
    await connection.send('Playwright.setDownloadBehavior', {
      'behavior': options.acceptDownloads ? 'allow' : 'deny',
      ...ctx,
      if (options.acceptDownloads) 'downloadPath': context.downloadsDirectory,
    });
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
    final profile = tempUserDataDir;
    if (profile != null) {
      tempUserDataDir = null;
      try {
        Directory(profile).deleteSync(recursive: true);
      } catch (_) {}
    }
  }
}

/// An isolated WebKit browser context.
class WkBrowserContext extends EventEmitter
    with BrowserContextStorage, CoreBrowserContextBindings
    implements CoreBrowserContext {
  final WkBrowser browser;

  /// Null for the default context of a persistent launch: WebKit addresses
  /// that one by leaving `browserContextId` off the message entirely.
  final String? browserContextId;
  final CoreContextOptions options;
  bool _closed = false;

  WkBrowserContext(this.browser, this.browserContextId, this.options);

  @override
  String get engineName => 'webkit';

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
    final pageResult = await browser.connection.send('Playwright.createPage', {
      if (browserContextId != null) 'browserContextId': browserContextId,
    });
    // Playwright.pageProxyCreated already arrived (it precedes the createPage
    // response); the handler builds and registers the page, exactly as it
    // does for a popup.
    return browser.pageForProxy(pageResult['pageProxyId'] as String);
  }

  /// Applies the context's emulation to a page of this context.
  ///
  /// WebKit splits this across both protocol layers: device metrics are a
  /// pageProxy command, the user agent a target one.
  Future<void> applyContextOptions(WkPageProxySession session) async {
    // WebKit spreads these across three layers: the browser session for
    // languages and geolocation, the pageProxy for device metrics, auth and
    // permissions, and the page target for everything else. Sending a command
    // to the wrong one fails with "'<cmd>' wasn't found".
    final viewport = options.viewport;
    if (viewport != null) {
      await session.send('Emulation.setDeviceMetricsOverride', {
        'width': viewport.width,
        'height': viewport.height,
        // WebKit calls the mobile flag fixedLayout.
        'fixedLayout': options.isMobile,
        'deviceScaleFactor': options.deviceScaleFactor ?? 1,
      });
      if (options.isMobile) {
        await session.send('Emulation.setOrientationOverride',
            {'angle': viewport.width > viewport.height ? 90 : 0});
      }
    }
    if (options.userAgent != null) {
      await session.sendToTarget('Page.overrideUserAgent', {
        'value': options.userAgent,
      });
    }
    if (options.timezoneId != null) {
      try {
        await session
            .sendToTarget('Page.setTimeZone', {'timeZone': options.timezoneId});
      } catch (_) {
        throw PlaywrightException(
            'Invalid timezone ID: ${options.timezoneId}');
      }
    }
    if (options.colorScheme != null) {
      await session.sendToTarget('Page.overrideUserPreference', {
        'name': 'PrefersColorScheme',
        // WebKit spells the values with a capital.
        if (options.colorScheme != 'no-preference')
          'value': options.colorScheme == 'dark' ? 'Dark' : 'Light',
      });
    }
    if (options.reducedMotion != null) {
      await session.sendToTarget('Page.overrideUserPreference', {
        'name': 'PrefersReducedMotion',
        'value': options.reducedMotion == 'reduce' ? 'Reduce' : 'NoPreference',
      });
    }
    if (options.forcedColors != null) {
      await session.sendToTarget('Page.setForcedColors', {
        'forcedColors': options.forcedColors == 'active' ? 'Active' : 'None',
      });
    }
    await session.sendToTarget(
        'Page.setTouchEmulationEnabled', {'enabled': options.hasTouch});
    if (options.offline) {
      await session
          .sendToTarget('Network.setEmulateOfflineState', {'offline': true});
    }
    // WebKit's Playwright.setLanguages drives navigator.language but not the
    // Accept-Language header, so upstream sends that one itself
    // (wkPage.ts:678). Without this, a context with a locale asks the server
    // in the browser's own language.
    final headers = <String, String>{
      if (options.locale != null) 'Accept-Language': options.locale!,
      ...?options.extraHTTPHeaders,
    };
    if (headers.isNotEmpty) {
      await session
          .sendToTarget('Network.setExtraHTTPHeaders', {'headers': headers});
    }
    final credentials = options.httpCredentials;
    if (credentials != null) {
      await session.send('Emulation.setAuthCredentials', {
        'username': credentials.username,
        'password': credentials.password,
        'origin': credentials.origin ?? '',
      });
    }
    final permissions = options.permissions;
    if (permissions != null && permissions.isNotEmpty) {
      // Permissions are per page in WebKit, so every new page replays them.
      await session.send('Emulation.grantPermissions', {
        'origin': '*',
        'permissions':
            CorePermissions.resolve(CorePermissions.webkit, permissions),
      });
    }
  }

  @override
  Future<List<Map<String, dynamic>>> cookies([List<String>? urls]) async {
    final result = await browser.connection.send('Playwright.getAllCookies', {
      if (browserContextId != null) 'browserContextId': browserContextId,
    });
    final cookies = (result['cookies'] as List).cast<Map<String, dynamic>>();
    for (final c in cookies) {
      if (c.containsKey('expires') && c['expires'] != -1) {
        c['expires'] = (c['expires'] as num) / 1000;
      }
    }
    return cookies;
  }

  @override
  Future<void> addCookies(List<Map<String, dynamic>> cookies) async {
    // WebKit's Playwright.setCookies validator is strict: each cookie must
    // carry only known fields with the right types, and optional fields must
    // be omitted (not null/sentinel) when absent, or it rejects the payload.
    // Mirrors wkBrowser.ts addCookies exactly.
    final cc = rewriteCookies(cookies).map((c) {
      final expires = c['expires'] as num?;
      final cookie = <String, dynamic>{
        'name': c['name'],
        'value': c['value'],
        'domain': c['domain'],
        'path': c['path'] ?? '/',
        'session': expires == null || expires == -1,
      };
      if (expires != null && expires != -1) {
        cookie['expires'] = (expires * 1000).round();
      }
      if (c['httpOnly'] != null) cookie['httpOnly'] = c['httpOnly'];
      if (c['secure'] != null) cookie['secure'] = c['secure'];
      if (c['sameSite'] != null) cookie['sameSite'] = c['sameSite'];
      return cookie;
    }).toList();

    await browser.connection.send('Playwright.setCookies', {
      if (browserContextId != null) 'browserContextId': browserContextId,
      'cookies': cc,
    });
  }

  @override
  Future<void> clearCookies() async {
    await browser.connection.send('Playwright.deleteAllCookies', {
      if (browserContextId != null) 'browserContextId': browserContextId,
    });
  }

  @override
  Future<Map<String, dynamic>> storageState() => collectStorageState();

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (isDefault) {
      // The default context belongs to the profile: there is nothing to
      // delete, and closing it means closing the browser, which is what
      // upstream does for a persistent context too.
      trackedPages.clear();
      browser._contexts.remove(this);
      notifyClosed();
      await browser.close();
      return;
    }
    // Deleting the context closes all pages that belong to it.
    await browser.connection.send('Playwright.deleteContext', {
      'browserContextId': browserContextId,
    });
    trackedPages.clear();
    browser._contexts.remove(this);
    notifyClosed();
  }
}
