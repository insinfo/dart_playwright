import 'dart:io';
import 'package:test/test.dart';
import 'package:playwright/playwright.dart';

void main() {
  group('Playwright Chromium E2E', () {
    late Playwright playwright;
    late Browser browser;
    late HttpServer server;

    setUpAll(() async {
      // 1. Inicializa Servidor HTTP estático para os testes
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest request) {
        request.response
          ..headers.contentType = ContentType.html
          ..write(
              '<html><head><title>Test Page</title></head><body><h1 id="header">Hello Dart</h1></body></html>')
          ..close();
      });

      // 2. Inicializa o Playwright e baixa o Browser se necessário
      playwright = await Playwright.create();
      browser = await playwright.chromium.launch(headless: true);
    });

    tearDownAll(() async {
      await browser.close();
      await server.close(force: true);
    });

    test('waitForTimeout espera pelo menos o tempo pedido', () async {
      final context = await browser.newContext();
      final page = await context.newPage();
      await page.goto('http://127.0.0.1:${server.port}');

      final relogio = Stopwatch()..start();
      await page.waitForTimeout(const Duration(milliseconds: 300));
      relogio.stop();

      // Espera fixa e ruim em teste, e por isso este e o unico lugar onde ela
      // aparece: o que se verifica aqui e a propria espera. A margem cobre a
      // resolucao do temporizador, mas nao chega perto de deixar passar uma
      // implementacao que nao espere.
      expect(relogio.elapsedMilliseconds, greaterThanOrEqualTo(290));
      await context.close();
    });

    test('Deve navegar e extrair o título corretamente', () async {
      final context = await browser.newContext();
      final page = await context.newPage();

      final url = 'http://127.0.0.1:${server.port}';
      await page.goto(url);

      final title = await page.title();
      expect(title, equals('Test Page'));

      await context.close();
    });

    test('Deve localizar e extrair o textContent do h1', () async {
      final context = await browser.newContext();
      final page = await context.newPage();

      final url = 'http://127.0.0.1:${server.port}';
      await page.goto(url);

      final locator = page.locator('#header');
      final text = await locator.textContent();
      expect(text, equals('Hello Dart'));

      await context.close();
    });

    test('Deve suportar evaluate com JSHandle', () async {
      final context = await browser.newContext();
      final page = await context.newPage();

      final url = 'http://127.0.0.1:${server.port}';
      await page.goto(url);

      // Avalia um JSHandle e interage com ele
      final handle =
          await page.evaluateHandle('document.querySelector("#header")');
      expect(handle, isA<ElementHandle>());

      final element = handle as ElementHandle;
      final text = await element.textContent();
      expect(text, equals('Hello Dart'));

      await context.close();
    });
  });
}
