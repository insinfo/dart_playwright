import 'dart:async';
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
    _adoptPage(page, targetId, targetInfo).catchError((Object _) {});
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
    // Juggler applies these context-wide, before any page exists.
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
          'deviceScaleFactor': 1,
        },
      });
    }
    final context = FfBrowserContext(this, browserContextId);
    _contexts.add(context);
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
  bool _closed = false;

  FfBrowserContext(this.browser, this.browserContextId);

  @override
  bool get isClosed => _closed;

  @override
  Future<CorePage> newPage() async {
    if (_closed) throw PlaywrightException('Context closed');
    final result = await browser.session.send('Browser.newPage', {
      'browserContextId': browserContextId,
    });
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
