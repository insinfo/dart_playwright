// Uma suite que falha de proposito, para que outro teste possa ler a mensagem
// de falha que `playwrightTest` produz.
//
// Nao se chama `*_test.dart` porque nao deve ser coletada por `dart test`: ela
// e um dado de entrada, e quem a executa e o teste de integracao das fixtures.
import 'dart:io';

import 'package:playwright_test/playwright_test.dart';

import '../web_app_fixture.dart';

void main() {
  late PlaywrightWebServer servidor;

  setUpAll(() async {
    await garantirAppCompilado();
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final porta = socket.port;
    await socket.close();
    servidor = await PlaywrightWebServer.start(
      command: '"${Platform.resolvedExecutable}" run '
          'test/fixtures/serve_app.dart --port=$porta',
      url: 'http://127.0.0.1:$porta/',
      readyUrl: 'http://127.0.0.1:$porta/main.dart.js',
      readyBody: 'explodeDeliberadamente',
      timeout: const Duration(seconds: 90),
    );
  });

  tearDownAll(() async => servidor.stop());

  playwrightGroup('falha proposital', () {
    playwrightTest('estoura no navegador e falha', (t) async {
      await t.page.goto(servidor.baseURL);
      await expectLocator(t.page.locator('#pronto')).toBeVisible();
      await t.page.click('#estoura');
      // Da tempo de o erro chegar pelo protocolo antes de falhar.
      await Future<void>.delayed(const Duration(seconds: 1));
      fail('falha proposital: o erro da pagina tem de vir anexado traduzido');
    }, options: const PlaywrightTestOptions(artifactsPath: null));
  });
}
