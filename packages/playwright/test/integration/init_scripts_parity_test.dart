import 'dart:async';

import 'package:playwright/playwright.dart';
import 'package:test/test.dart';

import 'test_server.dart';

/// Parity coverage for `addInitScript`, `exposeFunction` and `exposeBinding`,
/// on Chromium, Firefox and WebKit.
///
/// The init-script assertions never read a value the test itself set from
/// outside: they read `window.__seenInHead`, which the *page's own* first
/// inline script recorded while `<head>` was parsing. A value there can only
/// have come from a script that ran before the document's, which is the whole
/// claim being made. Reading `window.__seed` afterwards would prove nothing —
/// an init script that ran late would look identical.
void main() {
  group('addInitScript, exposeFunction e exposeBinding', () {
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
        });

        tearDown(() async {
          await context.close();
        });

        tearDownAll(() async {
          if (browserLaunched) await browser.close();
        });

        // -------------------------------------------------- addInitScript

        test('Deve rodar antes dos scripts da propria pagina', () async {
          await page.addInitScript('window.__seed = "from-init";');
          await page.goto(server.url('/init-probe'));
          expect(await page.evaluate('() => window.__seenInHead'),
              equals('from-init'));
          expect(await page.evaluate('() => window.__seenInBody'),
              equals('from-init'));
          expect(
              await page
                  .evaluate('() => document.getElementById("out").textContent'),
              equals('from-init'));
        });

        test('Deve aceitar uma funcao com argumento', () async {
          await page.addInitScript('(value) => { window.__seed = value.tag; }',
              arg: {'tag': 'argumento'});
          await page.goto(server.url('/init-probe'));
          expect(await page.evaluate('() => window.__seenInHead'),
              equals('argumento'));
        });

        test('Deve rodar de novo a cada navegacao', () async {
          await page.addInitScript('window.__seed = "persistente";');
          await page.goto(server.url('/init-probe'));
          await page.goto(server.url('/hello'));
          await page.goto(server.url('/init-probe'));
          expect(await page.evaluate('() => window.__seenInHead'),
              equals('persistente'));
        });

        test('Deve rodar tambem nos frames filhos', () async {
          await page.addInitScript('window.__seed = "em-todo-frame";');
          await page.goto(server.url('/init-frames'));
          final child = page.frame(name: 'init-child');
          expect(child, isNotNull);
          expect(await child!.evaluate('() => window.__seenInHead'),
              equals('em-todo-frame'));
        });

        test('Nao deve tocar no documento ja aberto', () async {
          await page.goto(server.url('/init-probe'));
          await page.addInitScript('window.__seed = "tarde-demais";');
          // O documento atual continua exatamente como estava: nem a variavel
          // do init script existe nele.
          expect(await page.evaluate('() => window.__seed'), isNull);
          expect(await page.evaluate('() => window.__seenInHead'), isNull);
        });

        test('Deve preservar a ordem em que foram adicionados', () async {
          await page.addInitScript('window.__seed = "primeiro";');
          await page
              .addInitScript('window.__seed = window.__seed + "-depois";');
          await page.goto(server.url('/init-probe'));
          expect(await page.evaluate('() => window.__seenInHead'),
              equals('primeiro-depois'));
        });

        test('Cada script tem escopo proprio', () async {
          // Dois scripts declarando o mesmo `const` no topo: sem o IIFE por
          // script, o segundo quebraria com "already been declared" e o
          // primeiro nunca teria efeito.
          await page
              .addInitScript('const marca = "um"; window.__seed = marca;');
          await page.addInitScript(
              'const marca = "dois"; window.__seed = window.__seed + marca;');
          await page.goto(server.url('/init-probe'));
          expect(await page.evaluate('() => window.__seenInHead'),
              equals('umdois'));
        });

        test('Argumento sem funcao e recusado', () async {
          expect(() => page.addInitScript('window.__seed = 1;', arg: 7),
              throwsA(isA<ArgumentError>()));
        });

        // ----------------------------------- addInitScript no contexto

        test('Script do contexto alcanca pagina criada depois', () async {
          await context.addInitScript('window.__seed = "do-contexto";');
          final other = await context.newPage();
          await other.goto(server.url('/init-probe'));
          expect(await other.evaluate('() => window.__seenInHead'),
              equals('do-contexto'));
          await other.close();
        });

        test('Script do contexto alcanca pagina que ja existia', () async {
          await context.addInitScript('window.__seed = "retroativo";');
          await page.goto(server.url('/init-probe'));
          expect(await page.evaluate('() => window.__seenInHead'),
              equals('retroativo'));
        });

        test('Script do contexto roda antes do script da pagina', () async {
          await context.addInitScript('window.__seed = "contexto";');
          await page
              .addInitScript('window.__seed = window.__seed + "-pagina";');
          await page.goto(server.url('/init-probe'));
          expect(await page.evaluate('() => window.__seenInHead'),
              equals('contexto-pagina'));
        });

        // -------------------------------------------------- exposeFunction

        test('Funcao exposta antes do goto responde na pagina', () async {
          await page.exposeFunction(
              'somar', (args) => (args[0] as num) + (args[1] as num));
          await page.goto(server.url('/init-probe'));
          expect(await page.evaluate('() => window.somar(2, 40)'), equals(42));
        });

        test('Funcao exposta depois do goto responde no documento aberto',
            () async {
          await page.goto(server.url('/init-probe'));
          await page.exposeFunction(
              'gritar', (args) => '${args[0]}'.toUpperCase());
          expect(
              await page.evaluate('() => window.gritar("oi")'), equals('OI'));
        });

        test('Funcao exposta sobrevive a navegacao', () async {
          await page.exposeFunction('eco', (args) => args[0]);
          await page.goto(server.url('/init-probe'));
          await page.goto(server.url('/hello'));
          expect(await page.evaluate('() => window.eco("depois")'),
              equals('depois'));
        });

        test('Funcao exposta aceita callback assincrono', () async {
          await page.exposeFunction('devagar', (args) async {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            return {'recebido': args};
          });
          await page.goto(server.url('/hello'));
          final result = await page.evaluate(
              '() => window.devagar(1, "dois").then(r => JSON.stringify(r))');
          expect(result, equals('{"recebido":[1,"dois"]}'));
        });

        test('Erro do callback vira rejeicao na pagina', () async {
          await page.exposeFunction('explodir', (args) {
            throw StateError('estourou de proposito');
          });
          await page.goto(server.url('/hello'));
          final message = await page.evaluate('''
            () => window.explodir().then(
                () => 'resolveu',
                (error) => 'rejeitou: ' + error.message)
          ''');
          expect(message, startsWith('rejeitou:'));
          expect(message, contains('estourou de proposito'));
        });

        test('Resultado que nao vira JSON tambem rejeita', () async {
          // Um objeto Dart que jsonEncode nao sabe converter. A promessa da
          // pagina precisa ser rejeitada: se o erro sumisse no manipulador de
          // evento, o `await` na pagina ficaria pendurado para sempre.
          await page.exposeFunction('naoSerializa', (args) => Object());
          await page.goto(server.url('/hello'));
          final message = await page.evaluate('''
            () => window.naoSerializa().then(
                () => 'resolveu',
                (error) => 'rejeitou')
          ''').timeout(const Duration(seconds: 15));
          expect(message, equals('rejeitou'));
        });

        test('Funcao nao exposta nao existe na pagina', () async {
          await page.goto(server.url('/hello'));
          expect(await page.evaluate('() => typeof window.inexistente'),
              equals('undefined'));
        });

        test('Nome repetido e recusado', () async {
          await page.exposeFunction('unico', (args) => 1);
          expect(() => page.exposeFunction('unico', (args) => 2),
              throwsA(isA<PlaywrightException>()));
        });

        test('Nome ja exposto no contexto e recusado na pagina', () async {
          await context.exposeFunction('doContexto', (args) => 1);
          expect(() => page.exposeFunction('doContexto', (args) => 2),
              throwsA(isA<PlaywrightException>()));
        });

        // -------------------------------------------------- exposeBinding

        test('Binding recebe a pagina e o frame que chamou', () async {
          String? frameUrl;
          Page? seenPage;
          await page.exposeBinding('quemChamou', (source, args) {
            seenPage = source.page;
            frameUrl = source.frame?.url();
            return 'ok';
          });
          await page.goto(server.url('/init-frames'));
          expect(
              await page.evaluate('() => window.quemChamou()'), equals('ok'));
          expect(seenPage, same(page));
          expect(frameUrl, equals(server.url('/init-frames')));
        });

        test('Binding chamado de dentro de um frame filho identifica o frame',
            () async {
          final frameUrls = <String?>[];
          await page.exposeBinding('registrar', (source, args) {
            frameUrls.add(source.frame?.url());
            return true;
          });
          await page.goto(server.url('/init-frames'));
          final child = page.frame(name: 'init-child');
          expect(child, isNotNull);
          await child!.evaluate('() => window.registrar()');
          expect(frameUrls, equals([server.url('/init-probe')]));
        });

        // ------------------------------------- exposeFunction no contexto

        test('Funcao do contexto alcanca pagina criada depois', () async {
          await context.exposeFunction(
              'dobrar', (args) => (args[0] as num) * 2);
          final other = await context.newPage();
          await other.goto(server.url('/hello'));
          expect(await other.evaluate('() => window.dobrar(21)'), equals(42));
          await other.close();
        });

        test('Funcao do contexto alcanca pagina que ja existia', () async {
          await context.exposeFunction(
              'triplicar', (args) => (args[0] as num) * 3);
          await page.goto(server.url('/hello'));
          expect(await page.evaluate('() => window.triplicar(14)'), equals(42));
        });
      });
    }
  });
}
