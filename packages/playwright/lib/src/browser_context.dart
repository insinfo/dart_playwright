import 'package:playwright_core/src/server/core_browser.dart';
import 'page.dart';

/// An isolated browser context.
abstract class BrowserContext {
  /// Create a new page in this context.
  Future<Page> newPage();

  /// Close the context.
  Future<void> close();
}

class BrowserContextImpl implements BrowserContext {
  final CoreBrowser _browser;

  BrowserContextImpl(this._browser, [dynamic session]);

  @override
  Future<Page> newPage() async {
    // Agora utilizamos o próprio CoreBrowser que já conhece o tipo de motor (Cr, Ff, Wk)
    // para retornar a sua própria subclasse de CorePage.
    final corePage = await _browser.newPage();
    return PageImpl(corePage);
  }

  @override
  Future<void> close() async {
    // Requires Target.closeTarget
  }
}
