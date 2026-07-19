import 'package:test/test.dart';
import 'package:playwright/playwright.dart';
import 'test_server.dart';

void main() {
  group('Browser Parity E2E Tests', () {
    late Playwright playwright;
    late TestServer server;
    
    setUpAll(() async {
      server = await TestServer.start();
      playwright = await Playwright.create();
    });
    
    tearDownAll(() async {
      await server.stop();
    });

    final browsers = ['chromium', 'firefox', 'webkit'];

    for (final browserName in browsers) {
      group('[$browserName]', () {
        late Browser browser;
        var browserLaunched = false;
        late BrowserContext context;
        late Page page;

        setUpAll(() async {
          if (browserName == 'chromium') {
            browser = await playwright.chromium.launch(headless: true);
          } else if (browserName == 'firefox') {
            browser = await playwright.firefox.launch(headless: true);
          } else if (browserName == 'webkit') {
            browser = await playwright.webkit.launch(headless: true);
          }
          browserLaunched = true;
        });

        setUp(() async {
          context = await browser.newContext();
          page = await context.newPage();
        });

        tearDown(() async {
          await context.close();
        });

        tearDownAll(() async {
          // setUpAll may have failed before `browser` was assigned.
          if (browserLaunched) await browser.close();
        });

        test('Deve navegar e extrair o título corretamente', () async {
          await page.goto(server.url('/title'));
          final title = await page.title();
          expect(title, equals('Test Page Title'));
        });

        test('Deve localizar e extrair o textContent', () async {
          await page.goto(server.url('/text'));
          final text = await page.locator('#content').textContent();
          expect(text, equals('Hello, World!'));
        });

        test('Deve suportar JS evaluate', () async {
          await page.goto(server.url('/hello'));
          final result = await page.evaluate('() => 2 + 2');
          expect(result, equals(4));
        });

        test('Deve suportar Page.screenshot', () async {
          await page.goto(server.url('/visual'));
          final screenshot = await page.screenshot();
          expect(screenshot, isNotEmpty);
          // Verificar se é PNG (Chromium/Firefox)
          // Mas como estamos no v0.1, ao menos verificar se retornou bytes.
          expect(screenshot.length, greaterThan(100)); 
        });

        test('Deve clicar com evento confiavel (isTrusted)', () async {
          await page.goto(server.url('/button'));
          await page.locator('#clickMe').click();
          // __clicked holds event.isTrusted: only real protocol input passes.
          final clicked = await page.evaluate('() => window.__clicked');
          expect(clicked, isTrue);
        });

        test('Deve preencher e inspecionar formulario', () async {
          await page.goto(server.url('/form'));

          final name = page.locator('#name');
          expect(await name.inputValue(), equals('initial'));
          await name.fill('Playwright Dart');
          expect(await name.inputValue(), equals('Playwright Dart'));
          // The input event must come from trusted protocol-level typing.
          expect(await page.evaluate('() => window.__inputTrusted'), isTrue);

          expect(await name.getAttribute('data-role'), equals('field'));
          expect(await name.getAttribute('missing'), isNull);
          expect(await page.locator('.item').count(), equals(3));
        });

        test('Deve verificar visibilidade e estado de elementos', () async {
          await page.goto(server.url('/form'));

          expect(await page.locator('#name').isVisible(), isTrue);
          expect(await page.locator('#hidden').isVisible(), isFalse);
          expect(await page.locator('#btn').isEnabled(), isFalse);

          final checkbox = page.locator('#agree');
          expect(await checkbox.isChecked(), isFalse);
          await checkbox.check();
          expect(await checkbox.isChecked(), isTrue);
          await checkbox.uncheck();
          expect(await checkbox.isChecked(), isFalse);

          final select = page.locator('#color');
          await select.selectOption('green');
          expect(await select.inputValue(), equals('green'));
        });

        test('Deve aguardar elemento dinamico com waitForSelector', () async {
          await page.goto(server.url('/delayed-element'));
          await page.waitForSelector('#delayed',
              timeout: Duration(seconds: 5));
          expect(await page.locator('#delayed').textContent(),
              equals('Appeared!'));
        });

        test('Deve expor content() e url()', () async {
          await page.goto(server.url('/text'));
          expect(await page.url(), equals(server.url('/text')));
          final html = await page.content();
          expect(html, contains('Hello, World!'));
          expect(html.toLowerCase(), contains('<html'));
        });

        test('Deve interceptar rotas com Page.route', () async {
          await page.route('**/title', (route) async {
            await route.fulfill(
              status: 200,
              body: '<html><head><title>Intercepted</title></head><body></body></html>',
            );
          });
          
          await page.goto(server.url('/title'));
          expect(await page.title(), equals('Intercepted'));
        });
      });
    }
  });
}
