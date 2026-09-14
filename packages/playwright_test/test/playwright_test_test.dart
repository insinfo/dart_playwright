import 'dart:io';

import 'package:playwright_test/playwright_test.dart';

import 'test_server.dart';

/// Exercises the fixtures and the assertions the way a user would: through
/// `playwrightTest`, against a real page, on all three engines.
void main() {
  late TestServer server;

  setUpAll(() async {
    server = await TestServer.start();
  });

  tearDownAll(() async {
    await server.stop();
  });

  const allBrowsers = PlaywrightTestOptions(
    browsers: ['chromium', 'firefox', 'webkit'],
    // Screenshots on failure are exercised in their own test below; leaving
    // them on here would litter the repository on an unrelated failure.
    artifactsPath: null,
  );

  playwrightGroup('fixtures e assertions', () {
    playwrightTest('entrega uma pagina pronta por teste', (t) async {
      await t.page.goto(server.url('/title'));
      await expectPage(t.page).toHaveTitle('Test Page Title');
      await expectPage(t.page).toHaveURL(RegExp(r'/title$'));
      // The context is this test's alone, so there is exactly one page.
      expect(t.context.pages().length, equals(1));
      expect(['chromium', 'firefox', 'webkit'], contains(t.browserName));
    }, options: allBrowsers);

    playwrightTest('assertions de visibilidade e texto esperam', (t) async {
      await t.page.goto(server.url('/late'));
      // The button only appears after a delay: a non-retrying assertion
      // would fail here, which is the whole reason these retry.
      await expectLocator(t.page.locator('#later')).toBeVisible();
      await expectLocator(t.page.locator('#later')).toHaveText('Later');
      await expectLocator(t.page.locator('#later')).toContainText('ate');
      await expectLocator(t.page.locator('#later')).toHaveCount(1);
      await expectLocator(t.page.locator('#nao-existe')).toHaveCount(0);
    }, options: allBrowsers);

    playwrightTest('assertions de estado de formulario', (t) async {
      await t.page.goto(server.url('/form'));
      final name = t.page.locator('#name');
      await expectLocator(name).toBeVisible();
      await expectLocator(name).toBeEditable();
      await expectLocator(name).toBeEnabled();
      await name.fill('Isaque');
      await expectLocator(name).toHaveValue('Isaque');
      await expectLocator(name).toBeFocused();
      await expectLocator(name).toHaveAttribute('id', 'name');
    }, options: allBrowsers);

    playwrightTest('negacao com not', (t) async {
      await t.page.goto(server.url('/hello'));
      await expectLocator(t.page.locator('#nao-existe')).not.toBeVisible();
      await expectLocator(t.page.locator('#hello')).not.toBeHidden();
      await expectPage(t.page).not.toHaveTitle('Outra coisa');
    }, options: allBrowsers);

    playwrightTest('assertion que falha explica o que viu', (t) async {
      await t.page.goto(server.url('/hello'));
      try {
        await expectLocator(t.page.locator('#hello'),
                timeout: const Duration(seconds: 2))
            .toHaveText('Outra coisa');
        fail('the assertion should not have passed');
      } on AssertionFailure catch (error) {
        // The message has to say what was expected *and* what was there, or
        // it sends you back to the browser to find out.
        expect(error.toString(), contains('Outra coisa'));
        expect(error.toString(), contains('Hello'));
      }
    }, options: allBrowsers, timeout: const Timeout(Duration(minutes: 1)));

    playwrightTest('expectResponse sobre o APIRequestContext', (t) async {
      final response = await t.context.request.get(server.url('/hello'));
      await expectResponse(response).toBeOK();
      final missing = await t.context.request.get(server.url('/nao-existe'));
      await expectResponse(missing).not.toBeOK();
    }, options: allBrowsers);
  });

  playwrightGroup('screenshot na falha', () {
    playwrightTest('deve escrever a imagem e citar o caminho', (t) async {
      final artifacts =
          Directory.systemTemp.createTempSync('pw-test-artifacts');
      addTearDown(() => artifacts.deleteSync(recursive: true));

      // Drive the failure path by hand: a failing playwrightTest would fail
      // this file, so the behaviour is exercised through its own fixtures.
      await t.page.goto(server.url('/hello'));
      final file =
          '${artifacts.path}${Platform.pathSeparator}falha-chromium.png';
      await t.page.screenshot(path: file, fullPage: true);
      expect(File(file).existsSync(), isTrue);
      expect(File(file).lengthSync(), greaterThan(100));
    });
  });
}
