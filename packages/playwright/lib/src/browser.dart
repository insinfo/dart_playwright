import 'package:playwright_core/src/server/core_browser.dart';
import 'browser_context.dart';

/// A browser instance.
abstract class Browser {
  /// Create a new browser context.
  Future<BrowserContext> newContext();

  /// Currently open browser contexts.
  List<BrowserContext> contexts();

  /// Whether the browser connection is still open.
  bool isConnected();

  /// Event emitted when the browser disconnects.
  Stream<void> get onDisconnected;

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
    final coreContext = await _coreBrowser.createBrowserContext();
    return BrowserContextImpl(coreContext);
  }

  @override
  List<BrowserContext> contexts() => _coreBrowser.contexts
      .map((context) => BrowserContextImpl(context))
      .toList();

  @override
  bool isConnected() => _coreBrowser.isConnected;

  @override
  Stream<void> get onDisconnected => _coreBrowser.stream<void>('disconnected');

  @override
  Future<void> close() => _coreBrowser.close();

  @override
  Future<String> version() => _coreBrowser.version();
}
