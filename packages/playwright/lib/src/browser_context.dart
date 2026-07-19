import 'package:playwright_core/src/server/core_browser.dart';
import 'page.dart';

/// An isolated browser context.
abstract class BrowserContext {
  /// Create a new page in this context.
  Future<Page> newPage();

  /// Return all cookies in this context (optionally filtered by [urls]).
  Future<List<Map<String, dynamic>>> cookies([List<String>? urls]);

  /// Add the given cookies to this context.
  Future<void> addCookies(List<Map<String, dynamic>> cookies);

  /// Remove all cookies from this context.
  Future<void> clearCookies();

  /// Capture cookies and per-origin localStorage as a portable snapshot.
  Future<Map<String, dynamic>> storageState();

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
  Future<List<Map<String, dynamic>>> cookies([List<String>? urls]) =>
      _coreContext.cookies(urls);

  @override
  Future<void> addCookies(List<Map<String, dynamic>> cookies) =>
      _coreContext.addCookies(cookies);

  @override
  Future<void> clearCookies() => _coreContext.clearCookies();

  @override
  Future<Map<String, dynamic>> storageState() => _coreContext.storageState();

  @override
  Future<void> close() => _coreContext.close();
}
