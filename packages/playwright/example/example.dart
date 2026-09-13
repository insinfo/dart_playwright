// Run with:
//   dart run playwright install chromium
//   dart run example/example.dart
import 'package:playwright/playwright.dart';

Future<void> main() async {
  final playwright = await Playwright.create();
  final browser = await playwright.chromium.launch(headless: true);

  try {
    final context = await browser.newContext(
      viewport: (width: 1280, height: 720),
    );
    final page = await context.newPage();

    // Events are streams. A dialog nobody subscribes to is dismissed
    // automatically, so an unexpected alert() cannot hang the script.
    page.onConsole.listen((message) {
      print('console [${message.type()}] ${message.text()}');
    });
    page.onPageError.listen((error) {
      print('uncaught ${error.name}: ${error.message}');
    });

    await page.goto('https://example.com');
    print('title: ${await page.title()}');
    print('heading: ${await page.getByRole('heading').textContent()}');

    // Start the wait before the action that triggers it, or the popup may
    // open before anybody is listening.
    final popup = page.waitForPopup(timeout: const Duration(seconds: 10));
    await page.getByRole('link', name: 'More information').click();
    print('popup: ${await (await popup).title()}');
  } finally {
    await browser.close();
  }
}
