import 'dart:io';

import 'package:path/path.dart' as p;

import 'package_dir.dart';

/// Onde vive o app Dart de teste.
///
/// Absoluto de proposito: `dart compile js` roda com este diretorio como
/// `workingDirectory`, e um caminho relativo so resolvia com o `dart test`
/// rodando de dentro do pacote.
final String appDir = p.join(packageDir, 'test', 'fixtures', 'web_app');

/// Compila `test/fixtures/web_app/main.dart` se ainda nao houver bundle atual.
///
/// O bundle e o source map nao entram no repositorio: sao artefatos, e um
/// artefato commitado vira mentira na primeira vez que alguem edita o `.dart`
/// e esquece de recompilar -- exatamente o erro que estes testes existem para
/// pegar. `dart compile js` emite o `.map` por padrao (o que se desliga e
/// `--no-source-maps`), entao nao ha flag a passar.
Future<void> garantirAppCompilado() async {
  final fonte = File('$appDir/main.dart');
  final bundle = File('$appDir/main.dart.js');
  final mapa = File('$appDir/main.dart.js.map');

  if (await bundle.exists() && await mapa.exists()) {
    final fonteEm = await fonte.lastModified();
    final bundleEm = await bundle.lastModified();
    if (!bundleEm.isBefore(fonteEm)) return;
  }

  final resultado = await Process.run(
    Platform.resolvedExecutable,
    ['compile', 'js', '-o', 'main.dart.js', 'main.dart'],
    workingDirectory: appDir,
  );
  if (resultado.exitCode != 0) {
    throw StateError('dart compile js falhou:\n'
        '${resultado.stdout}\n${resultado.stderr}');
  }
}

/// A linha (base 1) do `throw` dentro de `explodeDeliberadamente`.
///
/// Lida do arquivo, e nao fixada no teste: a assercao tem de bater com o
/// arquivo de hoje, nao com o de quando o teste foi escrito.
int linhaDoThrow() {
  final linhas = File('$appDir/main.dart').readAsLinesSync();
  final indice = linhas.indexWhere((l) => l.contains('throw StateError('));
  if (indice < 0) {
    throw StateError(
        'o app de teste nao tem mais o throw que os testes procuram');
  }
  return indice + 1;
}
