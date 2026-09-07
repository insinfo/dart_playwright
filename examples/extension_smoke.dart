import 'dart:async';
import 'dart:io';

import 'package:playwright/playwright.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty || arguments.length > 3) {
    stderr.writeln('uso: dart run examples/extension_smoke.dart '
        '<diretorio-da-extensao> [executavel-chromium] [captura-popup.png]');
    exitCode = 64;
    return;
  }
  final extension = Directory(arguments.first).absolute;
  if (!File('${extension.path}${Platform.pathSeparator}manifest.json')
      .existsSync()) {
    throw ArgumentError('manifest.json não encontrado em ${extension.path}');
  }

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    request.response.headers.contentType = ContentType.html;
    request.response
        .write('<!doctype html><title>Extension smoke</title><h1>ready</h1>');
    await request.response.close();
  });

  final profile = await Directory.systemTemp.createTemp('dart_pw_extension_');
  final playwright = await Playwright.create();
  final browser = await playwright.chromium.launch(
    headless: false,
    executablePath:
        arguments.length >= 2 && arguments[1] != '-' ? arguments[1] : null,
    userDataDir: profile.path,
    extensionPaths: <String>[extension.path],
  );
  try {
    final context = browser.contexts().first;
    final page = await context.newPage();
    await page.goto('http://127.0.0.1:${server.port}/');
    try {
      await page.waitForFunction(
        "typeof window.dartUiIcpBrasil === 'object' && "
        "typeof window.dartUiIcpBrasil.signPdfHash === 'function' && "
        "document.querySelector('meta[name=\"dart-ui-icp-brasil\"]') !== null",
        timeout: const Duration(seconds: 15),
      );
    } on TimeoutException {
      final diagnostics = await page.evaluate("({"
          "api: typeof window.dartUiIcpBrasil,"
          "marker: document.querySelector('meta[name=\"dart-ui-icp-brasil\"]')?.content ?? null"
          "})");
      throw StateError('extensão não injetada: $diagnostics');
    }
    await page.evaluate("window.__dartUiBridge = 'pending'");
    await page.evaluate(
      "window.dartUiIcpBrasil.status({}).then("
      "() => window.__dartUiBridge = 'connected',"
      "() => window.__dartUiBridge = 'native-host-unregistered')",
    );
    await page.waitForFunction(
      "window.__dartUiBridge !== 'pending'",
      timeout: const Duration(seconds: 10),
    );
    final bridge = await page.evaluate('window.__dartUiBridge');
    final extensionId = await page.evaluate(
      "document.querySelector('meta[name=\"dart-ui-icp-brasil\"]').content",
    );
    final popup = await context.newPage();
    await popup.goto('chrome-extension://$extensionId/popup.html');
    await popup.waitForFunction(
      "document.querySelector('canvas') !== null && "
      "document.querySelector('canvas').width > 0",
      timeout: const Duration(seconds: 20),
    );
    await Future<void>.delayed(const Duration(seconds: 2));
    final popupError = await popup.evaluate(
      "document.documentElement.getAttribute('data-dart-ui-error')",
    );
    if (popupError != null) {
      throw StateError('popup dart_ui apresentou erro: $popupError');
    }
    final surface = await popup.evaluate("({"
        "width: document.querySelector('canvas').getBoundingClientRect().width,"
        "height: document.querySelector('canvas').getBoundingClientRect().height,"
        "charset: document.characterSet"
        "})");
    if (surface is! Map || surface['charset'] != 'UTF-8') {
      throw StateError('superfície dart_ui/UTF-8 inválida: $surface');
    }
    if (arguments.length == 3) {
      await popup.screenshot(path: File(arguments[2]).absolute.path);
    }
    stdout.writeln('OK: extensão $extensionId carregada; ponte: $bridge; '
        'popup dart_ui: $surface');
  } finally {
    await browser.close();
    await server.close(force: true);
    for (var attempt = 0; attempt < 5 && profile.existsSync(); attempt++) {
      try {
        await profile.delete(recursive: true);
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
    if (profile.existsSync()) {
      stderr.writeln(
          'Aviso: perfil temporário ainda está em uso: ${profile.path}');
    }
  }
}
