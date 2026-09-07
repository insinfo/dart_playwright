import 'package:playwright_core/playwright_core.dart';
import 'package:playwright_core/src/server/chromium/chromium.dart';
import 'package:playwright_core/src/server/firefox/firefox.dart';
import 'package:playwright_core/src/server/webkit/webkit.dart';
import 'browser.dart';

/// Launcher for a specific browser type (chromium, firefox, webkit).
abstract class BrowserType {
  /// The name of the browser.
  String get name;

  /// Launch a local browser instance.
  Future<Browser> launch({
    bool headless = true,
    List<String> args = const [],
    List<String> ignoreDefaultArgs = const [],
    String? executablePath,
    String? userDataDir,
    List<String> extensionPaths = const [],
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
    List<String> ignoreDefaultArgs = const [],
    String? executablePath,
    String? userDataDir,
    List<String> extensionPaths = const [],
  }) async {
    if (name == 'chromium') {
      if (extensionPaths.isNotEmpty && userDataDir == null) {
        throw ArgumentError('Chromium extensions require userDataDir');
      }
      final chromiumArgs = <String>[...args];
      final ignored = <String>[...ignoreDefaultArgs];
      if (extensionPaths.isNotEmpty) {
        ignored.add('--disable-extensions');
        chromiumArgs.add('--enable-extensions');
        chromiumArgs
            .add('--disable-extensions-except=${extensionPaths.join(',')}');
        chromiumArgs.add('--load-extension=${extensionPaths.join(',')}');
      }
      final crType = ChromiumBrowserType(_registry);
      final crBrowser = await crType.launch(
        options: ChromiumLaunchOptions(
          headless: headless,
          args: chromiumArgs,
          ignoreDefaultArgs: ignored,
          executablePath: executablePath,
          userDataDir: userDataDir,
        ),
      );
      return BrowserImpl(crBrowser);
    } else if (name == 'firefox') {
      final ffType = FirefoxBrowserType(_registry);
      if (ignoreDefaultArgs.isNotEmpty ||
          executablePath != null ||
          userDataDir != null ||
          extensionPaths.isNotEmpty) {
        throw ArgumentError(
          'ignoreDefaultArgs, executablePath, userDataDir and extensionPaths '
          'are Chromium-only',
        );
      }
      final ffBrowser = await ffType.launch(headless: headless, args: args);
      return BrowserImpl(ffBrowser);
    } else if (name == 'webkit') {
      final wkType = WebKitBrowserType(_registry);
      if (ignoreDefaultArgs.isNotEmpty ||
          executablePath != null ||
          userDataDir != null ||
          extensionPaths.isNotEmpty) {
        throw ArgumentError(
          'ignoreDefaultArgs, executablePath, userDataDir and extensionPaths '
          'are Chromium-only',
        );
      }
      final wkBrowser = await wkType.launch(headless: headless, args: args);
      return BrowserImpl(wkBrowser);
    }
    throw UnimplementedError('Browser $name is not fully ported yet.');
  }
}
