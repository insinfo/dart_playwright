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
    await connection.transport.close();
  }

  @override
  Future<String> version() async {
    // The WebKit inspector protocol has no Browser domain; the closest
    // equivalent is the user agent of a live page. Report the engine name.
    return 'WebKit';
  }

  @override
  Future<CorePage> newPage() async {
    final contextResult = await connection.send('Playwright.createContext', {});
    final contextId = contextResult['browserContextId'] as String;

    final pageResult = await connection.send('Playwright.createPage', {
      'browserContextId': contextId,
    });
    final pageProxyId = pageResult['pageProxyId'] as String;

    // The session was created eagerly when Playwright.pageProxyCreated
    // arrived (which happens before the createPage response).
    final session = connection.pageProxySession(pageProxyId);
    await session.waitForTarget(timeout: Duration(seconds: 10));

    final page = WkPage(session, browserContextId: contextId);
    await page.initialize();
    return page;
  }
}
