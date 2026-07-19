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
    // Passamos o CoreBrowser que agora gerencia as CorePages diretamente
    return BrowserContextImpl(_coreBrowser, null);
  }

  @override
  Future<void> close() => _coreBrowser.close();

  @override
  Future<String> version() => _coreBrowser.version();
}
