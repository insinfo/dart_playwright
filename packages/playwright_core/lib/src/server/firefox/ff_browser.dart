import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:playwright_protocol/playwright_protocol.dart';
import '../core_browser.dart';
import '../core_page.dart';
import 'ff_connection.dart';
import 'ff_page.dart';

class FfBrowser extends EventEmitter implements CoreBrowser {
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
    return _downloadsDirectory ??= Directory.systemTemp
        .createTempSync('playwright-dart-downloads')
        .path;
  }

  FfBrowserContext? _contextFor(String? browserContextId) {
    for (final context in _contexts) {
      if (context.browserContextId == browserContextId) return context;
    }
    return null;
  }

  Future<void> init() async {
    await session.send('Browser.enable', {
      'attachToDefaultContext': false,
    });
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
    // Juggler applies all of these context-wide, before any page exists,
    // which is why Firefox needs no per-page emulation at all.
    if (options.userAgent != null) {
      await session.send('Browser.setUserAgentOverride', {
        'browserContextId': browserContextId,
        'userAgent': options.userAgent,
      });
    }
    final viewport = options.viewport;
    if (viewport != null) {
      await session.send('Browser.setDefaultViewport', {
        'browserContextId': browserContextId,
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
        'browserContextId': browserContextId,
        'locale': options.locale,
      });
    }
    if (options.timezoneId != null) {
      await session.send('Browser.setTimezoneOverride', {
        'browserContextId': browserContextId,
        'timezoneId': options.timezoneId,
      });
    }
    if (options.colorScheme != null) {
      await session.send('Browser.setColorScheme', {
        'browserContextId': browserContextId,
        'colorScheme': options.colorScheme,
      });
    }
    if (options.reducedMotion != null) {
      await session.send('Browser.setReducedMotion', {
        'browserContextId': browserContextId,
        'reducedMotion': options.reducedMotion,
      });
    }
    if (options.forcedColors != null) {
      await session.send('Browser.setForcedColors', {
        'browserContextId': browserContextId,
        'forcedColors': options.forcedColors,
      });
    }
    if (options.hasTouch) {
      await session.send('Browser.setTouchOverride', {
        'browserContextId': browserContextId,
        'hasTouch': true,
      });
    }
    if (options.offline) {
      await session.send('Browser.setOnlineOverride', {
        'browserContextId': browserContextId,
        'override': 'offline',
      });
    }
    final headers = options.extraHTTPHeaders;
    if (headers != null && headers.isNotEmpty) {
      // Juggler takes an array of {name, value}, not an object.
      await session.send('Browser.setExtraHTTPHeaders', {
        'browserContextId': browserContextId,
        'headers': [
          for (final entry in headers.entries)
            {'name': entry.key, 'value': entry.value},
        ],
      });
    }
    final credentials = options.httpCredentials;
    if (credentials != null) {
      await session.send('Browser.setHTTPCredentials', {
        'browserContextId': browserContextId,
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
        'browserContextId': browserContextId,
        'geolocation': {
          'latitude': geolocation.latitude,
          'longitude': geolocation.longitude,
          'accuracy': geolocation.accuracy,
        },
      });
    }
    final permissions = options.permissions;
    if (permissions != null && permissions.isNotEmpty) {
      await session.send('Browser.grantPermissions', {
        'browserContextId': browserContextId,
        // Upstream keys permissions by origin and defaults to '*', meaning
        // every origin; an empty string matches nothing.
        'origin': '*',
        'permissions':
            CorePermissions.resolve(CorePermissions.firefox, permissions),
      });
    }
    final context = FfBrowserContext(this, browserContextId, options);
    _contexts.add(context);
    await session.send('Browser.setDownloadOptions', {
      'browserContextId': browserContextId,
      'downloadOptions': {
        'behavior': options.acceptDownloads ? 'saveToDisk' : 'cancel',
        if (options.acceptDownloads)
          'downloadsDir': context.downloadsDirectory,
      },
    });
    return context;
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

/// An isolated Firefox (Juggler) browser context.
class FfBrowserContext extends EventEmitter
    with BrowserContextStorage
    implements CoreBrowserContext {
  final FfBrowser browser;
  final String browserContextId;
  final CoreContextOptions options;
  bool _closed = false;

  FfBrowserContext(this.browser, this.browserContextId, this.options);

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
        'browserContextId': browserContextId,
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
      'browserContextId': browserContextId,
    });
    return (result['cookies'] as List).cast<Map<String, dynamic>>();
  }

  @override
  Future<void> addCookies(List<Map<String, dynamic>> cookies) async {
    await browser.connection.send('Browser.setCookies', {
      'browserContextId': browserContextId,
      'cookies': rewriteCookies(cookies),
    });
  }

  @override
  Future<void> clearCookies() async {
    await browser.session.send('Browser.clearCookies', {
      'browserContextId': browserContextId,
    });
  }

  @override
  Future<Map<String, dynamic>> storageState() => collectStorageState();

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
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
