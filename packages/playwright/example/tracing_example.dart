// Records a trace of a navigation with a click and a network request.
//
//   dart run packages/playwright/example/tracing_example.dart [engine] [out.zip]
//
// Then open the result with the official viewer:
//
//   npx playwright show-trace <out.zip>
//
// `engine` is chromium (the default), firefox or webkit.
import 'dart:convert';
import 'dart:io';

import 'package:playwright/playwright.dart';

Future<void> main(List<String> args) async {
  final engine = args.isEmpty ? 'chromium' : args.first;
  final out = args.length > 1
      ? args[1]
      : '${Directory.systemTemp.path}/dart-trace-$engine.zip';

  final server = await HttpServer.bind('127.0.0.1', 0);
  final base = 'http://127.0.0.1:${server.port}';
  server.listen((request) async {
    final path = request.uri.path;
    if (path == '/api/items') {
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'items': ['alpha', 'beta']
        }));
      await request.response.close();
      return;
    }
    if (path == '/style.css') {
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType('text', 'css')
        ..write('body { font-family: sans-serif; background: #fafafa; }');
      await request.response.close();
      return;
    }
    request.response
      ..statusCode = 200
      ..headers.contentType = ContentType.html
      ..write('''
<!doctype html>
<html><head><title>Trace probe</title>
<link rel="stylesheet" href="/style.css"></head>
<body>
  <h1>Trace probe</h1>
  <button id="load">Load items</button>
  <ul id="items"></ul>
  <script>
    console.log('page booted');
    document.getElementById('load').addEventListener('click', async () => {
      const res = await fetch('/api/items');
      const data = await res.json();
      document.getElementById('items').innerHTML =
          data.items.map(i => '<li>' + i + '</li>').join('');
    });
  </script>
</body></html>
''');
    await request.response.close();
  });

  final playwright = await Playwright.create();
  final browserType = switch (engine) {
    'firefox' => playwright.firefox,
    'webkit' => playwright.webkit,
    _ => playwright.chromium,
  };
  final browser = await browserType.launch();
  final context = await browser.newContext(viewport: (width: 900, height: 600));

  await context.tracing.start(title: 'Dart port probe', sources: true);

  final page = await context.newPage();
  await page.goto('$base/');
  await page.locator('#load').click();
  await page.locator('li').first.waitFor();
  final text = await page.locator('#items').innerText();
  await page.title();

  final path = await context.tracing.stop(path: out);

  await browser.close();
  await server.close(force: true);

  stdout.writeln('items: ${text.replaceAll('\n', ',')}');
  stdout.writeln('trace: $path');
}
