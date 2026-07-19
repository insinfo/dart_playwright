import 'package:playwright_core/src/server/core_browser.dart';
import 'browser_context.dart';

/// A browser instance.
abstract class Browser {
  /// Create a new browser context.
  Future<BrowserContext> newContext();
  
  /// Close the browser.
  Future<void> close();

  /// Browser version.
  Future<String> version();
}

class BrowserImpl implements Browser {
  final CoreBrowser _coreBrowser;

  BrowserImpl(this._coreBrowser);

  @override
  Future<BrowserContext> newContext() async {
    // In full implementation, this uses Browser.createBrowserContext CDP
    // For this prototype, we'll just connect directly to default target
    final targetId = (await _coreBrowser.connection.send('Target.createTarget', {
      'url': 'about:blank',
    }))['targetId'];

    final sessionId = (await _coreBrowser.connection.send('Target.attachToTarget', {
      'targetId': targetId,
      'flatten': true,
    }))['sessionId'];

    final session = _coreBrowser.connection.createSession(sessionId, 'page');
    return BrowserContextImpl(session);
  }

  @override
  Future<void> close() => _coreBrowser.close();

  @override
  Future<String> version() => _coreBrowser.version();
}
