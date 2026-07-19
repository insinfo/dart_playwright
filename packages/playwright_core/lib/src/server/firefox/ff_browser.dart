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
      print('FfBrowser caught Browser.attachedToTarget: \$params');
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
  Future<CorePage> newPage() async {
    final contextResult = await session.send('Browser.createBrowserContext', {
      'removeOnDetach': true
    });
    final browserContextId = contextResult['browserContextId'] as String;

    // Call Browser.newPage
    final result = await session.send('Browser.newPage', {
      'browserContextId': browserContextId
    });
    final targetId = result['targetId'] as String;
    
    if (_attachedPages.containsKey(targetId)) {
      final page = _attachedPages.remove(targetId)!;
      await page.initialize();
      return page;
    }

    final completer = Completer<FfPage>();
    _pendingPages[targetId] = completer;
    
    // Wait for Browser.attachedToTarget
    final page = await completer.future.timeout(Duration(seconds: 10), onTimeout: () {
      _pendingPages.remove(targetId);
      throw PlaywrightException('Timeout waiting for Firefox page session');
    });
    
    await page.initialize();
    return page;
  }

  @override
  Future<void> close() async {
    connection.close();
  }
}
