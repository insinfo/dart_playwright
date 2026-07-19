import 'package:playwright_core/playwright_core.dart';
import 'browser_type.dart';

/// The entry point for Playwright Dart.
class Playwright {
  final BrowserRegistry _registry;
  late final BrowserType chromium;
  late final BrowserType firefox;
  late final BrowserType webkit;

  Playwright._(this._registry) {
    // We instantiate wrappers around the core engine types
    chromium = BrowserTypeImpl('chromium', _registry);
    firefox = BrowserTypeImpl('firefox', _registry);
    webkit = BrowserTypeImpl('webkit', _registry);
  }

  /// Create a Playwright instance.
  static Future<Playwright> create() async {
    final registry = BrowserRegistry();
    return Playwright._(registry);
  }
}
