// Proof that a trace recorded by this port opens in the official viewer.
//
// The viewer is not reimplemented here and never should be: the whole point of
// writing upstream's format is that upstream's viewer reads it. This script
// drives the real one and reports what it rendered, so the claim "it opens" is
// checked instead of asserted.
//
// Run it like this:
//
//   # 1. record a trace
//   dart run packages/playwright/example/tracing_example.dart chromium
//
//   # 2. serve it with the official viewer (this does not need the npm
//   #    package installed in the project; `npx` fetches it)
//   npx playwright@1.63.0 show-trace --host 127.0.0.1 --port 9299 <trace.zip>
//
//   # 3. open that URL with this port's own Chromium and read the UI back.
//   #    `show-trace --port` answers `/` with a 302 to the real viewer URL;
//   #    pass the Location header value here.
//   dart run tool/open_trace_in_viewer.dart "<url from the 302>" [shot.png]
//
// `show-trace --port` also opens the system browser unless CLAUDECODE or
// COPILOT_CLI is set in the environment.
import 'dart:io';

import 'package:playwright/playwright.dart';

Future<void> main(List<String> args) async {
  final url = args.first;
  final shot = args.length > 1 ? args[1] : null;

  final playwright = await Playwright.create();
  final browser = await playwright.chromium.launch();
  final context =
      await browser.newContext(viewport: (width: 1400, height: 900));
  final page = await context.newPage();

  final errors = <String>[];
  page.onPageError.listen((e) => errors.add('pageerror: ${e.message}'));
  page.onConsole.listen((m) {
    if (m.type == 'error') errors.add('console.error: ${m.text}');
  });

  await page.goto(url);
  // The viewer unzips the trace inside a service worker, so the action list
  // appears well after load.
  await page.waitForFunction(
      "() => document.querySelectorAll('.action-title').length > 0",
      timeout: const Duration(seconds: 30));

  final titles = await page.evaluate(
      "() => [...document.querySelectorAll('.action-title')].map(e => e.innerText.replace(/\\s+/g, ' ').trim())");
  stdout.writeln('ACTIONS:');
  for (final t in titles as List) {
    stdout.writeln('  - $t');
  }

  // Metadata pane: browser name, title, duration.
  final meta = await page
      .evaluate("() => document.body.innerText.includes('Trace probe')");
  stdout.writeln('TITLE_IN_UI: $meta');

  // Network tab.
  await page.evaluate(
      "() => [...document.querySelectorAll('.tabbed-pane-tab-label')].find(e => e.textContent === 'Network')?.click()");
  await page.waitForTimeout(const Duration(milliseconds: 1500));
  final network = await page.evaluate(
      "() => [...document.querySelectorAll('.network-request-title-url')].map(e => e.textContent)");
  stdout.writeln('NETWORK: $network');

  // Console tab.
  await page.evaluate(
      "() => [...document.querySelectorAll('.tabbed-pane-tab-label')].find(e => e.textContent === 'Console')?.click()");
  await page.waitForTimeout(const Duration(milliseconds: 800));
  final console = await page.evaluate(
      "() => document.querySelector('.console-tab')?.innerText?.replace(/\\s+/g, ' ').trim().slice(0, 300)");
  stdout.writeln('CONSOLE: $console');

  // Source tab.
  await page.evaluate(
      "() => [...document.querySelectorAll('.tabbed-pane-tab-label')].find(e => e.textContent === 'Source')?.click()");
  await page.waitForTimeout(const Duration(milliseconds: 800));
  final source = await page.evaluate(
      "() => document.querySelector('.source-tab')?.innerText?.replace(/\\s+/g, ' ').trim().slice(0, 200)");
  stdout.writeln('SOURCE: $source');

  if (shot != null) {
    await page.screenshot(path: shot, fullPage: false);
    stdout.writeln('SCREENSHOT: $shot');
  }
  stdout.writeln('ERRORS: ${errors.isEmpty ? 'none' : errors.join(' | ')}');

  await browser.close();
}
