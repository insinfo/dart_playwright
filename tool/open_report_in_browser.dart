// Proof that the HTML report this port generates actually renders.
//
// A report that is written but never opened is a file, not a report. This
// drives the port's own Chromium at the generated `index.html`, reads the DOM
// back and prints what the page drew: the counters, the test rows with their
// status, and -- for a failing test -- the error text, the steps and the
// attachments it shows. It is the same idea as `open_trace_in_viewer.dart`,
// with one difference: there the viewer is somebody else's and the format is
// the thing under test, while here both sides are ours, so what is being
// checked is that the data reached the screen.
//
// Run it like this:
//
//   # 1. run a suite that fails on purpose and report on it
//   cd packages/playwright_test
//   dart run playwright_test:report --html ../../.tmptest/relatorio \
//       -- test/fixtures/relatorio_child.dart -j 1
//
//   # 2. read the page back
//   dart run tool/open_report_in_browser.dart ../../.tmptest/relatorio/index.html
//
// A second argument writes a screenshot of the page next to the output, a
// third narrows the "show me the steps" pass to a different test, and
// `--out=<file>` writes the same lines to a file. That last one exists for a
// concrete reason: a caller that reads this script's stdout through a pipe
// waits for the pipe to close, and the browser this script launched keeps it
// open past exit -- so `report_end_to_end_test.dart` reads the file instead.
import 'dart:convert';
import 'dart:io';

import 'package:playwright/playwright.dart';

/// Everything reported, so that `--out` can write the same text to a file.
final StringBuffer _log = StringBuffer();

void _say(String line) {
  stdout.writeln(line);
  _log.writeln(line);
}

