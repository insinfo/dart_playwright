/// Playwright fixtures and retrying assertions on top of `package:test`.
///
/// ```dart
/// import 'package:playwright_test/playwright_test.dart';
///
/// void main() {
///   playwrightGroup('example.com', () {
///     playwrightTest('the heading is there', (t) async {
///       await t.page.goto('https://example.com');
///       await expectLocator(t.page.getByRole('heading')).toBeVisible();
///     });
///   });
/// }
/// ```
///
/// This is a layer over `package:test`, not a runner of its own: `dart test`
/// still runs the tests, reports them and filters them. What this adds is the
/// browser lifecycle, a fresh page per test, retrying assertions, and a
/// screenshot when a test fails.
library playwright_test;

export 'package:playwright/playwright.dart';
export 'package:test/test.dart';

export 'src/assertions.dart';
export 'src/fixture.dart';
export 'src/fixtures.dart';
export 'src/source_maps.dart';
export 'src/step.dart' show attach, step;
export 'src/storage_state.dart' show StorageState, applyStorageState;
export 'src/web_server.dart';
