import 'package:playwright_core/src/server/core_browser.dart';
import 'browser_context.dart';

/// A browser instance.
abstract class Browser {
  /// Create a new browser context.
  ///
  /// [viewport] sets the page viewport size and [userAgent] overrides the
  /// browser user agent for every page in the context.
  Future<BrowserContext> newContext(
      {({int width, int height})? viewport, String? userAgent});

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
  Future<BrowserContext> newContext(
      {({int width, int height})? viewport, String? userAgent}) async {
    final coreContext = await _coreBrowser.createBrowserContext(
        options:
            CoreContextOptions(viewport: viewport, userAgent: userAgent));
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
