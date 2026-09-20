// The twin of `open_trace_in_viewer.dart`, for this port's own viewer.
//
// The other script proves a trace this port recorded opens in the *official*
// viewer. This one opens the same trace in the viewer this port *draws*, and
// reads the same things back in the same shape, so the two outputs can be
// diffed line by line. A viewer that opens but shows the wrong thing is worse
// than no viewer, and only the comparison catches that.
//
// Run it like this:
//
//   # 1. record a trace
//   dart run packages/playwright/example/tracing_example.dart chromium out.zip
//
//   # 2. open it in this port's viewer and read the UI back
//   dart run tool/open_trace_in_dart_viewer.dart out.zip [shot.png]
//
// Unlike the official one, this needs no npx and no second server: it starts
// the viewer itself, because the viewer is this repository.
import 'dart:io';

import 'package:playwright/playwright.dart';
import 'package:playwright_trace_viewer_ui/server.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
        'Usage: open_trace_in_dart_viewer.dart <trace.zip> [shot.png]');
    exitCode = 64;
    return;
  }
  final shot = args.length > 1 ? args[1] : null;

  final trace = await LoadedTrace.open(File(args.first).absolute.path);
  final viewer = TraceViewerServer(trace, await ViewerAssets.load());
  await viewer.start();

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

  await page.goto(viewer.url);
  await page.waitForFunction(
      "() => document.querySelectorAll('.action-title').length > 0",
      timeout: const Duration(seconds: 30));

  // The tree opens collapsed, exactly as the official viewer does, so the
  // groups have to be expanded before their contents exist in the DOM.
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

  // Select the last action before reading the per-action tabs, the same way
  // the official run does, so Source and Call have something to show.
  await page.evaluate('''
    () => {
      const entries = [...document.querySelectorAll('.actions-tree-view .tree-view-entry')]
          .filter(e => e.querySelector('.action-title'));
      entries[entries.length - 1]?.click();
    }''');
  await page.waitForTimeout(const Duration(milliseconds: 500));

  final meta = await page
      .evaluate("() => document.body.innerText.includes('Trace probe')");
  stdout.writeln('TITLE_IN_UI: $meta');

  await _selectTab(page, 'Network');
  final network = await page.evaluate('''
    () => {
      const cells = [...document.querySelectorAll('.network-grid-view .grid-view-column-name')];
      if (cells.length)
        return cells.map(e => e.textContent);
      return document.querySelector('.network-grid-view')
          ? 'grid with no rows'
          : 'no network grid (viewer says the trace has no requests)';
    }''');
  stdout.writeln('NETWORK: $network');

  await _selectTab(page, 'Console');
  final console = await page.evaluate(
      "() => document.querySelector('.console-tab')?.innerText?.replace(/\\s+/g, ' ').trim().slice(0, 300)");
  stdout.writeln('CONSOLE: $console');

  await _selectTab(page, 'Source');
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

  // The stack, which the official run does not read but this port cares
  // about: these frames are Dart, and the point of the panel is that they
  // name the test's own file rather than the library's internals.
  final stack = await page.evaluate('''
    () => {
      const rows = [...document.querySelectorAll('.stack-trace-list-view .list-view-entry')];
      if (!rows.length) return 'no stack frames';
      return rows.map(row => {
        const fn = row.querySelector('.stack-trace-frame-function')?.textContent ?? '';
        const loc = row.querySelector('.stack-trace-frame-location')?.textContent ?? '';
        const line = row.querySelector('.stack-trace-frame-line')?.textContent ?? '';
        return fn + ' @ ' + loc + line;
      });
    }''');
  stdout.writeln('STACK: $stack');

  await _selectTab(page, 'Attachments');
  final attachments = await page.evaluate(
      "() => [...document.querySelectorAll('.attachments-tab .attachment-item')].map(e => e.innerText.replace(/\\s+/g, ' ').trim().slice(0, 80))");
  stdout.writeln('ATTACHMENTS: $attachments');

  // What the snapshot panel actually drew. The official run does not check
  // this either, and it is the one thing a viewer can most convincingly fake:
  // an iframe that loaded nothing still looks like a panel.
  final snapshot = await page.evaluate('''
    () => {
      const frame = document.querySelector('iframe.snapshot-visible');
      if (!frame) return 'no visible snapshot iframe';
      const doc = frame.contentDocument;
      return {
        url: document.querySelector('.browser-frame-address')?.textContent,
        bodyText: doc ? doc.body.innerText.replace(/\\s+/g, ' ').trim().slice(0, 120) : null,
        elements: doc ? doc.querySelectorAll('*').length : 0,
      };
    }''');
  stdout.writeln('SNAPSHOT: $snapshot');

  if (shot != null) {
    await page.screenshot(path: shot, fullPage: false);
    stdout.writeln('SCREENSHOT: $shot');
  }
  stdout.writeln('ERRORS: ${errors.isEmpty ? 'none' : errors.join(' | ')}');

  await browser.close();
  await viewer.close();
  exit(0);
}

Future<void> _selectTab(Page page, String title) async {
  await page.evaluate(
      "() => [...document.querySelectorAll('.tabbed-pane-tab-label')].find(e => e.textContent === '$title')?.click()");
  await page.waitForTimeout(const Duration(milliseconds: 800));
}
