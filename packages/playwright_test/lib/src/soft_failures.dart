import 'package:test/test.dart';

/// As falhas soft acumuladas no teste em andamento.
///
/// Uma lista de biblioteca serve aqui porque `package:test` roda os testes de
/// um arquivo um de cada vez dentro do isolate: nao ha dois testes acumulando
/// falhas ao mesmo tempo. O `addTearDown` abaixo e o que amarra a lista ao
/// teste certo e a esvazia no fim dele.
final List<String> _pending = [];
final List<String> _artifacts = [];
bool _flushRegistered = false;

/// Se ha falha soft esperando para derrubar o teste no fim.
bool get hasPendingSoftFailures => _pending.isNotEmpty;

/// Guarda [failure] e garante que o teste falhe quando terminar.
///
/// O gancho e `addTearDown` e nao uma excecao adiada: e a unica forma de o
/// relatorio do `package:test` continuar inteiro — a falha aparece como falha
/// daquele teste, com a mensagem completa, sem um runner paralelo por cima.
void recordSoftFailure(Object failure) {
  if (!_flushRegistered) {
    try {
      addTearDown(flushSoftFailures);
      _flushRegistered = true;
    } catch (_) {
      // Fora de um teste nao ha teardown onde pendurar o relato. Uma falha
      // soft que ninguem vai relatar no fim e pior que uma falha normal,
      // entao ela sobe agora.
      throw failure;
    }
  }
  _pending.add(failure.toString());
}

/// Anexa um artefato (um screenshot, por exemplo) ao relato final.
void noteSoftFailureArtifact(String path) {
  if (_pending.isNotEmpty) _artifacts.add(path);
}

/// Derruba o teste com tudo que foi acumulado, e zera para o proximo.
void flushSoftFailures() {
  final failures = List.of(_pending);
  final artifacts = List.of(_artifacts);
  _pending.clear();
  _artifacts.clear();
  _flushRegistered = false;
  if (failures.isEmpty) return;

  final buffer =
      StringBuffer('${failures.length} soft assertion(s) failed in this test:');
  for (var i = 0; i < failures.length; i++) {
    buffer.write('\n\n${i + 1}) ${failures[i]}');
  }
  for (final artifact in artifacts) {
    buffer.write('\n\nScreenshot of the failure: $artifact');
  }
  // TestFailure e nao Exception: o relatorio do package:test separa "falhou" de
  // "quebrou", e uma assertion que nao passou e a primeira coisa.
  throw TestFailure(buffer.toString());
}
