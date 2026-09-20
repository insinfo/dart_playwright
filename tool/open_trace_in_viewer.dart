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

  // The action list is a tree, and the nesting is the whole point of
  // `tracing.group`: a row's depth is how many `.tree-view-indent` spacers the
  // viewer drew before it, and its children only exist in the DOM once the row
  // is expanded. The viewer opens every group collapsed (`autoExpandDepth` is
  // 0 without a filter), so a run that only read the rows would report the
  // groups and none of their contents.
  for (var round = 0; round < 10; round++) {
    final expanded = await page.evaluate('''
      () => {
        const rows = [...document.querySelectorAll('.actions-tree-view [role=treeitem]')]
            .filter(row => row.getAttribute('aria-expanded') === 'false');
        rows.forEach(row => row.querySelector('.codicon-chevron-right')?.click());
        return rows.length;
      }''');
    if (expanded == 0) break;
    await page.waitForTimeout(const Duration(milliseconds: 200));
  }
  final tree = await page.evaluate('''
    () => [...document.querySelectorAll('.actions-tree-view [role=treeitem]')].map(row => {
      const entry = row.querySelector(':scope > .tree-view-entry');
      const title = entry && entry.querySelector('.action-title');
      return {
        depth: entry ? entry.querySelectorAll('.tree-view-indent').length : 0,
        title: title ? title.innerText.replace(/\\s+/g, ' ').trim() : '',
      };
    }).filter(r => r.title)''');
  stdout.writeln('ACTIONS:');
  for (final row in tree as List) {
    final depth = (row as Map)['depth'] as int;
    stdout.writeln('  ${'  ' * depth}- ${row['title']}');
  }

  // Film strip: the lanes only exist when the trace carries screencast
  // frames, and each frame div's background-image is a `file/...` URL the
  // viewer resolved out of the archive. An empty list here means the
  // `screencast-frame` events pointed at resources the viewer could not find.
  final filmStrip = await page.evaluate('''
    () => {
      const frames = [...document.querySelectorAll('.film-strip-frame')];
      return {
        lanes: document.querySelectorAll('.film-strip-lane').length,
        frames: frames.length,
        firstImage: frames.length
            ? getComputedStyle(frames[0]).backgroundImage.slice(0, 120)
            : null,
      };
    }''');
  stdout.writeln('FILMSTRIP: $filmStrip');

  // Pick an action before reading the tabs. The Source tab follows the
  // selection — with nothing selected it has no file to show, which reads
  // exactly like "the trace carries no sources".
  await page.evaluate('''
    () => {
      const entries = [...document.querySelectorAll('.actions-tree-view .tree-view-entry')]
          .filter(e => e.querySelector('.action-title'));
      entries[entries.length - 1]?.click();
    }''');
  await page.waitForTimeout(const Duration(milliseconds: 500));

  // Metadata pane: browser name, title, duration.
  final meta = await page
      .evaluate("() => document.body.innerText.includes('Trace probe')");
  stdout.writeln('TITLE_IN_UI: $meta');

  // Network tab.
  await page.evaluate(
      "() => [...document.querySelectorAll('.tabbed-pane-tab-label')].find(e => e.textContent === 'Network')?.click()");
  await page.waitForTimeout(const Duration(milliseconds: 1500));
  // The rows are a `GridView`, and `grid-view-column-name` is the URL cell.
  // An empty tab renders a `PlaceholderPanel` instead of the grid, so the two
  // answers are told apart rather than both coming back as an empty list —
  // this read used to look for `.network-request-title-url`, a class the
  // shipped viewer no longer has, and reported no requests for a trace that
  // had four.
  final network = await page.evaluate('''
    () => {
      const cells = [...document.querySelectorAll('.network-grid-view .grid-view-column-name')];
      if (cells.length)
        return cells.map(e => e.textContent);
      // No grid at all means the viewer drew its "No network calls"
      // placeholder, which is a different answer from a grid with no rows.
      return document.querySelector('.network-grid-view')
          ? 'grid with no rows'
          : 'no network grid (viewer says the trace has no requests)';
    }''');
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
  // `[data-testid=source-code]` and not `.source-tab`: the shipped viewer has
  // no such class, and this read reported no source for traces recorded with
  // `sources: true` — the same silent nothing the Network read used to give.
  final source = await page.evaluate('''
    () => {
      const pane = document.querySelector('[data-testid=source-code]');
      if (!pane) return 'no source pane';
      const name = pane.querySelector('.source-tab-file-name')?.textContent ?? '(no file name)';
      const code = pane.querySelector('[data-testid=source-code-mirror]')?.innerText
          ?.replace(/\\s+/g, ' ').trim().slice(0, 160) ?? '';
      return name + ' | ' + code;
    }''');
  stdout.writeln('SOURCE: $source');

  // Attachments tab. It only exists when some action carried attachments, so
  // an absent tab and an empty one are different answers.
  final attachmentsTab = await page.evaluate('''
    () => {
      const tab = [...document.querySelectorAll('.tabbed-pane-tab-label')]
          .find(e => e.textContent === 'Attachments');
      if (!tab) return 'no Attachments tab';
      tab.click();
      return null;
    }''');
  if (attachmentsTab == null) {
    await page.waitForTimeout(const Duration(milliseconds: 800));
    final items = await page.evaluate(
        "() => [...document.querySelectorAll('.attachments-tab .attachment-item')].map(e => e.innerText.replace(/\\s+/g, ' ').trim().slice(0, 80))");
    stdout.writeln('ATTACHMENTS: $items');
  } else {
    stdout.writeln('ATTACHMENTS: $attachmentsTab');
  }

  if (shot != null) {
    await page.screenshot(path: shot, fullPage: false);
    stdout.writeln('SCREENSHOT: $shot');
  }
  stdout.writeln('ERRORS: ${errors.isEmpty ? 'none' : errors.join(' | ')}');

  await browser.close();
}
