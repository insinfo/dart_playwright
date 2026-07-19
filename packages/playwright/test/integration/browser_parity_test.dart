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

        test('Deve digitar texto com eventos reais de teclado', () async {
          await page.goto(server.url('/keyboard'));
          await page.type('#field', 'abc');
          expect(await page.locator('#field').inputValue(), equals('abc'));
          // Real keydown events must have fired for each character.
          final keys = await page.evaluate('() => window.__keys.join(",")');
          expect(keys, equals('a,b,c'));
        });

        test('Deve suportar press de teclas especiais', () async {
          await page.goto(server.url('/keyboard'));
          await page.locator('#field').fill('hello');
          await page.locator('#field').press('Backspace');
          expect(await page.locator('#field').inputValue(), equals('hell'));
        });

        test('Deve gerenciar cookies no contexto', () async {
          await page.goto(server.url('/hello'));
          await context.addCookies([
            {
              'name': 'session',
              'value': 'xyz',
              'url': server.url('/'),
            }
          ]);
          final cookies = await context.cookies();
          expect(cookies.any((c) => c['name'] == 'session' && c['value'] == 'xyz'),
              isTrue);

          await context.clearCookies();
          expect(await context.cookies(), isEmpty);
        });

        test('Deve aceitar dialog prompt com texto', () async {
          await page.goto(server.url('/dialog'));
          page.onDialog((dialog) {
            expect(dialog.type, equals('prompt'));
            dialog.accept('Playwright');
          });
          await page.evaluate('() => window.runPrompt()');
          expect(await page.locator('#result').textContent(),
              equals('got:Playwright'));
        });

        test('Deve capturar storageState com cookies e localStorage', () async {
          await page.goto(server.url('/hello'));
          await page.evaluate('() => localStorage.setItem("k", "v")');
          await context.addCookies([
            {'name': 'a', 'value': 'b', 'url': server.url('/')}
          ]);

          final state = await context.storageState();
          expect((state['cookies'] as List).any((c) => c['name'] == 'a'),
              isTrue);
          final origins = state['origins'] as List;
          expect(origins, isNotEmpty);
          final ls = (origins.first as Map)['localStorage'] as List;
          expect(ls.any((e) => e['name'] == 'k' && e['value'] == 'v'), isTrue);

          await context.clearCookies();
        });

        test('Deve isolar contextos e fechar contexto', () async {
          final ctx1 = await browser.newContext();
          final page1 = await ctx1.newPage();
          await page1.goto(server.url('/hello'));
          await page1.evaluate('() => localStorage.setItem("pw", "ctx1")');
          expect(await page1.evaluate('() => localStorage.getItem("pw")'),
              equals('ctx1'));

          // A second context must not see the first context's storage.
          final ctx2 = await browser.newContext();
          final page2 = await ctx2.newPage();
          await page2.goto(server.url('/hello'));
          expect(
              await page2.evaluate('() => localStorage.getItem("pw")'), isNull);

          await ctx1.close();
          await ctx2.close();
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
