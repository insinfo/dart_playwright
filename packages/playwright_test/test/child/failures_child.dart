import 'dart:io';

import 'package:playwright_test/playwright_test.dart';

/// Uma suite que **tem de falhar**.
///
/// Ela nao termina em `_test.dart` de proposito: `dart test` nao a pega
/// sozinho. Quem a roda e `failure_reporting_test.dart`, num processo filho,
/// porque as duas coisas que ela prova — teardown que roda quando o corpo
/// falha, e `expect.soft` que derruba o teste no fim — so podem ser observadas
/// de fora de um teste que falhou.
///
/// Os marcadores em disco dizem ate onde o corpo chegou; o pai le os dois.
final marcadores = Directory(Platform.environment['PW_DART_MARCADORES']!);

File _marcador(String nome) =>
    File('${marcadores.path}${Platform.pathSeparator}$nome');

final comTeardown = defineFixture<String>(
  'comTeardown',
  (f) async => 'valor',
  tearDown: (value) async => _marcador('teardown.txt').writeAsStringSync(value),
);

void main() {
  const curto = Duration(milliseconds: 300);
  const opcoes = PlaywrightTestOptions(artifactsPath: null);

  playwrightGroup('falhas de proposito', () {
    playwrightTest('o teardown roda mesmo quando o corpo falha', (t) async {
      await t.use(comTeardown);
      await t.page.setContent('<p id="x">x</p>');
      throw StateError('falha proposital do corpo');
    }, options: opcoes);

    playwrightTest('soft acumula e o teste falha no fim', (t) async {
      await t.page.setContent('<p id="pintado">pintado</p>');
      await expectLocator(t.page.locator('#nao-existe'), timeout: curto)
          .soft
          .toBeVisible();
      await expectLocator(t.page.locator('#pintado'), timeout: curto)
          .soft
          .toHaveId('outro');
      await expectPage(t.page, timeout: curto).soft.toHaveTitle('inexistente');
      await expectPoll(() => 1, equals(2),
          timeout: curto, reason: 'o contador', soft: true);
      // Se soft interrompesse o corpo, este marcador nao existiria.
      _marcador('soft.txt').writeAsStringSync('o corpo chegou ao fim');
    }, options: opcoes);

    playwrightTest('soft que passa nao derruba nada', (t) async {
      await t.page.setContent('<p id="pintado">pintado</p>');
      await expectLocator(t.page.locator('#pintado'), timeout: curto)
          .soft
          .toHaveId('pintado');
      _marcador('soft-ok.txt').writeAsStringSync('passou');
    }, options: opcoes);
  });
}
