/// Drives the real gallery on the DOM path and asserts the things a unit test
/// cannot: trusted Tab traversal, the browser's own accessibility tree, and a
/// selection made through the page rather than through a Dart API.
///
/// Run with the playwright workspace's package config, from the dart_ui root:
///
/// ```
/// dart --packages=C:/MyDartProjects/playwright/.dart_tool/package_config.json \
///   <this file>
/// ```
library;

import 'dart:async';

import 'dart:io';

import 'package:playwright/playwright.dart';

const String webRoot = r'C:\MyDartProjects\dart_ui\web';

final List<String> failures = <String>[];
final List<String> notes = <String>[];

void check(String what, bool ok, [String? detail]) {
  if (ok) {
    notes.add('PASS  $what${detail == null ? '' : ' -- $detail'}');
  } else {
    failures.add('FAIL  $what${detail == null ? '' : ' -- $detail'}');
  }
}

Future<HttpServer> serve() async {
  final HttpServer server = await HttpServer.bind('127.0.0.1', 0);
  final Map<String, ContentType> types = <String, ContentType>{
    '.html': ContentType.html,
    '.js': ContentType('application', 'javascript'),
    '.ttf': ContentType('font', 'ttf'),
  };
  unawaited(server.forEach((HttpRequest request) async {
    String path = request.uri.path;
    if (path == '/' || path.isEmpty) path = '/index.html';
    final File file = File('$webRoot${path.replaceAll('/', r'\')}');
    if (!file.existsSync()) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final String extension =
        path.contains('.') ? path.substring(path.lastIndexOf('.')) : '';
    request.response.headers.contentType =
        types[extension] ?? ContentType.binary;
    await request.response.addStream(file.openRead());
    await request.response.close();
  }));
  return server;
}

