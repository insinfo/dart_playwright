import 'dart:async';
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

  WkBrowser(this.connection) {
    connection.on('closed', () => _onClosed());
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
  Future<CoreBrowserContext> createBrowserContext() async {
    final result = await connection.send('Playwright.createContext', {});
    final context =
        WkBrowserContext(this, result['browserContextId'] as String);
    _contexts.add(context);
    return context;
  }

  void _onClosed() {
    if (_isClosed) return;
    _isClosed = true;
    _contexts.clear();
    emit('disconnected');
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
  bool get isClosed => _closed;

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
  }
}
