import 'dart:convert';
import 'dart:io';

import 'package:playwright_test/playwright_test.dart';

import 'app_server.dart';

late AppServer app;

/// Os arquivos de estado ficam em TEMP e saem no fim: um `.auth/` largado no
/// repositorio e credencial commitada por acidente.
final tmp = Directory.systemTemp.createTempSync('pw-dart-storage-');

String _arquivo(String nome) => '${tmp.path}${Platform.pathSeparator}$nome';

Future<void> _login(Page page) async {
  await page.goto(app.url('/login'));
  await page.fill('#user', 'ana');
  await page.fill('#pass', 's3cr3t');
  await page.click('#entrar');
  await expectLocator(page.locator('#bemvindo')).toBeVisible();
}

Future<bool> _aindaLogado(Page page) async {
  await page.goto(app.url('/painel'));
  return page.locator('#sair').isVisible();
}

/// O caso normal: loga uma vez e reaproveita.
final auth = StorageState(
  path: _arquivo('auth.json'),
  logIn: _login,
  verify: _aindaLogado,
);

/// Sem `verify`, para exercitar as camadas baratas sozinhas.
final authSemVerify = StorageState(
  path: _arquivo('sem-verify.json'),
  logIn: _login,
);

/// Prazo de validade curtissimo: o arquivo em disco nunca serve.
final authVelho = StorageState(
  path: _arquivo('velho.json'),
  logIn: _login,
  maxAge: const Duration(seconds: 1),
);

/// Um estado que parece fresco e nao vale: so `verify` descobre.
final authInvalido = StorageState(
  path: _arquivo('invalido.json'),
  logIn: _login,
  verify: _aindaLogado,
);

/// `logIn` que nao loga: o estado recem-criado tambem reprova, e a suite tem
/// de parar com um motivo escrito em vez de refazer o login para sempre.
final authQuebrado = StorageState(
  path: _arquivo('quebrado.json'),
  logIn: (page) async => page.goto(app.url('/login')),
  verify: _aindaLogado,
);

String _estadoBruto({required String valor, required int expiraEm}) =>
    jsonEncode({
      'cookies': [
        {
          'name': 'session',
          'value': valor,
          'domain': '127.0.0.1',
          'path': '/',
          'expires': expiraEm,
          'httpOnly': false,
          'secure': false,
          'sameSite': 'Lax',
        }
      ],
      'origins': <Object>[],
    });

int get _agora => DateTime.now().millisecondsSinceEpoch ~/ 1000;

void main() {
  setUpAll(() async {
    app = await AppServer.start();
    // Os arquivos de partida sao escritos antes de qualquer teste, para que
    // existam quando a primeira fixture de worker for ler um deles.
    File(authSemVerify.path)
        .writeAsStringSync(_estadoBruto(valor: 'ok', expiraEm: _agora - 60));
    final velho = File(authVelho.path)
      ..writeAsStringSync(_estadoBruto(valor: 'ok', expiraEm: _agora + 3600));
    velho
        .setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 2)));
    File(authInvalido.path).writeAsStringSync(
        _estadoBruto(valor: 'nao-vale', expiraEm: _agora + 3600));
  });

  tearDownAll(() async {
    await app.stop();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  playwrightGroup('storageState', () {
    final comAuth = PlaywrightTestOptions(
      artifactsPath: null,
      storageState: auth,
    );

    playwrightTest('o primeiro teste loga (1 de 2)', (t) async {
      await t.page.goto(app.url('/painel'));
      await expectLocator(t.page.locator('#sair')).toBeVisible();
      expect(app.logins, equals(1),
          reason: 'um unico login, feito no setup do arquivo');
      expect(File(auth.path).existsSync(), isTrue);
    }, options: comAuth);

    playwrightTest('o segundo teste pula o login (2 de 2)', (t) async {
      await t.page.goto(app.url('/painel'));
      await expectLocator(t.page.locator('#sair')).toBeVisible();
      // A prova de que pulou: o servidor conta as idas a /session, e o
      // contador nao andou. Passar sozinho nao provaria nada — o teste
      // passaria tambem se ele tivesse logado de novo.
      expect(app.logins, equals(1),
          reason: 'o segundo teste reaproveitou o estado do primeiro');
    }, options: comAuth);

    playwrightTest('o localStorage volta junto com os cookies', (t) async {
      await t.page.goto(app.url('/token'));
      await expectLocator(t.page.locator('#token')).toHaveText('abc-123');
      expect(app.logins, equals(1));
    }, options: comAuth);

    playwrightTest('um cookie ja vencido no arquivo derruba o estado',
        (t) async {
      // Escrito antes de qualquer teste que use `authSemVerify`, entao e ele
      // que a fixture vai ler.
      expect(app.logins, equals(2),
          reason: 'o arquivo tinha um cookie vencido, entao o login refez');
      await t.page.goto(app.url('/painel'));
      await expectLocator(t.page.locator('#sair')).toBeVisible();
    },
        options: PlaywrightTestOptions(
          artifactsPath: null,
          storageState: authSemVerify,
        ));

    playwrightTest('um arquivo mais velho que maxAge e ignorado', (t) async {
      expect(app.logins, equals(3));
      await t.page.goto(app.url('/painel'));
      await expectLocator(t.page.locator('#sair')).toBeVisible();
    },
        options: PlaywrightTestOptions(
          artifactsPath: null,
          storageState: authVelho,
        ));

    playwrightTest('um estado fresco que nao vale e refeito uma vez',
        (t) async {
      expect(app.logins, equals(4),
          reason: 'verify reprovou o estado do disco e o login rodou de novo');
      await t.page.goto(app.url('/painel'));
      await expectLocator(t.page.locator('#sair')).toBeVisible();
    },
        options: PlaywrightTestOptions(
          artifactsPath: null,
          storageState: authInvalido,
        ));

    playwrightTest('um login que nao loga falha com o motivo escrito',
        (t) async {
      await expectLater(
        t.use(authQuebrado.fixture),
        throwsA(isA<StateError>().having((e) => e.message, 'message',
            contains('foi refeito agora e mesmo assim verify()'))),
      );
    }, options: const PlaywrightTestOptions(artifactsPath: null));
  });
}
