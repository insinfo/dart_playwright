import 'dart:async';
import 'dart:io';

import 'package:playwright/playwright.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty || arguments.length > 2) {
    stderr.writeln(
      'uso: dart run examples/web_canvas_smoke.dart <url> [captura.png]',
    );
    exitCode = 64;
    return;
  }
  final playwright = await Playwright.create();
  final browser = await playwright.chromium.launch(headless: true);
  try {
    final context = await browser.newContext(
      viewport: (width: 1280, height: 800),
    );
    final page = await context.newPage();
    await page.goto(arguments.first);
    try {
      await page.waitForFunction(
        "document.querySelector('canvas') !== null && "
        "document.querySelector('canvas').width > 0 && "
        "document.querySelector('canvas').height > 0",
        timeout: const Duration(seconds: 30),
      );
    } on TimeoutException {
      throw StateError('A página não apresentou uma superfície canvas.');
    }
    final metrics = await page.evaluate("({"
        "width: document.querySelector('canvas').width,"
        "height: document.querySelector('canvas').height,"
        "cssWidth: document.querySelector('canvas').getBoundingClientRect().width,"
        "cssHeight: document.querySelector('canvas').getBoundingClientRect().height"
        "})");
    await Future<void>.delayed(const Duration(seconds: 2));
    final errors = await page.evaluate('globalThis.__dartUiErrors ?? []');
    if (errors is List && errors.isNotEmpty) {
      throw StateError('Erros JavaScript durante a renderização: $errors');
    }
    final frameworkError = await page.evaluate(
      "document.documentElement.getAttribute('data-dart-ui-error')",
    );
    if (frameworkError != null) {
      throw StateError('Erro contido pelo dart_ui: $frameworkError');
    }
    if (arguments.length == 2) {
      await page.screenshot(path: File(arguments[1]).absolute.path);
    }
    stdout.writeln('OK: superfície web renderizada: $metrics');
  } finally {
    await browser.close();
  }
}
