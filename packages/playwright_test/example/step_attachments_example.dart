// Records a trace whose steps carry attachments, so the official viewer can
// be asked what it drew.
//
//   dart run packages/playwright_test/example/step_attachments_example.dart [out.zip]
//
// Then serve it and read the UI back, which is how this repository proves a
// trace opens — `tool/open_trace_in_viewer.dart` documents the procedure:
//
//   npx playwright@1.63.0 show-trace --host 127.0.0.1 --port 9299 <out.zip>
//   dart run tool/open_trace_in_viewer.dart "<url from the 302>"
//
// The Attachments tab should list both items: the PNG rendered inline and the
// text file behind a download link.
import 'dart:convert';
import 'dart:io';

import 'package:playwright/playwright.dart';
import 'package:playwright_test/src/step.dart';

Future<void> main(List<String> args) async {
  final out = args.isEmpty
      ? '${Directory.systemTemp.path}/dart-trace-attachments.zip'
      : args.first;

  final server = await HttpServer.bind('127.0.0.1', 0);
  final base = 'http://127.0.0.1:${server.port}';
  server.listen((request) async {
    request.response
      ..statusCode = 200
      ..headers.contentType = ContentType.html
      ..write('<!doctype html><html><head><title>Attach probe</title></head>'
          '<body><h1>Attach probe</h1><button id="go">Go</button></body>'
          '</html>');
    await request.response.close();
  });

  final playwright = await Playwright.create();
  final browser = await playwright.chromium.launch();
  final context = await browser.newContext(viewport: (width: 900, height: 600));
  await context.tracing.start(title: 'Attach probe', snapshots: true);
  final page = await context.newPage();

  // `attach` hangs the file off the call that is running, and outside a step
  // there is no such call — see its dartdoc. `runWithCurrentPage` is what a
  // `playwrightTest` does for you; here it is spelled out because this is a
  // plain script.
  await runWithCurrentPage(page, () async {
    await step('open and capture', () async {
      await page.goto('$base/');
      await attach('shot',
          body: await page.screenshot(), contentType: 'image/png');
      await attach('note',
          body: utf8.encode('hello from the dart port'),
          contentType: 'text/plain');
    });
  });

  final path = await context.tracing.stop(path: out);
  await browser.close();
  await server.close(force: true);
  stdout.writeln('trace: $path');
}
