import 'dart:io';

import 'package:playwright_test/playwright_test.dart';

import 'package_dir.dart';
import 'web_app_fixture.dart';

/// Prova a integracao: um teste que falha com um erro estourado no navegador
/// tem de chegar ao relatorio ja traduzido.
///
/// A unica forma honesta de verificar isso e ler a mensagem que `dart test`
/// imprime, entao o teste roda uma suite que falha de proposito
/// (`test/fixtures/falha_traduzida.dart`, que nao termina em `_test.dart` e
/// por isso nao e coletada sozinha) e inspeciona a saida.
void main() {
  test('a falha de um teste traz o stack do navegador ja em Dart', () async {
    await garantirAppCompilado();
    final linha = linhaDoThrow();

    final resultado = await Process.run(
      Platform.resolvedExecutable,
      [
        'test',
        'test/fixtures/falha_traduzida.dart',
        '--concurrency=1',
        '--reporter=expanded',
      ],
      // A suite de fixture e nomeada relativamente, e um processo filho herda
      // o diretorio de quem o lancou -- que so era este pacote quando o
      // `dart test` rodava de dentro dele.
      workingDirectory: packageDir,
    );
    final saida = '${resultado.stdout}\n${resultado.stderr}';

    expect(resultado.exitCode, isNot(0),
        reason: 'a suite de fixture falha de proposito');
    expect(saida, contains('Erro nao capturado na pagina'));
    expect(saida, contains('main.dart $linha:'),
        reason: 'a mensagem de falha tem de apontar para a linha do throw '
            '($linha) em main.dart; veio:\n$saida');
    expect(saida, contains('explodeDeliberadamente'));
  }, timeout: const Timeout(Duration(minutes: 5)));
}
