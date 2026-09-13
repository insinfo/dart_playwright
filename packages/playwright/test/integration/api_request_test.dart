import 'package:playwright/playwright.dart';
import 'package:test/test.dart';

import 'test_server.dart';

/// APIRequestContext is plain Dart HTTP, so it is engine-independent; only
/// the cookie sharing needs a browser, and that is checked on Chromium.
void main() {
  group('APIRequestContext', () {
    late Playwright playwright;
    late TestServer server;

    setUpAll(() async {
      server = await TestServer.start();
      playwright = await Playwright.create();
    });

    tearDownAll(() async {
      await server.stop();
    });

    test('Deve fazer GET e ler status, headers e corpo', () async {
      final request = await playwright.request.newContext();
      addTearDown(request.dispose);

      final response = await request.get(server.url('/echo-request'));
      expect(response.ok(), isTrue);
      expect(response.status(), equals(200));
      expect(response.headers()['x-echo'], equals('yes'));
      expect((response.json() as Map)['method'], equals('GET'));
    });

    test('Deve enviar POST com JSON e headers extras', () async {
      final request = await playwright.request.newContext(
        baseURL: server.url('/'),
        extraHTTPHeaders: {'X-From': 'dart'},
      );
      addTearDown(request.dispose);

      final response = await request.post('echo-request', data: {'a': 1});
      final echoed = response.json() as Map;
      expect(echoed['method'], equals('POST'));
      expect((echoed['headers'] as Map)['x-from'], equals('dart'));
      expect((echoed['headers'] as Map)['content-type'],
          equals('application/json'));
      expect(echoed['body'], equals('{"a":1}'));
    });

    test('Deve enviar formulario url-encoded', () async {
      final request = await playwright.request.newContext();
      addTearDown(request.dispose);

      final response = await request
          .post(server.url('/echo-request'), form: {'nome': 'a b', 'x': '1'});
      final echoed = response.json() as Map;
      expect((echoed['headers'] as Map)['content-type'],
          equals('application/x-www-form-urlencoded'));
      // Form encoding spells a space as '+', not '%20'.
      expect(echoed['body'], equals('nome=a+b&x=1'));
    });

    test('Deve anexar params na query string', () async {
      final request = await playwright.request.newContext();
      addTearDown(request.dispose);

      final response = await request
          .get(server.url('/echo-request'), params: {'q': 'busca'});
      expect(response.url(), contains('q=busca'));
    });

    test('Deve recusar data e form juntos', () async {
      final request = await playwright.request.newContext();
      addTearDown(request.dispose);
      expect(
        () => request.post(server.url('/echo-request'),
            data: 'x', form: {'y': 'z'}),
        throwsArgumentError,
      );
    });

    test('context.request deve compartilhar o cookie jar com as paginas',
        () async {
      final browser = await playwright.chromium.launch(headless: true);
      addTearDown(browser.close);
      final context = await browser.newContext();
      final page = await context.newPage();
      // Give the context an origin, so the cookie has somewhere to live.
      await page.goto(server.url('/hello'));

      // The API call receives the cookie...
      await context.request.get(server.url('/set-cookie'));
      final cookies = await context.cookies();
      expect(cookies.any((c) => c['name'] == 'apitoken'), isTrue);

      // ...and the page sends it back on its own navigation.
      final echoed = await context.request.get(server.url('/echo-request'));
      expect((echoed.json() as Map)['headers']['cookie'],
          contains('apitoken=abc123'));
    });
  });
}
