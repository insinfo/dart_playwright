import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

/// O que so da para ver de fora de um teste que falhou.
///
/// Um teste que prova "o teardown rodou mesmo com o corpo falhando" nao pode
/// ser um teste que passa: o corpo tem de falhar de verdade. Entao a suite de
/// verdade roda num processo filho (`test/child/failures_child.dart`, que nao
/// termina em `_test.dart` e por isso `dart test` nao pega sozinho) e este
/// arquivo le o que ela deixou: o codigo de saida, a saida do runner e os
/// marcadores em disco.
void main() {
  test('teardown roda com o corpo falhando, e soft derruba no fim', () async {
    final lib = await Isolate.resolvePackageUri(
        Uri.parse('package:playwright_test/playwright_test.dart'));
    final pacote = Directory.fromUri(lib!.resolve('../'));
    final filho = '${pacote.path}test/child/failures_child.dart';

    final marcadores =
        Directory.systemTemp.createTempSync('pw-dart-marcadores-');
    try {
      final resultado = await Process.run(
        Platform.resolvedExecutable,
        ['test', filho, '--concurrency=1', '-r', 'expanded'],
        workingDirectory: pacote.path,
        environment: {'PW_DART_MARCADORES': marcadores.path},
      );
      final saida = '${resultado.stdout}\n${resultado.stderr}';

      expect(resultado.exitCode, isNot(0),
          reason: 'a suite filha existe para falhar:\n$saida');

      // --- teardown com o corpo falhando -------------------------------
      expect(saida, contains('falha proposital do corpo'));
      expect(
          File('${marcadores.path}${Platform.pathSeparator}teardown.txt')
              .existsSync(),
          isTrue,
          reason: 'o teardown da fixture tem de rodar mesmo assim:\n$saida');

      // --- expect.soft ---------------------------------------------------
      expect(
          File('${marcadores.path}${Platform.pathSeparator}soft.txt')
              .existsSync(),
          isTrue,
          reason: 'soft nao pode interromper o corpo:\n$saida');
      expect(saida, contains('4 soft assertion(s) failed'),
          reason: 'o teste tem de falhar no fim com as quatro falhas juntas');
      expect(saida, contains('Expected locator to be visible'));
      expect(saida, contains('have an id that would be "outro"'));
      // Soft vale para as tres portas de entrada, nao so para o locator.
      expect(saida, contains('Expected page to have a title'));
      expect(saida, contains('Expected o contador to'));

      // Um soft que passou nao pode contaminar o teste seguinte.
      expect(
          File('${marcadores.path}${Platform.pathSeparator}soft-ok.txt')
              .existsSync(),
          isTrue);
      expect(saida, contains('+1 -2'),
          reason: 'um teste passou e dois falharam:\n$saida');
    } finally {
      if (marcadores.existsSync()) marcadores.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
