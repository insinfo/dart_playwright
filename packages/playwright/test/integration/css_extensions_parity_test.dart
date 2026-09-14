import 'package:test/test.dart';
import 'package:playwright/playwright.dart';
import 'test_server.dart';

/// Parity tests for Playwright's CSS extensions and for shadow piercing in the
/// `css` engine: `:has-text()`, `:text()`, `:text-is()`, `:text-matches()`,
/// `:visible`, `:nth-match()`, the layout selectors and `:light()`.
///
/// Every assertion drives a real browser, in all three engines.
void main() {
  group('Extensoes CSS e shadow DOM', () {
    late Playwright playwright;
    late TestServer server;

    setUpAll(() async {
      server = await TestServer.start();
      playwright = await Playwright.create();
    });

    tearDownAll(() async {
      await server.stop();
    });

    for (final browserName in ['chromium', 'firefox', 'webkit']) {
      group('[$browserName]', () {
        late Browser browser;
        var browserLaunched = false;
        late BrowserContext context;
        late Page page;

        setUpAll(() async {
          browser = switch (browserName) {
            'chromium' => await playwright.chromium.launch(headless: true),
            'firefox' => await playwright.firefox.launch(headless: true),
            _ => await playwright.webkit.launch(headless: true),
          };
          browserLaunched = true;
        });

        setUp(() async {
          context = await browser.newContext();
          page = await context.newPage();
          await page.goto(server.url('/hello'));
          await page.setContent(_fixture);
        });

        tearDown(() async {
          await context.close();
        });

        tearDownAll(() async {
          if (browserLaunched) await browser.close();
        });

        Future<List<String>> ids(Locator locator) async {
          final result = await locator
              .evaluateAll('els => els.map(e => e.id || e.tagName)');
          return (result as List).map((e) => e.toString()).toList();
        }

        // ------------------------------------------------------- :has-text()

        test('Deve casar :has-text() por substring, ignorando maiusculas',
            () async {
          expect(await page.locator('.t:has-text("hello")').count(), equals(3));
          expect(
              await page.locator('.t:has-text("Goodbye")').count(), equals(1));
          expect(await page.locator('.t:has-text("nao existe")').count(),
              equals(0));
        });

        test('Deve normalizar espaco em branco em :has-text()', () async {
          // #t-inner tem "Hello   World" com tres espacos no HTML.
          expect(await ids(page.locator('span:has-text("Hello World")')),
              equals(['t-inner']));
        });

        test('Deve distinguir :text() parcial de :text-is() exato', () async {
          // :text() casa por substring, no elemento mais profundo.
          expect(await ids(page.locator('.t:text("hello")')),
              equals(['t-exact', 't-partial']));
          // :text-is() exige igualdade apos normalizar espaco.
          expect(await ids(page.locator('div:text-is("Hello")')),
              equals(['t-exact']));
          expect(await ids(page.locator('div:text-is("Hello World")')),
              equals(['t-partial']));
          // O span tem "Hello   World": o espaco e normalizado antes de
          // comparar, como upstream faz.
          expect(await ids(page.locator('span:text-is("Hello World")')),
              equals(['t-inner']));
        });

        test('Deve casar :text-matches() com regex e flags', () async {
          expect(await ids(page.locator('.t:text-matches("^Good", "i")')),
              equals(['t-none']));
          expect(await page.locator('.t:text-matches("^good")').count(),
              equals(0));
        });

        // --------------------------------------------------------- :visible

        test('Deve tratar tamanho zero e visibility:hidden como invisiveis',
            () async {
          expect(await page.locator('.v').count(), equals(4));
          expect(await ids(page.locator('.v:visible')), equals(['v-visible']));
          // Tamanho zero: tem caixa, mas com area nula.
          expect(await page.locator('#v-zero:visible').count(), equals(0));
          expect(await page.locator('#v-zero').count(), equals(1));
          // visibility:hidden: tem area, mas nao e pintado.
          expect(await page.locator('#v-hidden:visible').count(), equals(0));
          expect(await page.locator('#v-hidden').count(), equals(1));
          // display:none: nem caixa tem.
          expect(await page.locator('#v-none:visible').count(), equals(0));
        });

        // ------------------------------------------------------ :nth-match()

        test('Deve selecionar a n-esima ocorrencia com :nth-match()', () async {
          expect(await ids(page.locator(':nth-match(.item, 1)')),
              equals(['item-a']));
          expect(await ids(page.locator(':nth-match(.item, 3)')),
              equals(['item-c']));
          expect(await page.locator(':nth-match(.item, 9)').count(), equals(0));
        });

        // -------------------------------------------------- layout selectors

        test('Deve casar :right-of() e ordenar por proximidade', () async {
          expect(await ids(page.locator('.box:right-of(#anchor)')),
              equals(['right', 'far-right']));
          expect(
              await page.locator('#left:right-of(#anchor)').count(), equals(0));
        });

        test('Deve casar :left-of()', () async {
          expect(await ids(page.locator('.box:left-of(#anchor)')),
              equals(['left']));
          expect(
              await page.locator('#right:left-of(#anchor)').count(), equals(0));
        });

        test('Deve casar :above()', () async {
          expect(await ids(page.locator('.box:above(#anchor)')),
              equals(['above']));
          expect(
              await page.locator('#below:above(#anchor)').count(), equals(0));
        });

        test('Deve casar :below()', () async {
          expect(await ids(page.locator('.box:below(#anchor)')),
              equals(['below']));
          expect(
              await page.locator('#above:below(#anchor)').count(), equals(0));
        });

        test('Deve casar :near() e respeitar a distancia maxima', () async {
          final near = await ids(page.locator('.box:near(#anchor)'));
          expect(near.toSet(), equals({'right', 'left', 'above', 'below'}));
          expect(await page.locator('#far-right:near(#anchor)').count(),
              equals(0));
          expect(await page.locator('#far-right:near(#anchor, 300)').count(),
              equals(1));
        });

        // ------------------------------------------------------- shadow DOM

        test('Deve atravessar shadow root aberto no motor css', () async {
          expect(await ids(page.locator('.sd')), equals(['sd-open']));
          expect(await page.locator('#sd-open').textContent(),
              equals('Shadow Open'));
        });

        test('Deve atravessar shadow roots aninhados', () async {
          expect(await page.locator('#sd-deep').textContent(),
              equals('Deep Shadow'));
        });

        test('Nao deve enxergar shadow root fechado', () async {
          expect(await page.locator('#sd-closed').count(), equals(0));
          expect(await page.locator('.sd-closed-class').count(), equals(0));
        });

        test('Deve cruzar a fronteira do shadow com combinadores', () async {
          expect(
              await ids(page.locator('#host-open .sd')), equals(['sd-open']));
          expect(await page.locator('#host-open > .sd').count(), equals(1));
        });

        test('Deve desligar o piercing com :light()', () async {
          expect(await page.locator(':light(.sd)').count(), equals(0));
          expect(await page.locator('css:light=.sd').count(), equals(0));
        });

        test('Deve combinar shadow com extensoes de texto', () async {
          expect(await page.locator('.sd:has-text("shadow open")').count(),
              equals(1));
        });

        test('Os getBy* por atributo tambem devem entrar no shadow aberto',
            () async {
          expect(await page.getByTestId('sd-testid').textContent(),
              equals('Shadow Open'));
          expect(await page.getByPlaceholder('sombra').count(), equals(1));
          expect(await page.getByTitle('titulo na sombra').count(), equals(1));
          // A sombra fechada continua invisivel tambem por aqui.
          expect(await page.getByTestId('sd-closed-testid').count(), equals(0));
        });

        // ------------------------------------------------- casos degenerados

        test('Deve dar erro claro em seletor malformado', () async {
          await expectLater(page.locator('div:has-text(').count(),
              throwsA(isA<InvalidSelectorError>()));
          await expectLater(page.locator('div:nth-match(span)').count(),
              throwsA(isA<InvalidSelectorError>()));
          await expectLater(page.locator('div:visible(1)').count(),
              throwsA(isA<InvalidSelectorError>()));
          await expectLater(page.locator('div:has-text("a"').count(),
              throwsA(isA<InvalidSelectorError>()));
        });

        test('Seletor malformado nao deve esperar ate o timeout', () async {
          await expectLater(
              page
                  .locator('div:has-text(')
                  .textContent(timeout: const Duration(seconds: 30)),
              throwsA(isA<InvalidSelectorError>()));
        });

        // ---------------------------------------------------- :has / :is/:not

        test('Deve suportar :has(), :is() e :not() do Playwright', () async {
          expect(await ids(page.locator('.t:has(span)')), equals(['t-nested']));
          expect(await page.locator('.item:not(#item-a)').count(), equals(3));
          expect(
              await page.locator(':is(#item-a, #item-b)').count(), equals(2));
        });
      });
    }
  });
}

