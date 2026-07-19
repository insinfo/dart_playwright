import 'package:playwright_core/src/server/core_page.dart';
import 'package:playwright_core/src/server/chromium/cr_element_handle.dart';
import 'locator.dart';
import 'js_handle.dart';
import 'element_handle.dart';
import 'route.dart';
import 'package:playwright_core/src/accessibility.dart';

/// A single tab or page in a browser.
abstract class Page {
  /// Navigate to a URL.
  Future<void> goto(String url);

  /// Get the page title.
  Future<String> title();

  /// Take a screenshot of the page.
  Future<List<int>> screenshot({String? path});

  /// Get the accessibility snapshot.
  Future<AccessibilitySnapshot> accessibilitySnapshot();

  /// Intercept network requests.
  Future<void> route(String urlPattern, void Function(Route) handler);

  /// Evaluate JavaScript expression in the page.
  Future<dynamic> evaluate(String expression);

  /// Evaluate JavaScript expression and return a handle.
  Future<JSHandle> evaluateHandle(String expression);

  /// Create a locator for an element.
  Locator locator(String selector);

  /// Click an element using trusted protocol-level input events.
  Future<void> click(String selector);

  /// Fill an element with text using trusted protocol-level input events.
  Future<void> fill(String selector, String text);

  /// Get the full HTML content of the page.
  Future<String> content();

  /// Get the current URL of the page.
  Future<String> url();

  /// Wait until [selector] matches an element, or throw on timeout.
  Future<void> waitForSelector(String selector,
      {Duration timeout = const Duration(seconds: 30)});

  /// Close the page.
  Future<void> close();
}

class PageImpl implements Page {
  final CorePage _corePage;

  PageImpl(this._corePage);

  @override
  Future<void> goto(String url) => _corePage.goto(url);

  @override
  Future<String> title() => _corePage.title();

  @override
  Future<List<int>> screenshot({String? path}) => _corePage.screenshot(path: path);

  @override
  Future<AccessibilitySnapshot> accessibilitySnapshot() => _corePage.accessibilitySnapshot();

  @override
  Future<void> route(String urlPattern, void Function(Route) handler) async {
    await _corePage.route(urlPattern, (crRoute) {
      final routeImpl = RouteImpl(crRoute);
      handler(routeImpl);
    });
  }

  @override
  Future<dynamic> evaluate(String expression) => _corePage.evaluate(expression);

  @override
  Future<JSHandle> evaluateHandle(String expression) async {
    final handle = await _corePage.evaluateHandle(expression);
    // Cast appropriately based on the handle type returned
    if (handle is CrElementHandle) {
      return ElementHandleImpl(handle);
    }
    return JSHandleImpl(handle);
  }

  @override
  Locator locator(String selector) {
    return LocatorImpl(this, selector);
  }

  @override
  Future<void> click(String selector) => _corePage.click(selector);

  @override
  Future<void> fill(String selector, String text) =>
      _corePage.fill(selector, text);

  @override
  Future<String> content() async {
    final result =
        await _corePage.evaluate('() => document.documentElement.outerHTML');
    return result.toString();
  }

  @override
  Future<String> url() async {
    final result = await _corePage.evaluate('() => window.location.href');
    return result.toString();
  }

  @override
  Future<void> waitForSelector(String selector,
      {Duration timeout = const Duration(seconds: 30)}) {
    return LocatorImpl(this, selector).waitFor(timeout: timeout);
  }

  @override
  Future<void> close() => _corePage.close();
}
