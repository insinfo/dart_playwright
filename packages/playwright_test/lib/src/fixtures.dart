import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:playwright/playwright.dart';
import 'package:test/test.dart';

/// What a Playwright test body receives.
///
/// The page is fresh for every test, in a context of its own, so nothing
/// leaks between tests: no cookies, no storage, no leftover tabs.
class PlaywrightFixtures {
  /// Which engine this run is using: `chromium`, `firefox` or `webkit`.
  final String browserName;

  /// The browser, shared by every test in this file for this engine.
  final Browser browser;

  /// A context created for this test alone.
  final BrowserContext context;

  /// A page created for this test alone.
  final Page page;

  PlaywrightFixtures({
    required this.browserName,
    required this.browser,
    required this.context,
    required this.page,
  });
}

/// Options for [playwrightTest] and [playwrightGroup].
class PlaywrightTestOptions {
  /// Engines to run the body on. Defaults to Chromium only, because running
  /// three browsers per test is a choice, not a default.
  final List<String> browsers;

  final bool headless;
  final ({int width, int height})? viewport;
  final String? locale;
  final String? timezoneId;
  final String? colorScheme;
  final bool hasTouch;
  final String? baseURL;

  /// Where a failure screenshot is written. Null turns the capture off.
  final String? artifactsPath;

  const PlaywrightTestOptions({
    this.browsers = const ['chromium'],
    this.headless = true,
    this.viewport,
    this.locale,
    this.timezoneId,
    this.colorScheme,
    this.hasTouch = false,
    this.baseURL,
    this.artifactsPath = 'test-results',
  });
}

/// One browser per (file, engine), launched on first use and closed by the
/// test runner's tearDownAll.
class _BrowserPool {
  static final Map<String, Future<Browser>> _browsers = {};
  static Playwright? _playwright;

  static Future<Browser> get(String name, {required bool headless}) {
    final key = '$name:$headless';
    return _browsers.putIfAbsent(key, () async {
      final playwright = _playwright ??= await Playwright.create();
      final type = switch (name) {
        'firefox' => playwright.firefox,
        'webkit' => playwright.webkit,
        'chromium' => playwright.chromium,
        _ => throw ArgumentError.value(
            name, 'browser', 'Expected chromium, firefox or webkit'),
      };
      return type.launch(headless: headless);
    });
  }

  static Future<void> closeAll() async {
    final pending = _browsers.values.toList();
    _browsers.clear();
    for (final browser in pending) {
      await (await browser).close();
    }
  }
}

/// Registers a test that runs once per browser in [options].
///
/// ```dart
/// void main() {
///   playwrightTest('the heading is there', (t) async {
///     await t.page.goto('https://example.com');
///     await expectLocator(t.page.getByRole('heading')).toBeVisible();
///   }, options: const PlaywrightTestOptions(
///        browsers: ['chromium', 'firefox', 'webkit']));
/// }
/// ```
///
/// The browser is shared across the tests in the file; the context and the
/// page are not. When a test fails and `artifactsPath` is set, a screenshot
/// is written next to the failure and its path is added to the error, which
/// is usually the fastest way to see what the page actually looked like.
void playwrightTest(
  String description,
  Future<void> Function(PlaywrightFixtures fixtures) body, {
  PlaywrightTestOptions options = const PlaywrightTestOptions(),
  Timeout? timeout,
  Object? skip,
  Object? tags,
}) {
  for (final browserName in options.browsers) {
    test(
      options.browsers.length == 1
          ? description
          : '$description [$browserName]',
      () => _runOne(description, browserName, options, body),
      timeout: timeout ?? const Timeout(Duration(minutes: 2)),
      skip: skip,
      tags: tags,
    );
  }
}

/// Groups Playwright tests and closes every browser they launched.
///
/// Call this once per test file, around the `playwrightTest` calls, or the
/// browsers stay open until the process exits.
void playwrightGroup(String description, void Function() body) {
  group(description, () {
    tearDownAll(_BrowserPool.closeAll);
    body();
  });
}

Future<void> _runOne(
  String description,
  String browserName,
  PlaywrightTestOptions options,
  Future<void> Function(PlaywrightFixtures) body,
) async {
  final browser =
      await _BrowserPool.get(browserName, headless: options.headless);
  final context = await browser.newContext(
    viewport: options.viewport,
    locale: options.locale,
    timezoneId: options.timezoneId,
    colorScheme: options.colorScheme,
    hasTouch: options.hasTouch,
  );
  final page = await context.newPage();
  final fixtures = PlaywrightFixtures(
    browserName: browserName,
    browser: browser,
    context: context,
    page: page,
  );

  try {
    await body(fixtures);
  } catch (error) {
    final shot = await _captureFailure(
        page, description, browserName, options.artifactsPath);
    if (shot == null) rethrow;
    // Keep the original error first: the screenshot is a hint, not the
    // failure.
    throw StateError('$error\n\nScreenshot of the failure: $shot');
  } finally {
    await context.close();
  }
}

/// Writes a screenshot of the failing page, returning its path.
///
/// Returns null when capture is off or when the page is in no state to be
/// photographed — a crashed or closed page cannot be, and failing here would
/// replace the real failure with a less useful one.
Future<String?> _captureFailure(
    Page page, String description, String browserName, String? artifactsPath) async {
  if (artifactsPath == null) return null;
  try {
    final safe = description
        .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '')
        .toLowerCase();
    final file = p.join(artifactsPath, '$safe-$browserName.png');
    await Directory(p.dirname(file)).create(recursive: true);
    await page.screenshot(path: file, fullPage: true);
    return file;
  } catch (_) {
    return null;
  }
}
