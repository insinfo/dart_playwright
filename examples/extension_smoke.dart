import 'dart:async';
import 'dart:io';

import 'package:playwright/playwright.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty || arguments.length > 2) {
    stderr.writeln('uso: dart run examples/extension_smoke.dart '
        '<diretorio-da-extensao> [executavel-chromium]');
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
    executablePath: arguments.length == 2 ? arguments[1] : null,
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
      "document.querySelector('#status').textContent !== "
      "'Verificando assinador…'",
      timeout: const Duration(seconds: 10),
    );
    final heading = await popup.locator('h1').textContent();
    final popupStatus = await popup.locator('#status').textContent();
    if (heading != 'Assinatura digital segura') {
      throw StateError('texto UTF-8 do popup inválido: $heading');
    }
    stdout.writeln('OK: extensão $extensionId carregada; ponte: $bridge; '
        'popup: $popupStatus');
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
