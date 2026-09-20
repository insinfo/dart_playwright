import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

/// O nucleo deste pacote sera compilado por dart2js junto com a UI do
/// visualizador, entao nada em `lib/src` pode tocar `dart:io`, `dart:html` ou
/// `package:web`. O que e de plataforma vive em `lib/io.dart`, que so o CLI
/// importa.
///
/// A prova completa e compilar `tool/web_smoke.dart` com
/// `dart compile js`; isto aqui e o portao barato, que roda em toda suite e
/// pega a importacao errada no momento em que ela entra.
void main() {
  test('Deve manter o nucleo livre de importacoes de plataforma', () async {
    final libraryUri = await Isolate.resolvePackageUri(Uri.parse(
        'package:playwright_trace_viewer/playwright_trace_viewer.dart'));
    final lib = Directory(File.fromUri(libraryUri!).parent.path);
    expect(lib.existsSync(), isTrue);

    const forbidden = ['dart:io', 'dart:html', 'package:web/', 'dart:ui'];
    final offenders = <String>[];
    for (final entity in lib.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final relative = entity.path
          .replaceAll('\\', '/')
          .substring(lib.path.replaceAll('\\', '/').length + 1);
      // O unico arquivo que pode, e existe para isso.
      if (relative == 'io.dart') continue;
      final source = entity.readAsStringSync();
      for (final import in forbidden) {
        if (source.contains("import '$import") ||
            source.contains("export '$import")) {
          offenders.add('$relative -> $import');
        }
      }
    }
    expect(offenders, isEmpty);
  });
}
