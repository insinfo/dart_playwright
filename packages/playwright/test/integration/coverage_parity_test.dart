import 'package:playwright/playwright.dart';
import 'package:test/test.dart';

import 'test_server.dart';

/// `page.coverage` on the three engines.
///
/// Two halves, and they are not symmetric on purpose. On Chromium coverage is
/// exercised for real; on Firefox and WebKit the only thing to assert is that
/// asking throws, and says why. The counts come from V8's `Profiler` domain
/// and from Blink's CSS rule-usage tracking, and neither the Juggler protocol
/// nor the WebKit inspector protocol has anything equivalent — upstream
/// Playwright exposes `page.coverage` on the Chromium page alone. Returning
/// an empty list there would be worse than throwing: a caller would read it
/// as "nothing ran".
void main() {
  group('Coverage', () {
    late Playwright playwright;
    late TestServer server;

    setUpAll(() async {
      server = await TestServer.start();
      playwright = await Playwright.create();
    });

    tearDownAll(() async {
      await server.stop();
    });

    group('[chromium]', () {
      late Browser browser;
      var browserLaunched = false;
      late BrowserContext context;
      late Page page;

      setUpAll(() async {
        browser = await playwright.chromium.launch(headless: true);
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
        if (browserLaunched) await browser.close();
      });

      // ------------------------------------------------ JS coverage

      test('Deve reportar o script externo com a fonte', () async {
        await page.coverage.startJSCoverage();
        await page.goto(server.url('/coverage'));
        final entries = await page.coverage.stopJSCoverage();

        final entry = entries
            .where((e) => e.url.endsWith('/coverage.js'))
            .toList();
        expect(entry, hasLength(1));
        expect(entry.single.source, contains('usedFunction'));
        expect(entry.single.functions, isNotEmpty);
      });

      test('Deve distinguir o que rodou do que nao rodou', () async {
        await page.coverage.startJSCoverage();
        await page.goto(server.url('/coverage'));
        final entries = await page.coverage.stopJSCoverage();
        final entry =
            entries.firstWhere((e) => e.url.endsWith('/coverage.js'));

        int countFor(String name) {
          final fn = entry.functions.where((f) => f.functionName == name);
          if (fn.isEmpty) return -1;
          return fn.single.ranges.first.count;
        }

        expect(countFor('usedFunction'), greaterThan(0));
        expect(countFor('neverCalledFunction'), equals(0));
      });

      test('Sem script anonimo por padrao', () async {
        await page.coverage.startJSCoverage();
        await page.setContent(
            '<script>window.__inline = 1;</script><p>oi</p>');
        final entries = await page.coverage.stopJSCoverage();
        expect(entries.where((e) => e.url.isEmpty), isEmpty);
      });

      test('reportAnonymousScripts inclui o script inline', () async {
        await page.coverage.startJSCoverage(reportAnonymousScripts: true);
        await page.setContent(
            '<script>window.__inline = 1;</script><p>oi</p>');
        final entries = await page.coverage.stopJSCoverage();
        expect(entries.where((e) => e.url.isEmpty), isNotEmpty);
      });

      test('Depois de navegar, so o documento atual e reportado', () async {
        // Medido neste Chromium (151): `Profiler.takePreciseCoverage` so
        // devolve script que ainda esta vivo. Ao sair da pagina, o script do
        // documento anterior vira lixo e some do relatorio — e isso vale com
        // resetOnNavigation ligado ou desligado, porque quem descartou foi o
        // V8, nao o driver. O que a opcao controla e a escrituracao deste
        // lado: os ids e as fontes ja lidas. Ver o doc de
        // Coverage.startJSCoverage.
        await page.coverage.startJSCoverage(resetOnNavigation: false);
        await page.goto(server.url('/coverage'));
        await page.goto(server.url('/hello'));
        final entries = await page.coverage.stopJSCoverage();
        expect(entries.where((e) => e.url.endsWith('/coverage.js')), isEmpty);
      });

      test('Comecar duas vezes e recusado', () async {
        await page.coverage.startJSCoverage();
        expect(page.coverage.startJSCoverage(),
            throwsA(isA<PlaywrightException>()));
        await page.coverage.stopJSCoverage();
      });

      test('Parar sem comecar devolve lista vazia', () async {
        expect(await page.coverage.stopJSCoverage(), isEmpty);
      });

      // ----------------------------------------------- CSS coverage

      test('Deve reportar a folha de estilo com o texto e as faixas',
          () async {
        await page.coverage.startCSSCoverage();
        await page.goto(server.url('/coverage'));
        final entries = await page.coverage.stopCSSCoverage();

        final entry =
            entries.where((e) => e.url.endsWith('/coverage.css')).toList();
        expect(entry, hasLength(1));
        expect(entry.single.text, contains('#used'));
        expect(entry.single.ranges, isNotEmpty);

        // A regra usada esta dentro de uma faixa; a que nunca casou, nao.
        final text = entry.single.text;
        final usedOffset = text.indexOf('#used');
        final missingOffset = text.indexOf('#missing');
        bool covers(int offset) => entry.single.ranges
            .any((r) => r.start <= offset && offset < r.end);
        expect(covers(usedOffset), isTrue);
        expect(covers(missingOffset), isFalse);
      });

      test('CSS: parar sem comecar devolve lista vazia', () async {
        expect(await page.coverage.stopCSSCoverage(), isEmpty);
      });

      test('CSS: comecar duas vezes e recusado', () async {
        await page.coverage.startCSSCoverage();
        expect(page.coverage.startCSSCoverage(),
            throwsA(isA<PlaywrightException>()));
        await page.coverage.stopCSSCoverage();
      });
    });

    // ------------------------------------- o que os outros dois nao dao

    for (final browserName in ['firefox', 'webkit']) {
      group('[$browserName]', () {
        late Browser browser;
        var browserLaunched = false;

        setUpAll(() async {
          browser = browserName == 'firefox'
              ? await playwright.firefox.launch(headless: true)
              : await playwright.webkit.launch(headless: true);
          browserLaunched = true;
        });

        tearDownAll(() async {
          if (browserLaunched) await browser.close();
        });

        test('Deve recusar coverage dizendo por que', () async {
          final context = await browser.newContext();
          final page = await context.newPage();
          try {
            expect(
                () => page.coverage,
                throwsA(isA<UnsupportedError>().having((e) => e.message,
                    'message', contains('Chromium-only'))));
          } finally {
            await context.close();
          }
        });
      });
    }
  });
}