Future<void> main(List<String> args) async {
  final out = args
      .where((arg) => arg.startsWith('--out='))
      .map((arg) => arg.substring('--out='.length))
      .firstOrNull;
  final positional = args.where((arg) => !arg.startsWith('--')).toList();
  if (positional.isEmpty) {
    stderr.writeln('usage: dart run tool/open_report_in_browser.dart '
        '<index.html> [shot.png] [query] [--out=<file>]');
    exit(64);
  }
  final url = Uri.file(File(positional.first).absolute.path).toString();
  final shot = positional.length > 1 ? positional[1] : null;

  final playwright = await Playwright.create();
  final browser = await playwright.chromium.launch();
  final context =
      await browser.newContext(viewport: (width: 1400, height: 1000));
  final page = await context.newPage();

  final problems = <String>[];
  page.onPageError.listen((e) => problems.add('pageerror: ${e.message}'));
  page.onConsole.listen((m) {
    if (m.type == 'error') problems.add('console.error: ${m.text}');
  });

  await page.goto(url);
  // The page decodes its payload and builds the DOM synchronously on load, so
  // one row being present means the whole list is.
  await page.waitForFunction(
      "() => document.querySelectorAll('.tab').length > 0",
      timeout: const Duration(seconds: 15));

  _say('TITLE: ${await page.title()}');

  final counters = await page.evaluate('''
    () => [...document.querySelectorAll('.tabs .tab')].map(
        t => t.textContent.replace(/\\s+/g, ' ').trim())''');
  _say('COUNTERS: ${(counters as List).join(' | ')}');

  // The failed filter is the one a reader clicks first, so it is the one worth
  // proving: it has to narrow the list to the tests that actually failed.
  //
  // The hash is set from inside the page rather than by navigating to it: a
  // same-document navigation fires no lifecycle event, so `goto` would wait
  // for a load that is never going to happen.
  await page.evaluate("() => { location.hash = '?q=s:failed'; }");
  await page.waitForFunction(
      "() => document.querySelectorAll('.row').length > 0",
      timeout: const Duration(seconds: 10));
  final failed = await page.evaluate('''
    () => [...document.querySelectorAll('.row')].map(r => ({
      status: r.className.replace('row ', ''),
      title: r.querySelector('.title').textContent.replace(/\\s+/g, ' ').trim(),
    }))''');
  _say('FILTER s:failed ->');
  for (final row in failed as List) {
    _say('  [${(row as Map)['status']}] ${row['title']}');
  }
  if (failed.isEmpty) problems.add('the s:failed filter showed no test');

  // Open the first failure and read its detail pane.
  await page.click('.row');
  await page.waitForFunction(
      "() => document.querySelector('.err') || document.querySelector('.att')",
      timeout: const Duration(seconds: 10));
  final detail = await page.evaluate('''
    () => ({
      heading: document.querySelector('h1.detail').textContent.replace(/\\s+/g, ' ').trim(),
      errors: [...document.querySelectorAll('.err')].map(e => e.textContent.trim()),
      steps: [...document.querySelectorAll('.steps .line .t')].map(t => t.textContent.trim()),
      attachments: [...document.querySelectorAll('.att')].map(a => ({
        name: a.querySelector('.name').textContent.trim(),
        img: a.querySelector('img') ? a.querySelector('img').getAttribute('src') : null,
        imgWidth: a.querySelector('img') ? a.querySelector('img').naturalWidth : 0,
        text: a.querySelector('pre') ? a.querySelector('pre').textContent.trim() : null,
      })),
    })''') as Map;

  _say('DETAIL heading: ${detail['heading']}');
  for (final error in detail['errors'] as List) {
    _say('DETAIL error: ${_oneLine('$error')}');
  }
  for (final step in detail['steps'] as List) {
    _say('DETAIL step: $step');
  }
  for (final attachment in (detail['attachments'] as List).cast<Map>()) {
    final rendered = attachment['img'] != null
        ? 'image ${attachment['img']} (${attachment['imgWidth']}px wide)'
        : attachment['text'] != null
            ? 'text "${_oneLine('${attachment['text']}')}"'
            : 'link';
    _say('DETAIL attachment: ${attachment['name']} -> $rendered');
    // A screenshot that is in the DOM but did not decode is the failure mode
    // that matters here: the report claims to show the page and shows a
    // broken image instead.
    if (attachment['img'] != null && (attachment['imgWidth'] as int) == 0) {
      problems.add('the image ${attachment['img']} did not load');
    }
  }

  if (shot != null) {
    await page.screenshot(path: shot, fullPage: true);
    _say('SHOT: $shot');
  }

  // A second test, opened for its steps: the step tree and the attachment
  // hanging off a step are the parts that come from this port's own side
  // channel rather than from the runner, so they are the parts most worth
  // seeing on screen.
  final withSteps = positional.length > 2 ? positional[2] : 'passos';
  await page
      .evaluate('() => { location.hash = ${jsonEncode('?q=$withSteps')}; }');
  final found =
      await page.evaluate("() => document.querySelectorAll('.row').length > 0");
  if (found == true) {
    await page.click('.row');
    await page.waitForFunction("() => document.querySelector('h1.detail')",
        timeout: const Duration(seconds: 10));
    final steps = await page.evaluate('''
      () => [...document.querySelectorAll('.steps li')].map(li => ({
        depth: (() => {
          let depth = 0;
          for (let node = li.parentElement; node; node = node.parentElement)
            if (node.tagName === 'LI') ++depth;
          return depth;
        })(),
        title: li.querySelector('.line .t').textContent.trim(),
        attachment: li.querySelector(':scope > .att .name')
            ? li.querySelector(':scope > .att .name').textContent.trim() : null,
      }))''');
    _say('STEPS of "$withSteps":');
    for (final step in steps as List) {
      final row = step as Map;
      final extra =
          row['attachment'] == null ? '' : '  [+ ${row['attachment']}]';
      stdout
          .writeln('  ${'  ' * (row['depth'] as int)}- ${row['title']}$extra');
    }
    if (steps.isEmpty) problems.add('the test "$withSteps" showed no step');
  } else {
    problems.add('no test matched "$withSteps"');
  }

  await browser.close();

  if (problems.isNotEmpty) {
    for (final problem in problems) {
      _say('PROBLEM: $problem');
    }
  } else {
    _say('OK: the report rendered with no page errors.');
  }
  if (out != null) File(out).writeAsStringSync(_log.toString());
  if (problems.isNotEmpty) exit(1);
}

String _oneLine(String text) {
  final flat = const LineSplitter()
      .convert(text)
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .join(' / ');
  return flat.length > 160 ? '${flat.substring(0, 160)}...' : flat;
}