/// Polls [expression] until it is true or the budget runs out.
///
/// The gallery starts asynchronously - it fetches a font before the first frame
/// - so every assertion below has to wait for a first paint rather than assume
/// one. A fixed sleep would be either flaky or slow; this is neither.
Future<bool> waitFor(Page page, String expression, {int attempts = 100}) async {
  for (int i = 0; i < attempts; i++) {
    final Object? value = await page.evaluate('() => !!($expression)');
    if (value == true) return true;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return false;
}

Future<void> main() async {
  final HttpServer server = await serve();
  final String base = 'http://127.0.0.1:${server.port}';
  stdout.writeln('serving $webRoot at $base');

  final Playwright playwright = await Playwright.create();
  Browser? browser;
  try {
    browser = await playwright.chromium.launch(headless: true);
    final BrowserContext context =
        await browser.newContext(viewport: (width: 1280, height: 900));
    final Page page = await context.newPage();

    // The query parameter is the documented opt-in; see `_domRequested` in
    // web/main.dart. Without it the page would pick WebGL2 and this whole run
    // would assert nothing.
    await page.goto('$base/?renderer=dom');

    final bool started = await waitFor(
      page,
      "document.querySelector('.dartui-dom-host')",
    );
    check('the DOM host is in the page', started);
    if (!started) {
      stdout.writeln(failures.join('\n'));
      return;
    }
    await waitFor(
      page,
      "document.querySelector('.dartui-dom-scene').children.length > 0",
    );

    // ---- 1. the interface is elements, not pixels ------------------------
    final Object? elementCount = await page.evaluate(
      "() => document.querySelectorAll('.dartui-dom-host *').length",
    );
    check('the interface is made of elements', (elementCount as num) > 50,
        '$elementCount elements');

    final Object? text = await page.evaluate(
      "() => document.querySelector('.dartui-dom-scene').innerText",
    );
    final String innerText = '$text';
    check('the page has real text a crawler could read',
        innerText.trim().length > 20, '${innerText.length} characters');

    // ---- 2. selection, made by the page ----------------------------------
    final Object? selected = await page.evaluate('''() => {
      const scene = document.querySelector('.dartui-dom-scene');
      const range = document.createRange();
      range.selectNodeContents(scene);
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      const value = selection.toString();
      selection.removeAllRanges();
      return value;
    }''');
    check('the browser can select the text', '$selected'.trim().isNotEmpty,
        '${'$selected'.trim().length} characters selected');

    // ---- 3. find-in-page has something to find ---------------------------
    final Object? firstWord = await page.evaluate('''() => {
      const t = document.querySelector('.dartui-dom-scene').innerText;
      const m = t.match(/[A-Za-z]{4,}/);
      return m ? m[0] : '';
    }''');
    check('find-in-page has a word to match', '$firstWord'.isNotEmpty,
        'first word: "$firstWord"');

    // ---- 4. trusted Tab traversal ---------------------------------------
    // The one assertion no unit test in this repository can make: these are
    // real key events from the browser, so what moves is the browser's own
    // sequential focus navigation over the published DOM order.
    final Object? focusableCount = await page.evaluate(
      "() => document.querySelectorAll("
      "'.dartui-dom-semantics button, "
      ".dartui-dom-semantics [tabindex=\"0\"]').length",
    );
    check('the semantics layer published focusable controls',
        (focusableCount as num) > 0, '$focusableCount focusable');

    await page.evaluate("() => document.body.focus()");
    final List<String> focusOrder = <String>[];
    for (int i = 0; i < 8; i++) {
      await page.keyboard.press('Tab');
      final Object? active = await page.evaluate('''() => {
        const a = document.activeElement;
        if (!a) return '';
        if (!a.closest || !a.closest('.dartui-dom-semantics')) return '(outside)';
        return (a.getAttribute('aria-label') || a.tagName) +
            '#' + (a.getAttribute('data-dartui-semantics-id') || '?');
      }''');
      focusOrder.add('$active');
    }
    final List<String> inside = focusOrder
        .where((String s) => s != '(outside)' && s.isNotEmpty)
        .toList();
    check('Tab reaches the published controls', inside.isNotEmpty,
        focusOrder.join(' -> '));
    check('Tab visits distinct controls',
        inside.toSet().length == inside.length, inside.join(' -> '));

    // The DOM order the layer published must be the order Tab walked. This is
    // the assertion that "reading order is paint order" is not just a comment.
    // `:not([disabled])`, and the exclusion is the point rather than a fudge.
    // The layer puts a real `disabled` attribute on a native `<button>` when the
    // semantic node says so, and the browser then takes it out of the sequential
    // focus order by itself - which is exactly the behaviour a `[role=button]`
    // div would have had to reimplement. The first run of this probe failed
    // here, and the backend was right.
    final Object? domOrder = await page.evaluate('''() => {
      const nodes = document.querySelectorAll(
        '.dartui-dom-semantics button:not([disabled]), ' +
        '.dartui-dom-semantics [tabindex="0"]:not([aria-disabled="true"])');
      return Array.from(nodes).map(n =>
        (n.getAttribute('aria-label') || n.tagName) + '#' +
        (n.getAttribute('data-dartui-semantics-id') || '?'));
    }''');
    final List<String> published =
        (domOrder as List<Object?>).map((Object? e) => '$e').toList();
    final int prefix =
        inside.length < published.length ? inside.length : published.length;
    check(
      'Tab order equals published DOM order',
      prefix > 0 &&
          published.take(prefix).toList().join('|') ==
              inside.take(prefix).toList().join('|'),
      'tab: ${inside.take(prefix).join(' -> ')}  |  dom: '
          '${published.take(prefix).join(' -> ')}',
    );

    // ---- 5. focus survives frames ---------------------------------------
    // The frame loop is running at vsync, so waiting a second is waiting
    // roughly sixty presents. A backend that rebuilt its tree would have blurred
    // the element long before this returns.
    final Object? before = await page.evaluate(
      "() => document.activeElement && "
      "document.activeElement.getAttribute('data-dartui-semantics-id')",
    );
    await Future<void>.delayed(const Duration(seconds: 1));
    final Object? after = await page.evaluate(
      "() => document.activeElement && "
      "document.activeElement.getAttribute('data-dartui-semantics-id')",
    );
    check('focus survives ~60 presents', before != null && before == after,
        'before=$before after=$after');

    // ---- 6. the accessibility tree ---------------------------------------
    final AccessibilitySnapshot ax = await page.accessibilitySnapshot();
    final List<String> roles = <String>[];
    void walk(AccessibilityNode node) {
      roles.add('${node.role}${node.name.isEmpty ? '' : '="${node.name}"'}');
      node.children.forEach(walk);
    }

    walk(ax.root);
    check('the accessibility tree has more than the root fragment',
        roles.length > 1, '${roles.length} nodes');
    check(
      'it contains named controls',
      roles.any((String r) => r.contains('=') && !r.startsWith('fragment')),
      roles.take(20).join(', '),
    );

    // ---- 7. what the backend refused ------------------------------------
    // Not an assertion: a record. The console warnings are the refusal list for
    // this particular interface, which is the thing a human has to look at.
    final Object? clientRects = await page.evaluate('''() => {
      const host = document.querySelector('.dartui-dom-host');
      const r = host.getBoundingClientRect();
      return JSON.stringify({w: r.width, h: r.height});
    }''');
    notes.add('INFO  host box: $clientRects');
    final Object? spans = await page.evaluate(
      "() => document.querySelectorAll('.dartui-dom-scene span').length",
    );
    final Object? unresolved = await page.evaluate(
      "() => document.querySelectorAll("
      "'.dartui-dom-scene span[data-dartui-unresolved]').length",
    );
    notes.add('INFO  $spans text runs, $unresolved with unnameable glyphs');
    notes.add('INFO  accessibility roles: ${roles.take(25).join(', ')}');
  } finally {
    await browser?.close();
    await server.close(force: true);
  }

  stdout
    ..writeln('')
    ..writeln(notes.join('\n'))
    ..writeln('')
    ..writeln(failures.isEmpty ? 'ALL CHECKS PASSED' : failures.join('\n'));
  exitCode = failures.isEmpty ? 0 : 1;
}
