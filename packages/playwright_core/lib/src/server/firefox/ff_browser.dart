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

    // In Juggler, new pages emit Browser.attachedToTarget
    session.on('Browser.attachedToTarget', (params) {
      final targetInfo = params['targetInfo'];
      if (targetInfo['type'] == 'page') {
        final sessionId = params['sessionId'] as String;
        final targetId = targetInfo['targetId'] as String;
        final newSession = connection.createSession(sessionId);
        final page = FfPage(newSession);
        if (_pendingPages.containsKey(targetId)) {
          _pendingPages[targetId]?.complete(page);
          _pendingPages.remove(targetId);
        } else {
          _attachedPages[targetId] = page;
        }
      }
    });
    connection.on('closed', () => _onClosed());
  }

  final _pendingPages = <String, Completer<FfPage>>{};
  final _attachedPages = <String, FfPage>{};

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

  /// Waits for the page session attached to [targetId] (created via
  /// Browser.newPage) and initializes it.
  Future<FfPage> waitForPage(String targetId) async {
    if (_attachedPages.containsKey(targetId)) {
      final page = _attachedPages.remove(targetId)!;
      await page.initialize();
      return page;
    }

    final completer = Completer<FfPage>();
    _pendingPages[targetId] = completer;

    final page =
        await completer.future.timeout(Duration(seconds: 10), onTimeout: () {
      _pendingPages.remove(targetId);
      throw PlaywrightException('Timeout waiting for Firefox page session');
    });

    await page.initialize();
    return page;
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
    _contexts.clear();
    emit('disconnected');
  }
}

/// An isolated Firefox (Juggler) browser context.
class FfBrowserContext
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
    final page = await browser.waitForPage(result['targetId'] as String);
    trackedPages.add(page);
    return page;
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
  }
}
