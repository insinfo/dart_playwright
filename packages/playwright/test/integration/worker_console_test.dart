import 'package:playwright/playwright.dart';
import 'package:test/test.dart';

import 'test_server.dart';

/// Transcription of upstream's `tests/page/workers.spec.ts`: "should report
/// console logs", "should not report console logs from workers twice" and the
/// worker half of "should report errors".
///
/// The upstream spec spawns the worker from a blob URL, which is what keeps
/// the test independent of the server, so this one does too.
void main() {
  group('Console de worker', () {
    late Playwright playwright;
    late TestServer server;

    setUpAll(() async {
      server = await TestServer.start();
      playwright = await Playwright.create();
    });

    tearDownAll(() async {
      await server.stop();
    });

    /// Spawns a worker whose whole body is [source].
    String spawn(String source) => '''
      () => new Worker(URL.createObjectURL(
          new Blob([${_jsString(source)}], { type: 'application/javascript' })))
    ''';

    for (final browserName in ['chromium', 'firefox', 'webkit']) {
      group('[$browserName]', () {
        late Browser browser;
        var browserLaunched = false;
        late BrowserContext context;
        late Page page;

        setUpAll(() async {
          browser = await switch (browserName) {
            'chromium' => playwright.chromium.launch(headless: true),
            'firefox' => playwright.firefox.launch(headless: true),
            _ => playwright.webkit.launch(headless: true),
          };
          browserLaunched = true;
        });

        setUp(() async {
          context = await browser.newContext();
          page = await context.newPage();
          await page.goto(server.url('/hello'));
        });

        tearDown(() async {
          await context.close();
        });

        tearDownAll(() async {
          if (browserLaunched) await browser.close();
        });

        test('Deve reportar as mensagens de console do worker', () async {
          final messages = <ConsoleMessage>[];
          final subscription = page.onConsole.listen(messages.add);
          addTearDown(subscription.cancel);

          final first = page.waitForConsoleMessage(
              predicate: (m) => m.text() == '1',
              timeout: const Duration(seconds: 20));
          await page.evaluate(spawn('console.log(1)'));
          final message = await first;

          expect(message.text(), equals('1'));
          // Juggler once reported a worker's blob URL as the frame URL.
          expect(page.url(), isNot(contains('blob')));
        });

        test('A mensagem do worker vem marcada com o worker', () async {
          final logged = page.waitForConsoleMessage(
              predicate: (m) => m.text() == 'marcado',
              timeout: const Duration(seconds: 20));
          await page.evaluate(spawn("console.log('marcado')"));
          final message = await logged;

          final worker = message.worker();
          expect(worker, isNotNull,
              reason: 'uma mensagem de worker tem de apontar o worker');
          expect(worker!.url(), contains('blob'));
          expect(page.workers(), contains(worker));
        });

        test('Uma mensagem da pagina nao aponta worker nenhum', () async {
          final logged = page.waitForConsoleMessage(
              predicate: (m) => m.text() == 'da pagina',
              timeout: const Duration(seconds: 20));
          await page.evaluate("() => console.log('da pagina')");
          expect((await logged).worker(), isNull);
        });

        test('Nao deve reportar a mesma mensagem duas vezes', () async {
          final texts = <String>[];
          final subscription =
              page.onConsole.listen((message) => texts.add(message.text()));
          addTearDown(subscription.cancel);

          final second = page.waitForConsoleMessage(
              predicate: (m) => m.text() == '2',
              timeout: const Duration(seconds: 20));
          await page.evaluate(spawn('console.log(1); console.log(2);'));
          await second;
          // Give a duplicate the chance to arrive late.
          await page.waitForTimeout(const Duration(milliseconds: 500));

          expect(texts.where((t) => t == '1').length, equals(1));
          expect(texts.where((t) => t == '2').length, equals(1));
          expect(page.url(), isNot(contains('blob')));
        });
      });
    }
  });
}

/// A JavaScript string literal for [value].
String _jsString(String value) =>
    "'${value.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";
