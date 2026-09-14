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
    await session.waitForTarget(timeout: const Duration(seconds: 30));

    final page = WkPage(session, browserContextId: contextId);
    await page.initialize();
    await context.applyContextOptions(session);

    final openerId = params['openerId'] as String?;
    _pagesByProxy[pageProxyId] = page;
    context.registerPage(page,
        opener: openerId == null ? null : _pagesByProxy[openerId]);

    final completer = _pageCompleters.remove(pageProxyId);
    if (completer != null && !completer.isCompleted) completer.complete(page);
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
    return _downloadsDirectory ??= Directory.systemTemp
        .createTempSync('playwright-dart-downloads')
        .path;
  }

  WkBrowserContext? _contextFor(String? browserContextId) {
    for (final context in _contexts) {
      if (context.browserContextId == browserContextId) return context;
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

  Future<void> init() async {
    await connection.send('Playwright.enable', {});
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
    final result = await connection.send('Playwright.createContext', {});
    final context =
        WkBrowserContext(this, result['browserContextId'] as String, options);
    // WebKit only applies permissions when a page exists, so validate the
    // names now: otherwise an unknown one would surface much later, from a
    // call that has nothing to do with permissions.
    final requested = options.permissions;
    if (requested != null && requested.isNotEmpty) {
      CorePermissions.resolve(CorePermissions.webkit, requested);
    }
    _contexts.add(context);
    if (options.locale != null) {
      await connection.send('Playwright.setLanguages', {
        'browserContextId': context.browserContextId,
        'languages': [options.locale],
      });
    }
    final geolocation = options.geolocation;
    if (geolocation != null) {
      await connection.send('Playwright.setGeolocationOverride', {
        'browserContextId': context.browserContextId,
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
      'browserContextId': context.browserContextId,
      if (options.acceptDownloads) 'downloadPath': context.downloadsDirectory,
    });
    return context;
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
  }
}

/// An isolated WebKit browser context.
class WkBrowserContext extends EventEmitter
    with BrowserContextStorage
    implements CoreBrowserContext {
  final WkBrowser browser;
  final String browserContextId;
  final CoreContextOptions options;
  bool _closed = false;

  WkBrowserContext(this.browser, this.browserContextId, this.options);

  /// Where this context's downloads land.
  late final String downloadsDirectory =
      options.downloadsPath ?? browser.defaultDownloadsDirectory();

  @override
  bool get isClosed => _closed;

  @override
  Future<CorePage> newPage() async {
    if (_closed) throw PlaywrightException('Context closed');
    final pageResult = await browser.connection.send('Playwright.createPage', {
      'browserContextId': browserContextId,
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
      'browserContextId': browserContextId,
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
      'browserContextId': browserContextId,
      'cookies': cc,
    });
  }

  @override
  Future<void> clearCookies() async {
    await browser.connection.send('Playwright.deleteAllCookies', {
      'browserContextId': browserContextId,
    });
  }

  @override
  Future<Map<String, dynamic>> storageState() => collectStorageState();

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // Deleting the context closes all pages that belong to it.
    await browser.connection.send('Playwright.deleteContext', {
      'browserContextId': browserContextId,
    });
    trackedPages.clear();
    browser._contexts.remove(this);
    notifyClosed();
  }
}
