import 'package:playwright/playwright.dart';
import 'package:test/test.dart';

import 'test_server.dart';

/// Parity coverage for `page.clock` on Chromium, Firefox and WebKit.
///
/// Almost every group starts from `install(epoch 0)` followed by
/// `pauseAt(1000)`, which is the shape upstream's own clock tests use: with
/// the clock paused nothing moves unless the test moves it, so the
/// assertions are on exact numbers instead of ranges. Without the pause the
/// clock keeps flowing at real speed after `install`, and a timer could fire
/// because the test host was slow rather than because time was advanced.
void main() {
  group('Clock', () {
    late Playwright playwright;
    late TestServer server;

    setUpAll(() async {
      server = await TestServer.start();
      playwright = await Playwright.create();
    });

    tearDownAll(() async {
      await server.stop();
    });

    DateTime at(int millis) => DateTime.fromMillisecondsSinceEpoch(millis);

    for (final browserName in ['chromium', 'firefox', 'webkit']) {
      group('[$browserName]', () {
        late Browser browser;
        var browserLaunched = false;
        late BrowserContext context;
        late Page page;
        late List<List<dynamic>> calls;

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
          page = await context.newPage();
          calls = <List<dynamic>>[];
          await page.exposeFunction('stub', (args) {
            calls.add(args);
            return null;
          });
        });

        tearDown(() async {
          await context.close();
        });

        tearDownAll(() async {
          if (browserLaunched) await browser.close();
        });

        Future<void> installPaused() async {
          await page.clock.install(time: at(0));
          await page.clock.pauseAt(at(1000));
        }

        // ------------------------------------------------------- runFor

        test('runFor(0) dispara um timer sem atraso', () async {
          await installPaused();
          await page.evaluate('() => { setTimeout(window.stub); }');
          await page.clock.runFor(Duration.zero);
          expect(calls, hasLength(1));
        });

        test('runFor nao dispara antes da hora', () async {
          await installPaused();
          await page.evaluate('() => { setTimeout(window.stub, 100); }');
          await page.clock.runFor(const Duration(milliseconds: 10));
          expect(calls, isEmpty);
        });

        test('runFor dispara quando o atraso e alcancado', () async {
          await installPaused();
          await page.evaluate('() => { setTimeout(window.stub, 100); }');
          await page.clock.runFor(const Duration(milliseconds: 100));
          expect(calls, hasLength(1));
        });

        test('runFor dispara timers simultaneos', () async {
          await installPaused();
          await page.evaluate('''() => {
            setTimeout(window.stub, 100);
            setTimeout(window.stub, 100);
            setTimeout(window.stub, 99);
          }''');
          await page.clock.runFor(const Duration(milliseconds: 100));
          expect(calls, hasLength(3));
        });

        test('runFor acumula entre chamadas', () async {
          await installPaused();
          await page.evaluate('() => { setTimeout(window.stub, 150); }');
          await page.clock.runFor(const Duration(milliseconds: 50));
          expect(calls, isEmpty);
          await page.clock.runFor(const Duration(milliseconds: 100));
          expect(calls, hasLength(1));
        });

        test('runFor move o Date enquanto os timers rodam', () async {
          await page.clock.install(time: at(0));
          await page.clock.pauseAt(at(1000));
          await page.clock.setSystemTime(at(0));
          await page.evaluate(
              '() => { setInterval(() => window.stub(new Date().getTime()), 10); }');
          await page.clock.runFor(const Duration(milliseconds: 100));
          expect(calls.map((c) => c.first).toList(),
              equals([10, 20, 30, 40, 50, 60, 70, 80, 90, 100]));
        });

        test('runFor com um intervalo dispara a cada periodo', () async {
          await installPaused();
          await page.evaluate('() => { setInterval(window.stub, 4000); }');
          await page.clock.runFor(const Duration(seconds: 8));
          expect(calls, hasLength(2));
        });

        // -------------------------------------------------- fastForward

        test('fastForward ignora os timers que nao venceriam', () async {
          await installPaused();
          await page.evaluate('''() => {
            setTimeout(() => window.stub('a'), 1000);
            setTimeout(() => window.stub('b'), 3000);
          }''');
          await page.clock.fastForward(const Duration(milliseconds: 500));
          expect(calls, isEmpty);
        });

        test('fastForward junta o intervalo numa unica chamada', () async {
          // Um intervalo de 1s durante um salto de 60s dispara uma vez, nao
          // sessenta: e exatamente essa a diferenca para runFor.
          await installPaused();
          await page.evaluate('() => { setInterval(window.stub, 1000); }');
          await page.clock.fastForward(const Duration(seconds: 60));
          expect(calls, hasLength(1));
        });

        test('runFor no mesmo intervalo dispara sessenta vezes', () async {
          await installPaused();
          await page.evaluate('() => { setInterval(window.stub, 1000); }');
          await page.clock.runFor(const Duration(seconds: 60));
          expect(calls, hasLength(60));
        });

        test('fastForward para o passado e recusado', () async {
          await installPaused();
          expect(() => page.clock.fastForward(const Duration(seconds: -5)),
              throwsA(isA<PlaywrightException>()));
        });

        // ------------------------------------------------ setFixedTime

        test('setFixedTime congela o relogio da parede', () async {
          await page.clock.setFixedTime(at(1500000000000));
          await page.goto(server.url('/hello'));
          expect(await page.evaluate('() => Date.now()'),
              equals(1500000000000));
          expect(await page.evaluate('() => new Date().getTime()'),
              equals(1500000000000));
        });

        test('setFixedTime vale tambem para um documento ja aberto', () async {
          await page.goto(server.url('/hello'));
          await page.clock.setFixedTime(at(1500000000000));
          expect(await page.evaluate('() => Date.now()'),
              equals(1500000000000));
        });

        test('setFixedTime pode ser trocado', () async {
          await page.goto(server.url('/hello'));
          await page.clock.setFixedTime(at(1000));
          expect(await page.evaluate('() => Date.now()'), equals(1000));
          await page.clock.setFixedTime(at(2000));
          expect(await page.evaluate('() => Date.now()'), equals(2000));
        });

        test('setFixedTime nao impede os timers de rodar', () async {
          // O relogio da parede fica parado, o contador monotonico nao: um
          // setTimeout real ainda dispara.
          await page.goto(server.url('/hello'));
          await page.clock.setFixedTime(at(1000));
          final fired = await page.evaluate(
              '() => new Promise(r => setTimeout(() => r(Date.now()), 30))');
          expect(fired, equals(1000));
        });

        // ------------------------------------------ install e navegacao

        test('install sobrevive a navegacao', () async {
          await page.clock.install(time: at(0));
          await page.clock.pauseAt(at(2000));
          await page.goto(server.url('/hello'));
          expect(await page.evaluate('() => Date.now()'), equals(2000));
          await page.goto(server.url('/init-probe'));
          expect(await page.evaluate('() => Date.now()'), equals(2000));
        });

        test('install alcanca os frames filhos', () async {
          await page.clock.install(time: at(0));
          await page.clock.pauseAt(at(2000));
          await page.goto(server.url('/init-frames'));
          final child = page.frame(name: 'init-child');
          expect(child, isNotNull);
          expect(await child!.evaluate('() => Date.now()'), equals(2000));
        });

        test('install alcanca uma pagina criada depois', () async {
          await page.clock.install(time: at(0));
          await page.clock.pauseAt(at(2000));
          final other = await context.newPage();
          await other.goto(server.url('/hello'));
          expect(await other.evaluate('() => Date.now()'), equals(2000));
          await other.close();
        });

        test('install de novo recomeca o relogio na hora pedida', () async {
          // O guarda contra dois relogios falsos empilhados e no script
          // injetado, contra ele rodar duas vezes no mesmo documento; chamar
          // install de novo pelo driver so reposiciona o tempo.
          await page.clock.install(time: at(0));
          await page.clock.pauseAt(at(1000));
          await page.goto(server.url('/hello'));
          expect(await page.evaluate('() => Date.now()'), equals(1000));
          await page.clock.install(time: at(50000));
          expect(await page.evaluate('() => Date.now()'), equals(50000));
        });

        // ------------------------------------------ pauseAt e resume

        test('pauseAt para o tempo no instante pedido', () async {
          await page.clock.install(time: at(0));
          await page.clock.pauseAt(at(5000));
          await page.goto(server.url('/hello'));
          final first = await page.evaluate('() => Date.now()');
          await Future<void>.delayed(const Duration(milliseconds: 200));
          final second = await page.evaluate('() => Date.now()');
          expect(first, equals(5000));
          expect(second, equals(5000));
        });

        test('resume volta a deixar o tempo correr', () async {
          await page.clock.install(time: at(0));
          await page.clock.pauseAt(at(5000));
          await page.goto(server.url('/hello'));
          await page.clock.resume();
          await Future<void>.delayed(const Duration(milliseconds: 300));
          final now = await page.evaluate('() => Date.now()') as num;
          expect(now, greaterThan(5000));
        });

        test('pauseAt dispara os timers vencidos no caminho', () async {
          await page.clock.install(time: at(0));
          await page.goto(server.url('/hello'));
          await page.evaluate('() => { setTimeout(window.stub, 1000); }');
          await page.clock.pauseAt(at(10000));
          expect(calls, hasLength(1));
        });

        // ------------------------------------------------- performance

        test('performance.now segue o relogio', () async {
          await page.clock.install(time: at(0));
          await page.clock.pauseAt(at(1000));
          await page.goto(server.url('/hello'));
          final before = await page.evaluate('() => performance.now()') as num;
          await page.clock.runFor(const Duration(milliseconds: 500));
          final after = await page.evaluate('() => performance.now()') as num;
          expect(after - before, equals(500));
        });

        // -------------------------------------- requestAnimationFrame

        test('requestAnimationFrame dispara ao avancar o tempo', () async {
          await installPaused();
          await page.evaluate(
              '() => { requestAnimationFrame(t => window.stub(t)); }');
          await page.clock.runFor(const Duration(milliseconds: 20));
          expect(calls, hasLength(1));
          expect(calls.first.first, isA<num>());
        });
      });
    }
  });
}
