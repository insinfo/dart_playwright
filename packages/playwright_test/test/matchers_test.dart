import 'package:playwright_test/playwright_test.dart';

import 'app_server.dart';

/// Os matchers novos, cada um no caso que passa e no que falha.
///
/// O caso que falha e metade do valor de um matcher: uma assertion que so diz
/// "nao passou" manda quem le de volta ao navegador. Cada teste aqui confere a
/// mensagem, nao so o tipo da excecao.
void main() {
  late AppServer app;

  setUpAll(() async {
    app = await AppServer.start();
  });

  tearDownAll(() async {
    await app.stop();
  });

  // Prazo curto: o caso que falha espera o prazo inteiro antes de desistir, e
  // sao muitos deles neste arquivo.
  const curto = Duration(milliseconds: 400);

  /// Roda [body] e devolve a falha que ela produziu.
  Future<AssertionFailure> falhaDe(Future<void> Function() body) async {
    try {
      await body();
    } on AssertionFailure catch (failure) {
      return failure;
    }
    fail('esperava uma AssertionFailure e a assertion passou');
  }

  playwrightGroup('matchers', () {
    const opcoes = PlaywrightTestOptions(artifactsPath: null);

    playwrightTest('toHaveCSS', (t) async {
      await t.page.goto(app.url('/widgets'));
      final pintado = t.page.locator('#pintado');
      await expectLocator(pintado).toHaveCSS('color', 'rgb(0, 128, 0)');
      await expectLocator(pintado).toHaveCSS('padding-left', '7px');
      await expectLocator(pintado).toHaveCSS('color', RegExp(r'^rgb\(0,'));
      await expectLocator(pintado).not.toHaveCSS('color', 'rgb(255, 0, 0)');

      final falha = await falhaDe(() => expectLocator(pintado, timeout: curto)
          .toHaveCSS('color', 'rgb(255, 0, 0)'));
      expect(falha.toString(), contains('have CSS color'));
      expect(falha.toString(), contains('rgb(255, 0, 0)'));
      expect(falha.toString(), contains('Last seen: "rgb(0, 128, 0)"'));
    }, options: opcoes);

    playwrightTest('toHaveId', (t) async {
      await t.page.goto(app.url('/widgets'));
      await expectLocator(t.page.locator('#pintado')).toHaveId('pintado');
      await expectLocator(t.page.locator('#pintado')).toHaveId(RegExp('^pint'));
      await expectLocator(t.page.locator('#pintado')).not.toHaveId('outro');

      final falha = await falhaDe(() =>
          expectLocator(t.page.locator('#pintado'), timeout: curto)
              .toHaveId('outro'));
      expect(falha.toString(), contains('have an id'));
      expect(falha.toString(), contains('Last seen: "pintado"'));
    }, options: opcoes);

    playwrightTest('toHaveJSProperty', (t) async {
      await t.page.goto(app.url('/widgets'));
      final campo = t.page.locator('#campo');
      await expectLocator(campo).toHaveJSProperty('value', 'inicial');
      await expectLocator(campo).toHaveJSProperty('disabled', false);
      // Caminho com ponto, como no upstream.
      await expectLocator(t.page.locator('#marcado'))
          .toHaveJSProperty('dataset.estado', 'pronto');
      await expectLocator(campo).not.toHaveJSProperty('value', 'outra');

      final falha = await falhaDe(() => expectLocator(campo, timeout: curto)
          .toHaveJSProperty('value', 'outra'));
      expect(falha.toString(), contains('have the JS property value'));
      expect(falha.toString(), contains('Last seen: "inicial"'));

      // Propriedade que nao existe e reportada como ausente, nao como valor
      // errado: sao erros diferentes de quem escreveu o teste.
      final ausente = await falhaDe(() => expectLocator(campo, timeout: curto)
          .toHaveJSProperty('naoExiste', 1));
      expect(ausente.toString(), contains('Last seen: undefined'));
    }, options: opcoes);

    playwrightTest('toHaveValues', (t) async {
      await t.page.goto(app.url('/widgets'));
      final cores = t.page.locator('#cores');
      await expectLocator(cores).toHaveValues(['vermelho', 'azul']);
      await expectLocator(cores)
          .toHaveValues([RegExp('^verm'), RegExp('azul')]);
      await expectLocator(cores).not.toHaveValues(['vermelho']);

      final falha = await falhaDe(() => expectLocator(cores, timeout: curto)
          .toHaveValues(['vermelho', 'verde']));
      expect(falha.toString(), contains('selected values'));
      expect(falha.toString(), contains('Last seen: ["vermelho","azul"]'));

      // Um select sem `multiple` e erro de quem escreveu o teste: esperar o
      // prazo inteiro para depois dizer "nao bateu" esconderia isso.
      await expectLater(
        expectLocator(t.page.locator('#unico'), timeout: curto)
            .toHaveValues(['a']),
        throwsA(isA<ArgumentError>()),
      );
    }, options: opcoes);

    playwrightTest('toBeInViewport', (t) async {
      await t.page.goto(app.url('/widgets'));
      await expectLocator(t.page.locator('#pintado')).toBeInViewport();
      await expectLocator(t.page.locator('#dentro')).toBeInViewport(ratio: 1);
      // #fora tem 400px dentro de um painel de 60px que ja gastou 20 com
      // #dentro: so um pedaco dele aparece.
      await expectLocator(t.page.locator('#fora')).toBeInViewport();
      await expectLocator(t.page.locator('#fora')).not.toBeInViewport(ratio: 1);
      await expectLocator(t.page.locator('#abaixo')).not.toBeInViewport();

      final falha = await falhaDe(() =>
          expectLocator(t.page.locator('#abaixo'), timeout: curto)
              .toBeInViewport());
      expect(falha.toString(), contains('be in the viewport'));
      expect(falha.toString(), contains('Last seen: 0.0%'));

      final parcial = await falhaDe(() =>
          expectLocator(t.page.locator('#fora'), timeout: curto)
              .toBeInViewport(ratio: 1));
      expect(parcial.toString(), contains('100% in the viewport'));
    }, options: opcoes);

    playwrightTest('toHaveAccessibleName', (t) async {
      await t.page.goto(app.url('/widgets'));
      final salvar = t.page.locator('#salvar');
      await expectLocator(salvar).toHaveAccessibleName('Salvar');
      await expectLocator(salvar).toHaveAccessibleName(RegExp('^Sal'));
      await expectLocator(salvar).not.toHaveAccessibleName('Cancelar');

      final falha = await falhaDe(() => expectLocator(salvar, timeout: curto)
          .toHaveAccessibleName('Cancelar'));
      expect(falha.toString(), contains('accessible name'));
      expect(falha.toString(), contains('Last seen: "Salvar"'));
    }, options: opcoes);

    playwrightTest('toHaveAccessibleDescription', (t) async {
      await t.page.goto(app.url('/widgets'));
      // aria-describedby aponta para o texto de ajuda.
      await expectLocator(t.page.locator('#salvar'))
          .toHaveAccessibleDescription('Grava e fecha');
      // Sem aria-describedby nem aria-description sobra o title.
      await expectLocator(t.page.locator('#com-title'))
          .toHaveAccessibleDescription('Dica curta');
      await expectLocator(t.page.locator('#salvar'))
          .not
          .toHaveAccessibleDescription('outra coisa');

      final falha = await falhaDe(() =>
          expectLocator(t.page.locator('#salvar'), timeout: curto)
              .toHaveAccessibleDescription('outra coisa'));
      expect(falha.toString(), contains('accessible description'));
      expect(falha.toString(), contains('Last seen: "Grava e fecha"'));
    }, options: opcoes);

    playwrightTest('toHaveRole', (t) async {
      await t.page.goto(app.url('/widgets'));
      await expectLocator(t.page.locator('#papel')).toHaveRole('alert');
      await expectLocator(t.page.locator('#salvar')).toHaveRole('button');
      await expectLocator(t.page.locator('#papel')).not.toHaveRole('button');

      final falha = await falhaDe(() =>
          expectLocator(t.page.locator('#papel'), timeout: curto)
              .toHaveRole('button'));
      expect(falha.toString(), contains('ARIA role "button"'));
      expect(falha.toString(), contains('Last seen: "alert"'));
    }, options: opcoes);

    playwrightTest('expectPoll repete ate a condicao valer', (t) async {
      await t.page.goto(app.url('/widgets'));
      var tentativas = 0;
      await expectPoll(() {
        tentativas++;
        return tentativas;
      }, greaterThanOrEqualTo(3), timeout: const Duration(seconds: 3));
      expect(tentativas, greaterThanOrEqualTo(3));

      // Tambem serve para o que vem do navegador e ainda nao esta pronto.
      await expectPoll(
        () => t.page.locator('#cores').count(),
        equals(1),
        timeout: const Duration(seconds: 3),
      );

      final falha = await falhaDe(() => expectPoll(
            () => 1,
            equals(2),
            timeout: curto,
            reason: 'o contador',
          ));
      expect(falha.toString(), contains('Expected o contador to'));
      expect(falha.toString(), contains('Last seen: <1>'));
    }, options: opcoes);

    playwrightTest('expectPoll trata excecao como tentativa', (t) async {
      var tentativas = 0;
      await expectPoll(() {
        tentativas++;
        if (tentativas < 3) throw StateError('ainda nao');
        return 'pronto';
      }, equals('pronto'), timeout: const Duration(seconds: 3));
      expect(tentativas, equals(3));

      final falha = await falhaDe(() => expectPoll(
            () => throw StateError('nunca'),
            equals('pronto'),
            timeout: curto,
          ));
      expect(falha.toString(), contains('error: Bad state: nunca'));
    }, options: opcoes);
  });
}
