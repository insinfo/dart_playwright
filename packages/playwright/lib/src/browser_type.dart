import 'package:playwright_core/playwright_core.dart';
import 'package:playwright_core/src/server/chromium/chromium.dart';
import 'browser.dart';

/// Launcher for a specific browser type (chromium, firefox, webkit).
abstract class BrowserType {
  /// The name of the browser.
  String get name;

  /// Launch a local browser instance.
  Future<Browser> launch({
    bool headless = true,
    List<String> args = const [],
  });
}

class BrowserTypeImpl implements BrowserType {
  @override
  final String name;
  final BrowserRegistry _registry;

  BrowserTypeImpl(this.name, this._registry);

  @override
  Future<Browser> launch({
    bool headless = true,
    List<String> args = const [],
  }) async {
    if (name == 'chromium') {
      final crType = ChromiumBrowserType(_registry);
      final crBrowser = await crType.launch(
        options: ChromiumLaunchOptions(
          headless: headless,
          args: args,
        ),
      );
      return BrowserImpl(crBrowser);
    }
    throw UnimplementedError('Browser $name is not fully ported yet.');
  }
}
