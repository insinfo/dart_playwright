import 'package:playwright_core/src/server/chromium/cr_page.dart';
import 'locator.dart';

/// A single tab or page in a browser.
abstract class Page {
  /// Navigate to a URL.
  Future<void> goto(String url);

  /// Get the page title.
  Future<String> title();

  /// Evaluate JavaScript expression in the page.
  Future<dynamic> evaluate(String expression);

  /// Create a locator for an element.
  Locator locator(String selector);

  /// Close the page.
  Future<void> close();
}

class PageImpl implements Page {
  final CrPage _crPage;

  PageImpl(this._crPage);

  @override
  Future<void> goto(String url) => _crPage.goto(url);

  @override
  Future<String> title() => _crPage.title();

  @override
  Future<dynamic> evaluate(String expression) => _crPage.evaluate(expression);

  @override
  Locator locator(String selector) {
    return LocatorImpl(this, selector);
  }

  @override
  Future<void> close() => _crPage.close();
}
