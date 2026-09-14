import 'package:test/test.dart';
import 'package:playwright/playwright.dart';
import 'test_server.dart';

/// Parity tests for the frame-aware API: `Frame`, `FrameLocator`, the
/// `getBy*` engines and the `Locator` surface they all share.
///
/// Every assertion drives a real browser; nothing here checks that a method
/// merely exists.
void main() {
  group('Locator, Frame e FrameLocator', () {
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
        });

        tearDown(() async {
          await context.close();
        });

        tearDownAll(() async {
          if (browserLaunched) await browser.close();
        });

        /// The frames of /frames settle asynchronously; wait for the whole
        /// tree instead of sleeping.
        Future<void> gotoFramesPage() async {
          await page.goto(server.url('/frames'));
          await page.waitForFunction(
              '() => document.querySelectorAll("iframe").length === 2');
          await page
              .frameLocator('#one')
              .locator('#label')
              .waitFor(timeout: const Duration(seconds: 10));
          await page
              .frameLocator('#one')
              .frameLocator('#deep')
              .locator('#label')
              .waitFor(timeout: const Duration(seconds: 10));
        }

        // ------------------------------------------------------------ Frame

        test('Deve expor a arvore de frames com pais e filhos', () async {
          await gotoFramesPage();

          final frames = page.frames();
          expect(frames.length, equals(4),
              reason: 'main + frame-one + frame-two + frame-nested');

          final main = page.mainFrame();
          expect(main.parentFrame(), isNull);
          expect(main.childFrames().length, equals(2));

          final one = frames.firstWhere((f) => f.url().endsWith('/frame-one'));
          expect(one.parentFrame()!.url(), equals(main.url()));
          expect(one.childFrames().length, equals(1));
          expect(one.childFrames().single.url(), endsWith('/frame-nested'));
          expect(one.isDetached(), isFalse);
        });

        test('Deve avaliar no contexto de cada frame, nao no da pagina',
            () async {
          await gotoFramesPage();

          final one = page.frames()
              .firstWhere((f) => f.url().endsWith('/frame-one'));
          final two = page.frames()
              .firstWhere((f) => f.url().endsWith('/frame-two'));

          expect(await page.mainFrame().title(), equals('Frames Host'));
          expect(await one.title(), equals('Frame One'));
          expect(await two.title(), equals('Frame Two'));

          expect(
              await one.evaluate(
                  '() => document.getElementById("label").textContent'),
              equals('inside frame one'));
          expect(
              await two.evaluate(
                  '() => document.getElementById("label").textContent'),
              equals('inside frame two'));

          // The main frame must not see the child documents.
          expect(
              await page.evaluate('() => !!document.getElementById("label")'),
              isFalse);
        });

        test('Deve localizar dentro do frame com Frame.locator', () async {
          await gotoFramesPage();
          final one = page.frames()
              .firstWhere((f) => f.url().endsWith('/frame-one'));
          expect(await one.locator('#label').textContent(),
              equals('inside frame one'));
          expect(await one.locator('#label').count(), equals(1));
        });

        test('Deve clicar dentro de um frame com evento confiavel', () async {
          await gotoFramesPage();
          final one = page.frames()
              .firstWhere((f) => f.url().endsWith('/frame-one'));

          await one.locator('#go').click();
          // Records event.isTrusted: only real protocol input passes, and the
          // click point had to be shifted by the iframe's border box.
          expect(await one.evaluate('() => window.__clickedInFrame'), isTrue);
        });

        test('Deve clicar em frame aninhado com evento confiavel', () async {
          await gotoFramesPage();
          final deep = page.frames()
              .firstWhere((f) => f.url().endsWith('/frame-nested'));

          await deep.locator('#deepButton').click();
          expect(await deep.evaluate('() => window.__deepClicked'), isTrue);
        });

        test('Deve preencher input dentro de um frame', () async {
          await gotoFramesPage();
          final one = page.frames()
              .firstWhere((f) => f.url().endsWith('/frame-one'));

          await one.fill('#field', 'digitado');
          expect(await one.locator('#field').inputValue(), equals('digitado'));
          expect(await one.evaluate('() => window.__inputInFrame'), isTrue);
        });

        test('Deve navegar apenas o frame com Frame.goto', () async {
          await gotoFramesPage();
          final two = page.frames()
              .firstWhere((f) => f.url().endsWith('/frame-two'));

          await two.goto(server.url('/text'));
          expect(await two.locator('#content').textContent(),
              equals('Hello, World!'));
          // The host page did not navigate.
          expect(await page.url(), endsWith('/frames'));
          expect(await page.mainFrame().title(), equals('Frames Host'));
        });

        test('Deve substituir o documento do frame com setContent', () async {
          await gotoFramesPage();
          final two = page.frames()
              .firstWhere((f) => f.url().endsWith('/frame-two'));

          await two.setContent('<html><body><p id="p">novo</p></body></html>');
          expect(await two.locator('#p').textContent(), equals('novo'));
          expect(await two.content(), contains('novo'));
          expect(await page.content(), isNot(contains('novo')));
        });

        test('Deve marcar o frame como detached ao remover o iframe',
            () async {
          await gotoFramesPage();
          final two = page.frames()
              .firstWhere((f) => f.url().endsWith('/frame-two'));
          expect(two.isDetached(), isFalse);

          await page.evaluate(
              '() => document.getElementById("two").remove()');
          await page.waitForFunction(
              '() => document.querySelectorAll("iframe").length === 1');
          // The detach event may land slightly after the DOM mutation.
          for (var i = 0; i < 50 && !two.isDetached(); i++) {
            await page.waitForTimeout(const Duration(milliseconds: 50));
          }

          expect(two.isDetached(), isTrue);
          expect(page.frames().length, equals(3));
        });

        test('Deve encontrar frame por nome e por url', () async {
          await gotoFramesPage();

          final byName = page.frame(name: 'frame-two');
          expect(byName, isNotNull);
          expect(byName!.url(), endsWith('/frame-two'));

          final byUrl = page.frame(url: RegExp(r'/frame-nested$'));
          expect(byUrl, isNotNull);
          expect(await byUrl!.title(), equals('Frame Nested'));

          expect(page.frame(name: 'nao-existe'), isNull);
        });

        test('Deve aguardar seletor dentro do frame', () async {
          await gotoFramesPage();
          final one = page.frames()
              .firstWhere((f) => f.url().endsWith('/frame-one'));

          final handle = await one.waitForSelector('#go');
          expect(handle, isNotNull);
          expect(await handle!.textContent(), equals('Go one'));
        });

        // ----------------------------------------------------- FrameLocator

        test('Deve resolver FrameLocator em iframe simples', () async {
          await gotoFramesPage();
          expect(
              await page.frameLocator('#one').locator('#label').textContent(),
              equals('inside frame one'));
          expect(
              await page.frameLocator('#two').locator('#label').textContent(),
              equals('inside frame two'));
        });

        test('Deve encadear FrameLocator em iframe aninhado', () async {
          await gotoFramesPage();
          final deep =
              page.frameLocator('#one').frameLocator('#deep').locator('#label');
          expect(await deep.textContent(), equals('deeply nested'));
        });

        test('Deve clicar via FrameLocator com getByRole', () async {
          await gotoFramesPage();
          await page
              .frameLocator('#one')
              .getByRole('button', name: 'Go one')
              .click();
          final one = page.frames()
              .firstWhere((f) => f.url().endsWith('/frame-one'));
          expect(await one.evaluate('() => window.__clickedInFrame'), isTrue);
        });

        test('Deve selecionar frames por indice com FrameLocator.nth',
            () async {
          await gotoFramesPage();
          expect(
              await page
                  .frameLocator('iframe')
                  .nth(1)
                  .locator('#label')
                  .textContent(),
              equals('inside frame two'));
          expect(
              await page
                  .frameLocator('iframe')
                  .first
                  .locator('#label')
                  .textContent(),
              equals('inside frame one'));
        });

        test('Deve expor o iframe dono e converter Locator em FrameLocator',
            () async {
          await gotoFramesPage();

          final owner = page.frameLocator('#one').owner;
          expect(await owner.getAttribute('name'), equals('frame-one'));

          final viaContentFrame =
              page.locator('#two').contentFrame().locator('#label');
          expect(await viaContentFrame.textContent(),
              equals('inside frame two'));
        });

        test('Deve estourar timeout quando o iframe nunca aparece', () async {
          await page.goto(server.url('/hello'));
          await expectLater(
              page
                  .frameLocator('#nao-existe')
                  .locator('#x')
                  .textContent(timeout: const Duration(seconds: 1)),
              throwsA(isA<TimeoutException>()));
        });

        // --------------------------------------------------------- getBy*

        test('Deve localizar por papel ARIA com nome acessivel', () async {
          await page.goto(server.url('/semantics'));

          expect(
              await page
                  .getByRole('button', name: 'Save', exact: true)
                  .getAttribute('id'),
              equals('save'));
          // Sem exact, o nome e substring: dois botoes casam.
          expect(await page.getByRole('button', name: 'Save').count(),
              equals(2));
          // aria-label vence o conteudo.
          expect(await page.getByRole('button', name: 'Fechar').getAttribute('id'),
              equals('close'));
          // Nome vindo do <label for>.
          expect(
              await page
                  .getByRole('textbox', name: 'Username')
                  .getAttribute('id'),
              equals('user'));
        });

        test('Deve filtrar papel por nivel, estado e desabilitado', () async {
          await page.goto(server.url('/semantics'));

          expect(await page.getByRole('heading', level: 1).textContent(),
              equals('Pagina de semantica'));
          expect(await page.getByRole('heading', level: 2).textContent(),
              equals('Secao dois'));
          expect(await page.getByRole('heading').count(), equals(2));

          expect(await page.getByRole('checkbox', checked: true).getAttribute('id'),
              equals('agree'));
          expect(
              await page.getByRole('checkbox', checked: false).getAttribute('id'),
              equals('news'));

          expect(
              await page
                  .getByRole('button', disabled: true)
                  .getAttribute('id'),
              equals('disabledBtn'));

          // <nav aria-label="Principal"> => role navigation.
          expect(await page.getByRole('navigation', name: 'Principal').count(),
              equals(1));
          expect(await page.getByRole('link', name: 'hello').count(), equals(1));
          // <input type=search> mapeia para searchbox, nao textbox.
          expect(await page.getByRole('searchbox').getAttribute('id'),
              equals('search'));
        });

        test('Deve localizar por texto com normalizacao de espaco', () async {
          await page.goto(server.url('/semantics'));

          // O elemento tem uma quebra de linha e varios espacos; o motor
          // normaliza antes de comparar, como o upstream.
          expect(await page.getByText('Hello world', exact: true).getAttribute('id'),
              equals('spaced'));
          // Sem exact, substring e case-insensitive.
          expect(await page.getByText('hello WORLD').getAttribute('id'),
              equals('spaced'));
          // Exact com texto parcial nao casa.
          expect(await page.getByText('Hello', exact: true).count(), equals(0));
          // Expressao regular casa contra o texto cru.
          expect(await page.getByText(RegExp(r'^Alpha$')).count(), equals(1));
        });

        test('Deve localizar por label, placeholder, alt, title e testId',
            () async {
          await page.goto(server.url('/semantics'));

          expect(await page.getByLabel('Username').getAttribute('id'),
              equals('user'));
          // Label que envolve o controle.
          expect(await page.getByLabel('Password').getAttribute('id'),
              equals('pass'));
          expect(await page.getByPlaceholder('Search here').getAttribute('id'),
              equals('search'));
          expect(await page.getByAltText('A cat').getAttribute('id'),
              equals('cat'));
          expect(await page.getByTitle('Tooltip text').getAttribute('id'),
              equals('tip'));
          expect(await page.getByTestId('submit').textContent(),
              equals('Enviar'));

          // exact: por padrao os motores de atributo fazem substring
          // case-insensitive.
          expect(await page.getByPlaceholder('search').count(), equals(1));
          expect(
              await page.getByPlaceholder('search', exact: true).count(),
              equals(0));
        });

        test('Deve clicar via getByRole com evento confiavel', () async {
          await page.goto(server.url('/semantics'));
          await page.getByRole('button', name: 'Save', exact: true).click();
          expect(await page.evaluate('() => window.__savedTrusted'), isTrue);
        });

        // -------------------------------------------------------- Locator

        test('Deve compor locators com first, last, nth e filter', () async {
          await page.goto(server.url('/semantics'));

          final rows = page.locator('.row');
          expect(await rows.count(), equals(3));
          expect(await rows.first.textContent(), equals('Alpha'));
          expect(await rows.last.textContent(), equals('Gamma'));
          expect(await rows.nth(1).textContent(), equals('Beta'));
          expect(await rows.nth(-1).textContent(), equals('Gamma'));

          expect(await rows.filter(hasText: 'Bet').textContent(),
              equals('Beta'));
          expect(await rows.filter(hasNotText: 'a').count(), equals(0));
          expect((await rows.all()).length, equals(3));
        });

        test('Deve combinar locators com and e or', () async {
          await page.goto(server.url('/semantics'));

          final saveButtons = page.getByRole('button', name: 'Save');
          final exactSave = page.locator('#save');
          expect(await saveButtons.and(exactSave).count(), equals(1));

          expect(
              await page.locator('#save').or(page.locator('#close')).count(),
              equals(2));
        });

        test('Deve violar o modo strict quando o seletor casa varios',
            () async {
          await page.goto(server.url('/semantics'));

          await expectLater(
              page.locator('.row').textContent(),
              throwsA(isA<StrictModeViolation>()));
          // Com strict desligado vale o primeiro.
          expect(await page.locator('.row').textContent(strict: false),
              equals('Alpha'));
          // E o locator indexado resolve um so.
          expect(await page.locator('.row').first.textContent(),
              equals('Alpha'));
        });

        test('Deve esperar automaticamente elemento que aparece e estabiliza',
            () async {
          await page.goto(server.url('/late'));

          // Sem waitForSelector: o click espera aparecer, ficar visivel e
          // parar de se mover.
          await page.locator('#later').click();

          expect(await page.evaluate('() => window.__lateClicked'), isTrue);
          // The click landed inside the button's box as it was at click time.
          // That is the property stability protects, and it holds whatever
          // the animation was doing.
          //
          // Asserting that the animation had *finished* (left >= 60) was
          // wrong: a loaded macOS runner throttles the page's setInterval, the
          // button then genuinely stops moving part-way, and the element is
          // stable by any definition while the test still expected the end
          // position. The click was correct; the assertion was not.
          expect(await page.evaluate('() => window.__lateHit'), isTrue);
        });

        test('Deve respeitar timeout e force nas acoes', () async {
          await page.goto(server.url('/semantics'));

          await expectLater(
              page
                  .locator('#nao-existe')
                  .click(timeout: const Duration(milliseconds: 300)),
              throwsA(isA<TimeoutException>()));

          // O botao desabilitado nunca fica actionable...
          await expectLater(
              page
                  .locator('#disabledBtn')
                  .click(timeout: const Duration(milliseconds: 500)),
              throwsA(isA<TimeoutException>()));
          // ...mas force pula as verificacoes de actionability.
          await page
              .locator('#disabledBtn')
              .click(force: true, timeout: const Duration(seconds: 5));
        });

        test('Deve expor estado, caixa e semantica do elemento', () async {
          await page.goto(server.url('/semantics'));

          expect(await page.locator('#agree').isChecked(), isTrue);
          expect(await page.locator('#news').isChecked(), isFalse);
          expect(await page.locator('#disabledBtn').isDisabled(), isTrue);
          expect(await page.locator('#user').isEditable(), isTrue);
          expect(await page.locator('#save').isVisible(), isTrue);
          expect(await page.locator('#nao-existe').isVisible(), isFalse);

          final box = await page.locator('#cat').boundingBox();
          expect(box, isNotNull);
          expect(box!.width, closeTo(20, 1));
          expect(box.height, closeTo(20, 1));

          expect(await page.locator('#save').ariaRole(), equals('button'));
          expect(await page.locator('#user').ariaRole(), equals('textbox'));
          expect(await page.locator('#close').accessibleName(),
              equals('Fechar'));
          expect(await page.locator('#user').accessibleName(),
              equals('Username'));
        });

        test('Deve alternar checkbox com check, uncheck e setChecked',
            () async {
          await page.goto(server.url('/semantics'));
          final news = page.locator('#news');

          await news.check();
          expect(await news.isChecked(), isTrue);
          await news.check(); // idempotente
          expect(await news.isChecked(), isTrue);
          await news.uncheck();
          expect(await news.isChecked(), isFalse);
          await news.setChecked(true);
          expect(await news.isChecked(), isTrue);
        });

        test('Deve avaliar contra o elemento e contra todos os casamentos',
            () async {
          await page.goto(server.url('/semantics'));

          expect(await page.locator('#save').evaluate('(el) => el.tagName'),
              equals('BUTTON'));
          expect(
              await page
                  .locator('.row')
                  .evaluateAll('(els) => els.map(e => e.textContent)'),
              equals(['Alpha', 'Beta', 'Gamma']));

          final handle = await page.locator('#save').elementHandle();
          expect(await handle.textContent(), equals('Save'));
          expect(await handle.getAttribute('id'), equals('save'));
          expect(await handle.isVisible(), isTrue);

          expect((await page.locator('.row').elementHandles()).length,
              equals(3));
        });

        test('Deve aguardar estados hidden e detached', () async {
          await page.goto(server.url('/semantics'));

          await page.evaluate('''
            () => setTimeout(() => {
              document.getElementById('save').style.display = 'none';
            }, 200)
          ''');
          await page.locator('#save').waitFor(
              state: WaitForSelectorState.hidden,
              timeout: const Duration(seconds: 5));
          expect(await page.locator('#save').isVisible(), isFalse);

          await page.evaluate('''
            () => setTimeout(() => document.getElementById('close').remove(), 200)
          ''');
          await page.locator('#close').waitFor(
              state: WaitForSelectorState.detached,
              timeout: const Duration(seconds: 5));
          expect(await page.locator('#close').count(), equals(0));
        });

        test('Deve arrastar com dragTo usando o mouse do protocolo', () async {
          await page.goto(server.url('/drag'));

          await page.locator('#source').dragTo(page.locator('#target'));

          expect(await page.evaluate('() => window.__downTrusted'), isTrue);
          expect(await page.evaluate('() => window.__overTarget'), isTrue);
          expect(await page.evaluate('() => window.__dropped'), isTrue);
          // A movimentacao passou por varios passos intermediarios, nao um
          // salto unico.
          expect(await page.evaluate('() => window.__moves') as num,
              greaterThan(3));
        });

        test('Deve expor o mouse da pagina com move, down e up', () async {
          await page.goto(server.url('/drag'));
          final mouse = page.mouse;

          await mouse.move(35, 35);
          await mouse.down();
          await mouse.move(240, 240, steps: 4);
          await mouse.up();

          expect(await page.evaluate('() => window.__downTrusted'), isTrue);
          expect(await page.evaluate('() => window.__dropped'), isTrue);
          expect(mouse.x, closeTo(240, 0.01));
          expect(mouse.y, closeTo(240, 0.01));
        });

        test('Deve rolar a pagina com mouse.wheel', () async {
          await page.goto(server.url('/drag'));
          await page.mouse.move(150, 150);
          await page.mouse.wheel(0, 400);
          await page.waitForFunction('() => window.scrollY > 0',
              timeout: const Duration(seconds: 5));
          expect(await page.evaluate('() => window.scrollY') as num,
              greaterThan(0));
        });

        test('Deve expor o iframe dono com Frame.frameElement', () async {
          await gotoFramesPage();

          expect(await page.mainFrame().frameElement(), isNull);

          final one = page.frames()
              .firstWhere((f) => f.url().endsWith('/frame-one'));
          final owner = await one.frameElement();
          expect(owner, isNotNull);
          expect(await owner!.getAttribute('id'), equals('one'));
        });

        test('Deve expor os atalhos de DOM antigo do Frame', () async {
          await page.goto(server.url('/semantics'));
          final main = page.mainFrame();

          final save = await main.querySelector('#save');
          expect(save, isNotNull);
          expect(await save!.textContent(), equals('Save'));
          expect(await main.querySelector('#nao-existe'), isNull);

          expect((await main.querySelectorAll('.row')).length, equals(3));
          expect(await main.evalOnSelector('#save', '(el) => el.id'),
              equals('save'));
          expect(
              await main.evalOnSelectorAll(
                  '.row', '(els) => els.map(e => e.textContent).join(",")'),
              equals('Alpha,Beta,Gamma'));

          await main.evaluate(
              '() => { window.__custom = false; document.getElementById("save")'
              '.addEventListener("custom", () => { window.__custom = true; }); }');
          await main.dispatchEvent('#save', 'custom');
          expect(await main.evaluate('() => window.__custom'), isTrue);
        });

        test('Deve aceitar seletores encadeados com >> e prefixos', () async {
          await page.goto(server.url('/semantics'));

          expect(await page.locator('ul >> .row').count(), equals(3));
          expect(await page.locator('css=#save').textContent(), equals('Save'));
          expect(
              await page.locator('//button[@id="save"]').textContent(),
              equals('Save'));
          expect(await page.locator('text="Beta"').count(), equals(1));
        });

        // ------------------------------------------------- hit target

        test('Deve recusar clique em elemento coberto por overlay', () async {
          await page.goto(server.url('/occluded'));
          await expectLater(
            page
                .locator('#target')
                .click(timeout: const Duration(milliseconds: 800)),
            throwsA(isA<TimeoutException>()),
          );
          expect(await page.evaluate('() => window.__hit'), isFalse);
        });

        test('force deve pular a verificacao de hit target', () async {
          await page.goto(server.url('/occluded'));
          // The overlay swallows the real click, so the button never fires;
          // what `force` proves is that the check is skipped and the action
          // is dispatched instead of timing out.
          await page
              .locator('#target')
              .click(force: true, timeout: const Duration(seconds: 5));
        });

        test('Deve clicar assim que o overlay sai da frente', () async {
          await page.goto(server.url('/occluded'));
          final click = page
              .locator('#target')
              .click(timeout: const Duration(seconds: 15));
          await page.evaluate('() => setTimeout(() => window.uncover(), 200)');
          await click;
          expect(await page.evaluate('() => window.__hit'), isTrue);
        });

      });
    }
  });
}
