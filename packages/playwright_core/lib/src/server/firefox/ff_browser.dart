import 'dart:async';
import 'package:playwright_protocol/playwright_protocol.dart';
import '../core_browser.dart';
import '../core_page.dart';
import 'ff_connection.dart';
import 'ff_page.dart';

class FfBrowser extends EventEmitter implements CoreBrowser {
  final FfConnection connection;
  late final FfSession session;
  
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
  Future<CoreBrowserContext> createBrowserContext() async {
    final result = await session.send('Browser.createBrowserContext', {
      'removeOnDetach': true,
    });
    return FfBrowserContext(this, result['browserContextId'] as String);
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
      await session
          .send('Browser.close')
          .timeout(const Duration(seconds: 3));
    } catch (_) {}
    await connection.transport.close();
  }
}

/// An isolated Firefox (Juggler) browser context.
class FfBrowserContext implements CoreBrowserContext {
  final FfBrowser browser;
  final String browserContextId;
  bool _closed = false;

  FfBrowserContext(this.browser, this.browserContextId);

  @override
  Future<CorePage> newPage() async {
    if (_closed) throw PlaywrightException('Context closed');
    final result = await browser.session.send('Browser.newPage', {
      'browserContextId': browserContextId,
    });
    return browser.waitForPage(result['targetId'] as String);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // Removing the context closes its pages (removeOnDetach: true semantics
    // apply to disconnect; removal is explicit here).
    await browser.session.send('Browser.removeBrowserContext', {
      'browserContextId': browserContextId,
    });
  }
}
