// Servidor estatico que imita o comportamento que quebra os testes de app
// Dart: a porta abre imediatamente e o `index.html` e servido na hora, mas o
// bundle compilado (`main.dart.js`) so aparece depois que o "build" termina.
//
// E assim que `webdev serve` e `dart run build_runner serve` se comportam na
// primeira execucao, e e por isso que esperar a porta abrir nao e esperar o
// servidor estar pronto.
import 'dart:async';
import 'dart:io';

void main(List<String> args) async {
  final options = <String, String>{};
  for (final arg in args) {
    final i = arg.indexOf('=');
    if (arg.startsWith('--') && i > 0) {
      options[arg.substring(2, i)] = arg.substring(i + 1);
    }
  }

  final port = int.parse(options['port'] ?? '0');
  final buildDelay =
      Duration(milliseconds: int.parse(options['build-delay-ms'] ?? '0'));
  final root = Directory(options['root'] ?? 'test/fixtures/web_app');
  final silent = options['silent'] == 'true';

  var built = buildDelay == Duration.zero;
  if (!built) {
    Timer(buildDelay, () {
      built = true;
      if (!silent) print('Build succeeded after ${buildDelay.inMilliseconds}ms');
    });
  }

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  if (!silent) print('Serving on http://127.0.0.1:${server.port}/');
  if (built && !silent) print('Build succeeded after 0ms');

  await for (final request in server) {
    final response = request.response;
    var path = request.uri.path;
    if (path == '/') path = '/index.html';

    // O artefato compilado so existe depois do build. Antes disso, 404 --
    // exatamente o que um teste apressado recebe.
    if (path.endsWith('.js') && !built) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      continue;
    }

    final file = File('${root.path}$path');
    if (!await file.exists()) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      continue;
    }
    response.headers.contentType = switch (path.split('.').last) {
      'html' => ContentType.html,
      'js' => ContentType('text', 'javascript', charset: 'utf-8'),
      'map' => ContentType.json,
      _ => ContentType.text,
    };
    try {
      await response.addStream(file.openRead());
      await response.close();
    } catch (_) {
      // O cliente desistiu no meio; nao e problema do servidor de teste.
    }
  }
}
