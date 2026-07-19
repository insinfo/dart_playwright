import 'dart:async';
import 'package:playwright_protocol/playwright_protocol.dart';
import '../core_browser.dart';
import '../core_page.dart';
import 'wk_connection.dart';
import 'wk_page.dart';

class WkBrowser extends EventEmitter implements CoreBrowser {
  @override
  final WkConnection connection;

  WkBrowser(this.connection);

  Future<void> init() async {
    await connection.send('Playwright.enable', {});
  }

  @override
  Future<void> close() async {
    // Ask WebKit to shut down gracefully; fall back to killing the process
    // if it does not comply in time.
    try {
      await connection
          .send('Playwright.close', {})
          .timeout(const Duration(seconds: 3));
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
  Future<CoreBrowserContext> createBrowserContext() async {
    final result = await connection.send('Playwright.createContext', {});
    return WkBrowserContext(this, result['browserContextId'] as String);
  }
}

/// An isolated WebKit browser context.
class WkBrowserContext
    with BrowserContextStorage
    implements CoreBrowserContext {
  final WkBrowser browser;
  final String browserContextId;
  bool _closed = false;

  WkBrowserContext(this.browser, this.browserContextId);

  @override
  Future<CorePage> newPage() async {
    if (_closed) throw PlaywrightException('Context closed');
    final connection = browser.connection;

    final pageResult = await connection.send('Playwright.createPage', {
      'browserContextId': browserContextId,
    });
    final pageProxyId = pageResult['pageProxyId'] as String;

    // The session was created eagerly when Playwright.pageProxyCreated
    // arrived (which happens before the createPage response).
    final session = connection.pageProxySession(pageProxyId);
    await session.waitForTarget(timeout: Duration(seconds: 10));

    final page = WkPage(session, browserContextId: browserContextId);
    await page.initialize();
    trackedPages.add(page);
    return page;
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
    final cc = <Map<String, dynamic>>[];
    for (final c in rewriteCookies(cookies)) {
      final copy = Map<String, dynamic>.from(c);
      if (copy.containsKey('expires') && copy['expires'] != -1) {
        copy['expires'] = (copy['expires'] as num) * 1000;
      } else {
        copy['session'] = true;
      }
      cc.add(copy);
    }
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
  }
}
