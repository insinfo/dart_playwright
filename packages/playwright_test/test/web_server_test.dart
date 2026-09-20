import 'dart:async' as async;
import 'dart:io';

import 'package:playwright_test/playwright_test.dart';

import 'package_dir.dart';

/// Exercita [PlaywrightWebServer] sem navegador nenhum: o que esta em jogo
/// aqui e processo, porta e prontidao.
void main() {
  final dart = Platform.resolvedExecutable;
  final servidores = <PlaywrightWebServer>[];

  tearDown(() async {
    for (final s in servidores) {
      try {
        await s.stop();
      } catch (_) {
        // Um teste que ja derrubou o servidor nao deve falhar no tearDown.
      }
    }
    servidores.clear();
  });

  Future<PlaywrightWebServer> subir({
    required String command,
    String? url,
    int? port,
    String? readyUrl,
    Pattern? readyBody,
    RegExp? waitForStdout,
    Duration timeout = const Duration(seconds: 90),
    bool? reuseExistingServer,
  }) async {
    final s = await PlaywrightWebServer.start(
      command: command,
      cwd: packageDir,
      url: url,
      port: port,
      readyUrl: readyUrl,
      readyBody: readyBody,
      waitForStdout: waitForStdout,
      timeout: timeout,
      reuseExistingServer: reuseExistingServer,
    );
    servidores.add(s);
    return s;
  }

  group('prontidao', () {
    test(
        'a porta abre antes do build terminar, e por isso a porta nao serve '
        'de sinal de prontidao', () async {
      final porta = await _portaLivre();
      final server = await subir(
        command: '"$dart" run test/fixtures/serve_app.dart '
            '--port=$porta --build-delay-ms=4000',
        // Modo fraco, o do upstream quando so se da a porta: basta a porta
        // aceitar conexao.
        port: porta,
        timeout: const Duration(seconds: 30),
      );

      // A porta esta aberta, mas o bundle ainda nao existe: um teste que
      // rodasse agora pegaria 404.
      final status = await _status('http://127.0.0.1:$porta/main.dart.js');
      expect(status, equals(404),
          reason: 'a porta aceitou conexao antes do build terminar');
      expect(server.reusedExistingServer, isFalse);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('readyUrl espera o artefato compilado aparecer', () async {
      final porta = await _portaLivre();
      final relogio = Stopwatch()..start();
      await subir(
        command: '"$dart" run test/fixtures/serve_app.dart '
            '--port=$porta --build-delay-ms=4000',
        url: 'http://127.0.0.1:$porta/',
        readyUrl: 'http://127.0.0.1:$porta/main.dart.js',
        timeout: const Duration(seconds: 60),
      );
      relogio.stop();

      final status = await _status('http://127.0.0.1:$porta/main.dart.js');
      expect(status, equals(200),
          reason: 'start() so pode voltar com o bundle no ar');
      expect(relogio.elapsed, greaterThan(const Duration(seconds: 3)),
          reason: 'esperou o build de 4s, nao so o socket');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('readyBody recusa um corpo que nao casa', () async {
      final porta = await _portaLivre();
      await subir(
        command: '"$dart" run test/fixtures/serve_app.dart '
            '--port=$porta --build-delay-ms=2000',
        url: 'http://127.0.0.1:$porta/',
        readyUrl: 'http://127.0.0.1:$porta/main.dart.js',
        readyBody: 'explodeDeliberadamente',
        timeout: const Duration(seconds: 90),
      );
      final corpo = await _corpo('http://127.0.0.1:$porta/main.dart.js');
      expect(corpo, contains('explodeDeliberadamente'));
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('waitForStdout termina a espera pela saida do processo', () async {
      final porta = await _portaLivre();
      await subir(
        command: '"$dart" run test/fixtures/serve_app.dart '
            '--port=$porta --build-delay-ms=1500',
        url: 'http://127.0.0.1:$porta/',
        waitForStdout: RegExp('Build succeeded'),
        timeout: const Duration(seconds: 60),
      );
      final status = await _status('http://127.0.0.1:$porta/main.dart.js');
      expect(status, equals(200));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('derrubada', () {
    test('matar so o processo do comando deixa o neto segurando a porta',
        () async {
      // Este teste nao exercita PlaywrightWebServer: ele documenta o defeito
      // que motiva a derrubada em arvore. Se um dia matar o pai passar a
      // bastar, ele falha e a complexidade do taskkill /T pode sair.
      final porta = await _portaLivre();
      // spawn_server e o pai; quem escuta a porta e o filho que ele cria.
      final processo = await Process.start(
        dart,
        ['run', 'test/fixtures/spawn_server.dart', '--port=$porta'],
        workingDirectory: packageDir,
      );
      processo.stdout.drain<void>();
      processo.stderr.drain<void>();
      await _esperarPorta(porta, ocupada: true);

      processo.kill();
      await processo.exitCode;
      await Future<void>.delayed(const Duration(seconds: 2));

      final aindaOcupada = await _portaOcupada(porta);
      addTearDown(() => _matarArvoreNaPorta(porta));
      expect(aindaOcupada, isTrue,
          reason: 'o neto sobrevive ao pai e continua escutando');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('stop() derruba a arvore e devolve a porta', () async {
      final porta = await _portaLivre();
      final server = await subir(
        command: '"$dart" run test/fixtures/spawn_server.dart --port=$porta',
        url: 'http://127.0.0.1:$porta/',
        timeout: const Duration(seconds: 60),
      );
      expect(await _portaOcupada(porta), isTrue);

      await server.stop();

      expect(await _portaOcupada(porta), isFalse,
          reason: 'a porta tem de estar livre quando stop() retorna');
      // E a proxima execucao tem de conseguir usa-la.
      final segundo = await subir(
        command: '"$dart" run test/fixtures/spawn_server.dart --port=$porta',
        url: 'http://127.0.0.1:$porta/',
        timeout: const Duration(seconds: 60),
      );
      expect(segundo.reusedExistingServer, isFalse);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('stop() e idempotente', () async {
      final porta = await _portaLivre();
      final server = await subir(
        command: '"$dart" run test/fixtures/serve_app.dart --port=$porta',
        url: 'http://127.0.0.1:$porta/',
        timeout: const Duration(seconds: 60),
      );
      await server.stop();
      await server.stop();
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('servidor ja no ar', () {
    test('reaproveita e nao derruba o que nao subiu', () async {
      final porta = await _portaLivre();
      final externo = await Process.start(
        dart,
        ['run', 'test/fixtures/serve_app.dart', '--port=$porta'],
        workingDirectory: packageDir,
      );
      externo.stdout.drain<void>();
      externo.stderr.drain<void>();
      addTearDown(() async {
        externo.kill();
        await externo.exitCode;
      });
      await _esperarPorta(porta, ocupada: true);

      final server = await subir(
        command: 'este-comando-nao-deveria-rodar',
        url: 'http://127.0.0.1:$porta/',
        reuseExistingServer: true,
        timeout: const Duration(seconds: 30),
      );
      expect(server.reusedExistingServer, isTrue);

      await server.stop();
      expect(await _portaOcupada(porta), isTrue,
          reason: 'o servidor de quem rodou o teste continua de pe');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('recusa quando reuseExistingServer e falso', () async {
      final porta = await _portaLivre();
      final externo = await Process.start(
        dart,
        ['run', 'test/fixtures/serve_app.dart', '--port=$porta'],
        workingDirectory: packageDir,
      );
      externo.stdout.drain<void>();
      externo.stderr.drain<void>();
      addTearDown(() async {
        externo.kill();
        await externo.exitCode;
      });
      await _esperarPorta(porta, ocupada: true);

      await expectLater(
        PlaywrightWebServer.start(
          command: '"$dart" run test/fixtures/serve_app.dart --port=$porta',
          cwd: packageDir,
          url: 'http://127.0.0.1:$porta/',
          reuseExistingServer: false,
          timeout: const Duration(seconds: 15),
        ),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', contains('ja esta em uso'))
            .having(
                (e) => e.message, 'message', contains('reuseExistingServer'))),
      );
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('quando nao sobe', () {
    test('o timeout diz o que fazer e mostra a saida do servidor', () async {
      final porta = await _portaLivre();
      final outraPorta = await _portaLivre();
      await expectLater(
        PlaywrightWebServer.start(
          // Sobe, imprime, mas escuta na porta errada: a sonda nunca acerta.
          command: '"$dart" run test/fixtures/serve_app.dart '
              '--port=$outraPorta',
          cwd: packageDir,
          url: 'http://127.0.0.1:$porta/',
          timeout: const Duration(seconds: 8),
        ),
        throwsA(isA<async.TimeoutException>()
            .having((e) => e.message, 'message', contains('O que fazer'))
            .having((e) => e.message, 'message', contains('Sonda:'))
            .having((e) => e.message, 'message', contains('Serving on'))),
      );
      await _matarArvoreNaPorta(outraPorta);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('um comando que morre cedo vira erro com a saida anexada', () async {
      final porta = await _portaLivre();
      await expectLater(
        PlaywrightWebServer.start(
          command: 'comando-que-nao-existe-mesmo',
          url: 'http://127.0.0.1:$porta/',
          timeout: const Duration(seconds: 20),
        ),
        throwsA(isA<StateError>().having((e) => e.message, 'message',
            contains('terminou antes de ficar pronto'))),
      );
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('exige url ou port, nunca os dois', () async {
      expect(
        () => PlaywrightWebServer.start(command: 'x'),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => PlaywrightWebServer.start(
            command: 'x', url: 'http://127.0.0.1:1/', port: 1),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => PlaywrightWebServer.start(command: '  ', port: 1),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}

/// Uma porta que estava livre no instante da chamada.
Future<int> _portaLivre() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final porta = socket.port;
  await socket.close();
  return porta;
}

Future<bool> _portaOcupada(int porta) async {
  try {
    final socket = await Socket.connect('127.0.0.1', porta,
        timeout: const Duration(milliseconds: 500));
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

Future<void> _esperarPorta(int porta, {required bool ocupada}) async {
  final limite = DateTime.now().add(const Duration(seconds: 40));
  while (DateTime.now().isBefore(limite)) {
    if (await _portaOcupada(porta) == ocupada) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError(
      'a porta $porta nunca ficou ${ocupada ? 'ocupada' : 'livre'}');
}

Future<int> _status(String url) async {
  final client = HttpClient();
  try {
    final response = await (await client.getUrl(Uri.parse(url))).close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

Future<String> _corpo(String url) async {
  final client = HttpClient();
  try {
    final response = await (await client.getUrl(Uri.parse(url))).close();
    return await response.transform(const SystemEncoding().decoder).join();
  } finally {
    client.close(force: true);
  }
}

/// Rede de seguranca: nenhum teste pode deixar processo vivo segurando porta.
Future<void> _matarArvoreNaPorta(int porta) async {
  if (!Platform.isWindows) {
    await Process.run('sh', ['-c', 'fuser -k $porta/tcp'])
        .catchError((_) => ProcessResult(0, 0, '', ''));
    return;
  }
  final saida = await Process.run('netstat', ['-ano']);
  for (final linha in (saida.stdout as String).split('\n')) {
    if (!linha.contains(':$porta ') || !linha.contains('LISTENING')) continue;
    final pid = linha.trim().split(RegExp(r'\s+')).last;
    await Process.run('taskkill', ['/pid', pid, '/T', '/F'])
        .catchError((_) => ProcessResult(0, 0, '', ''));
  }
}
