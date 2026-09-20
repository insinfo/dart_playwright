import 'dart:async';

import 'package:playwright/playwright.dart';
import 'package:playwright/recorder.dart';
import 'package:test/test.dart';

import 'test_server.dart';

/// O recorder gravando de verdade, nos tres motores.
///
/// Os casos sao transcritos de `tests/library/inspector/cli-codegen-1.spec.ts`
/// e `-2.spec.ts` do upstream: clique com locator de role, `fill` num input
/// com label, checkbox, `select`, `press` e a navegacao que vira um `goto`
/// proprio. A prova nao e a string do seletor e sim o locator gerado, que e o
/// que o usuario le no arquivo.
///
/// A entrada e sempre a do protocolo (`page.click`, `page.fill`), nunca um
/// `el.click()` sintetico: o recorder da pagina ignora evento com
/// `isTrusted === false`, entao um teste que usasse JS nao gravaria nada.
void main() {
  group('Recorder', () {
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
        late Recorder recorder;
        late RecorderCollection collection;
        late Page page;

        Future<Browser> launch() {
          switch (browserName) {
            case 'chromium':
              return playwright.chromium.launch(headless: true);
            case 'firefox':
              return playwright.firefox.launch(headless: true);
            default:
              return playwright.webkit.launch(headless: true);
          }
        }

        setUpAll(() async {
          browser = await launch();
          browserLaunched = true;
        });

        setUp(() async {
          context = await browser.newContext();
          recorder = Recorder(context, isUnderTest: true);
          await recorder.install();
          collection = RecorderCollection(
            recorder: recorder,
            generatorId: 'dart-test',
            options: LanguageGeneratorOptions(browserName: browserName),
          );
          await recorder.setMode(RecorderMode.recording);
          page = await context.newPage();
          await page.goto(server.url('/recorder-page'));
          // O script da pagina so comeca a gravar depois do primeiro poll de
          // estado, que e quando ele sabe que o modo e `recording`.
          await _waitForRecordingMode(page);
        });

        tearDown(() async {
          await collection.dispose();
          await recorder.dispose();
          await context.close();
        });

        tearDownAll(() async {
          if (browserLaunched) await browser.close();
        });

        /// O codigo das acoes gravadas, sem o cabecalho nem o rodape.
        Future<List<String>> recordedActions() async {
          recorder.flushPendingActions();
          await Future<void>.delayed(const Duration(milliseconds: 100));
          return collection.generate().actionTexts;
        }

        test('Deve gravar um clique com o locator de role', () async {
          await page.click('#submit-button');
          expect(
              await recordedActions(),
              contains(contains(
                  "page.getByRole('button', name: 'Submit').click()")));
        });

        test('Deve gravar um fill com o locator de label', () async {
          await page.fill('#name', 'Isaque');
          expect(
              await recordedActions(),
              contains(contains(
                  "page.getByRole('textbox', name: 'Full name').fill('Isaque')")));
        });

        test('Deve juntar dois fills do mesmo campo num so', () async {
          await page.fill('#name', 'Isa');
          await page.fill('#name', 'Isaque');
          final actions = await recordedActions();
          final fills =
              actions.where((text) => text.contains('.fill(')).toList();
          expect(fills, hasLength(1));
          expect(fills.single, contains("fill('Isaque')"));
        });

        test('Deve gravar check e uncheck de um checkbox', () async {
          await page.locator('#agree').check();
          final afterCheck = await recordedActions();
          expect(afterCheck, contains(contains('.check()')));
        });

        test('Deve gravar select com o locator de test id', () async {
          await page.locator('#pet').selectOption('dog');
          expect(
              await recordedActions(),
              contains(contains(
                  "page.getByTestId('pet-picker').selectOption('dog')")));
        });

        test('Deve gravar uma tecla como press', () async {
          await page.locator('#name').press('Tab');
          expect(await recordedActions(), contains(contains(".press('Tab')")));
        });

        test('Deve virar goto quando a navegacao nao segue uma acao', () async {
          // A navegacao do setUp ainda esta represada: uma segunda navegacao
          // dentro da janela de 500ms substituiria a primeira em vez de virar
          // um goto novo, que e o que o upstream faz de proposito.
          await Future<void>.delayed(const Duration(milliseconds: 700));
          await page.goto(server.url('/text'));
          final actions = await recordedActions();
          expect(actions.where((text) => text.contains('page.goto(')).length,
              greaterThanOrEqualTo(2));
          expect(actions.last, contains(server.url('/text')));
        });

        test('Deve anexar a navegacao ao clique que a causou', () async {
          await page.click('#next');
          await page.waitForLoadState();
          final actions = await recordedActions();
          // O clique no link navega: upstream nao gera um `goto` para essa
          // navegacao, ela e apenas um sinal do clique.
          final gotos =
              actions.where((text) => text.contains('page.goto(')).toList();
          expect(gotos, hasLength(1));
          expect(gotos.single, contains('/recorder-page'));
          expect(actions, contains(contains("getByRole('link'")));
        });

        test('Deve escolher um locator com o modo inspecting', () async {
          await recorder.setMode(RecorderMode.inspecting);
          final picked = recorder.onElementPicked.first;
          // O modo `inspecting` consome o clique em vez de repassa-lo a
          // pagina, e responde com o seletor do elemento sob o cursor.
          await page.locator('#submit-button').hover();
          await page.click('#submit-button');
          final info = await picked.timeout(const Duration(seconds: 10));
          expect(info.selector, 'internal:role=button[name="Submit"i]');
          expect(asLocator(Languages.dart, info.selector),
              "getByRole('button', name: 'Submit')");
        });
      });
    }
  });
}

/// Espera a pagina confirmar que ja leu o estado `recording`.
///
/// O script injetado consulta o driver a cada segundo; sem esta espera o
/// primeiro clique de um teste pode chegar antes do primeiro poll e nao ser
/// gravado.
Future<void> _waitForRecordingMode(Page page) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (DateTime.now().isBefore(deadline)) {
    final mode = await page.evaluate(
        '() => window.__pwRecorder && window.__pwRecorder._recorder.state.mode');
    if (mode == 'recording') return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError('O recorder da pagina nao entrou em modo recording');
}
