import 'package:playwright_test/playwright_test.dart';

import 'app_server.dart';

/// O servidor e criado em `setUpAll` mas as fixtures sao declaradas no topo do
/// arquivo, como quem escreve um teste faria. Esta variavel e a ponte.
late AppServer app;

/// A razao de existir da fatia: uma pagina ja logada, definida uma vez.
///
/// Compoe com a fixture embutida `page` — e o `f.page` aqui e a mesma pagina
/// que o teste recebe em `t.page`.
final loggedInPage = defineFixture<Page>('loggedInPage', (f) async {
  await f.page.goto(app.url('/login'));
  await f.page.fill('#user', 'ana');
  await f.page.fill('#pass', 's3cr3t');
  await f.page.click('#entrar');
  // Esperar o painel faz parte do login: sem isso a fixture entrega uma pagina
  // que ainda esta a caminho, e o teste corre contra o servidor.
  await expectLocator(f.page.locator('#bemvindo')).toBeVisible();
  return f.page;
});

/// Ordem de setup e teardown, observada de fora.
final ordem = <String>[];

final baseFixture = defineFixture<String>(
  'base',
  (f) async {
    ordem.add('setUp base');
    return 'base';
  },
  tearDown: (value) async => ordem.add('tearDown base'),
);

/// Depende de [baseFixture]: e o `use` dentro do `setUp` que faz a composicao.
final derivada = defineFixture<String>(
  'derivada',
  (f) async {
    final base = await f.use(baseFixture);
    ordem.add('setUp derivada($base)');
    return '$base+derivada';
  },
  tearDown: (value) async => ordem.add('tearDown derivada'),
);

/// Escopo de worker: criada uma vez para o arquivo inteiro, neste motor.
var criacoesDoWorker = 0;
final versaoDoNavegador = defineFixture<String>(
  'versaoDoNavegador',
  (f) async {
    criacoesDoWorker++;
    return f.browser.version();
  },
  scope: FixtureScope.worker,
);

/// Uma fixture automatica existe pelo efeito, nao pelo valor.
final erros = <String>[];
final coletorDeErros = defineFixture<void>('coletorDeErros', (f) async {
  final sub = f.page.onPageError.listen((e) => erros.add(e.message));
  f.onTeardown(() async => sub.cancel());
});

/// Uma opcao com valor padrao, trocavel por quem monta a suite.
final ambiente = defineOption<String>('ambiente', 'dev');

void main() {
  setUpAll(() async {
    app = await AppServer.start();
  });

  tearDownAll(() async {
    await app.stop();
  });

  const opcoes = PlaywrightTestOptions(artifactsPath: null);

  playwrightGroup('fixtures customizadas', () {
    playwrightTest('uma pagina ja logada, sem repetir o login', (t) async {
      final page = await t.use(loggedInPage);
      // O tipo sai de `Fixture<Page>`: nao ha `as` nem `dynamic` aqui, que e o
      // ponto onde uma traducao literal do test.extend() do JS daria errado.
      await expectPage(page).toHaveURL(RegExp(r'/painel$'));
      await expectLocator(page.locator('#bemvindo')).toBeVisible();
    }, options: opcoes);

    playwrightTest('o mesmo `use` duas vezes cria uma fixture so', (t) async {
      final a = await t.use(loggedInPage);
      final b = await t.use(loggedInPage);
      expect(identical(a, b), isTrue);
      expect(app.logins, equals(2),
          reason: 'um login por teste que pediu loggedInPage, nao por `use`');
    }, options: opcoes);

    playwrightTest('uma fixture depende de outra (1 de 2)', (t) async {
      ordem.clear();
      final valor = await t.use(derivada);
      expect(valor, equals('base+derivada'));
      // A base e criada antes da derivada, porque foi a derivada que a pediu.
      expect(ordem, equals(['setUp base', 'setUp derivada(base)']));
    }, options: opcoes);

    playwrightTest('e o teardown sai na ordem inversa (2 de 2)', (t) async {
      // O teardown do teste anterior ja rodou quando este comeca.
      expect(
          ordem,
          equals([
            'setUp base',
            'setUp derivada(base)',
            'tearDown derivada',
            'tearDown base',
          ]),
          reason: 'a derivada sai antes da base de que ela depende');
    }, options: opcoes);

    playwrightTest('fixture de worker e criada uma vez (1 de 2)', (t) async {
      final versao = await t.use(versaoDoNavegador);
      expect(versao, isNotEmpty);
      expect(criacoesDoWorker, equals(1));
    }, options: opcoes);

    playwrightTest('fixture de worker e criada uma vez (2 de 2)', (t) async {
      final versao = await t.use(versaoDoNavegador);
      expect(versao, isNotEmpty);
      expect(criacoesDoWorker, equals(1),
          reason: 'o segundo teste reaproveita o que o primeiro criou');
    }, options: opcoes);

    playwrightTest('uma fixture de worker nao pode usar a pagina', (t) async {
      final quebrada = defineFixture<String>(
        'quebrada',
        (f) async => f.page.url(),
        scope: FixtureScope.worker,
      );
      await expectLater(
        t.use(quebrada),
        throwsA(isA<StateError>().having((e) => e.message, 'message',
            contains('fixture de escopo worker nao tem Page'))),
      );
    }, options: opcoes);

    playwrightTest('um ciclo entre fixtures e reportado, nao trava', (t) async {
      late Fixture<int> a;
      final b = defineFixture<int>('b', (f) async => await f.use(a) + 1);
      a = defineFixture<int>('a', (f) async => await f.use(b) + 1);
      await expectLater(
        t.use(a),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', contains('Ciclo'))),
      );
    }, options: opcoes);

    playwrightTest('fixture automatica roda sem ninguem pedir', (t) async {
      erros.clear();
      await t.page.goto(app.url('/widgets'));
      await t.page.evaluate('() => { setTimeout(() => { xpto(); }, 0); }');
      await expectPoll(() => erros.length, equals(1),
          timeout: const Duration(seconds: 3));
    },
        options: PlaywrightTestOptions(
          artifactsPath: null,
          fixtures: [coletorDeErros.asAuto],
        ));

    playwrightTest('uma opcao tem valor padrao', (t) async {
      expect(await t.use(ambiente), equals('dev'));
    }, options: opcoes);

    playwrightTest('e a opcao pode ser trocada', (t) async {
      expect(await t.use(ambiente), equals('homolog'));
    },
        options: PlaywrightTestOptions(
          artifactsPath: null,
          fixtures: [ambiente.overrideWith('homolog')],
        ));
  });
}