const String _fixture = r'''
<html>
<head>
<style>
  body { margin: 0; font-family: monospace; }
  .box { position: absolute; width: 50px; height: 50px; }
</style>
</head>
<body>
  <div id="texts">
    <div class="t" id="t-exact">Hello</div>
    <div class="t" id="t-partial">Hello World</div>
    <div class="t" id="t-none">Goodbye</div>
    <div class="t" id="t-nested"><span id="t-inner">Hello   World</span></div>
  </div>

  <div id="items">
    <div class="item" id="item-a">A</div>
    <div class="item" id="item-b">B</div>
    <div class="item" id="item-c">C</div>
    <div class="item" id="item-d">D</div>
  </div>

  <div id="vis">
    <div class="v" id="v-visible" style="width:30px;height:30px">v</div>
    <div class="v" id="v-zero" style="width:0;height:0;overflow:hidden">z</div>
    <div class="v" id="v-hidden" style="visibility:hidden;width:30px;height:30px">h</div>
    <div class="v" id="v-none" style="display:none">n</div>
  </div>

  <div class="box" id="anchor" style="left:100px;top:100px">anchor</div>
  <div class="box" id="right" style="left:200px;top:100px">right</div>
  <div class="box" id="far-right" style="left:400px;top:100px">far</div>
  <div class="box" id="left" style="left:0px;top:100px">left</div>
  <div class="box" id="below" style="left:100px;top:200px">below</div>
  <div class="box" id="above" style="left:100px;top:0px">above</div>

  <div id="host-open"></div>
  <div id="host-closed"></div>
  <script>
    var open = document.getElementById('host-open').attachShadow({ mode: 'open' });
    open.innerHTML = '<div class="sd" id="sd-open" data-testid="sd-testid" title="titulo na sombra">Shadow Open</div>' +
        '<input id="sd-input" placeholder="sombra">' +
        '<div id="inner-host"></div>';
    var inner = open.getElementById ? open.getElementById('inner-host') : open.querySelector('#inner-host');
    var deep = inner.attachShadow({ mode: 'open' });
    deep.innerHTML = '<div class="sd-deep" id="sd-deep">Deep Shadow</div>';
    var closed = document.getElementById('host-closed').attachShadow({ mode: 'closed' });
    closed.innerHTML = '<div class="sd sd-closed-class" id="sd-closed" data-testid="sd-closed-testid">Shadow Closed</div>';
  </script>
</body>
</html>
''';
