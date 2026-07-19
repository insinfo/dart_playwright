import 'package:playwright_core/src/server/core_browser.dart';
import 'page.dart';

/// An isolated browser context.
abstract class BrowserContext {
  /// Create a new page in this context.
  Future<Page> newPage();

  /// Close the context and every page that belongs to it.
  Future<void> close();
}

class BrowserContextImpl implements BrowserContext {
  final CoreBrowserContext _coreContext;

  BrowserContextImpl(this._coreContext);

  @override
  Future<Page> newPage() async {
    final corePage = await _coreContext.newPage();
    return PageImpl(corePage);
  }

  @override
  Future<void> close() => _coreContext.close();
}
