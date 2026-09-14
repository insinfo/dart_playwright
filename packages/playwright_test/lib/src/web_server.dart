import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Sobe (e derruba) o servidor que serve a aplicacao sob teste.
///
/// Testar um app web escrito em Dart exige que `webdev serve`,
/// `dart run build_runner serve` ou um servidor estatico ja esteja no ar,
/// **compilado**, numa porta conhecida, antes do primeiro teste. Sem uma peca
/// como esta cada suite reescreve o mesmo spawn de processo com polling de
/// porta, e o escreve errado das mesmas tres maneiras: espera a porta em vez de
/// esperar o build, mata so o processo pai, e quando falha nao mostra o que o
/// servidor imprimiu.
///
/// ```dart
/// late PlaywrightWebServer servidor;
///
/// setUpAll(() async {
///   servidor = await PlaywrightWebServer.start(
///     command: 'webdev serve web:8080 --release',
///     url: 'http://127.0.0.1:8080/',
///     readyUrl: 'http://127.0.0.1:8080/main.dart.js',
///   );
/// });
///
/// tearDownAll(() => servidor.stop());
/// ```
class PlaywrightWebServer {
  /// A URL base do servidor, pronta para `PlaywrightTestOptions.baseURL`.
  final String baseURL;

  /// Verdadeiro quando um servidor ja estava no ar e foi reaproveitado.
  ///
  /// Nesse caso [stop] nao mata nada: derrubar o servidor de desenvolvimento
  /// de quem rodou o teste seria uma surpresa desagradavel.
  final bool reusedExistingServer;

  /// O nome que prefixa as linhas de saida do servidor.
  final String name;

  final Process? _process;
  final Directory? _scriptDir;
  final _OutputBuffer? _output;
  final int? _port;
  final Duration _shutdownTimeout;
  bool _stopped = false;

  PlaywrightWebServer._({
    required this.baseURL,
    required this.reusedExistingServer,
    required this.name,
    required Process? process,
    required Directory? scriptDir,
    required _OutputBuffer? output,
    required int? port,
    required Duration shutdownTimeout,
  })  : _process = process,
        _scriptDir = scriptDir,
        _output = output,
        _port = port,
        _shutdownTimeout = shutdownTimeout;

  /// O que o servidor imprimiu em stdout e stderr desde que subiu.
  ///
  /// Limitado as ultimas linhas: um `build_runner` falante encheria a memoria
  /// de uma suite longa.
  String get output => _output?.text ?? '';

  /// Sobe [command] e so retorna quando o servidor estiver **pronto**.
  ///
  /// Exatamente uma entre [url] e [port] deve ser dada, como no upstream.
  /// Com [port], a prontidao e so "a porta aceita conexao" -- e o modo fraco,
  /// mantido por compatibilidade de semantica. Com [url], e uma requisicao
  /// HTTP bem-sucedida.
  ///
  /// [readyUrl] existe porque nenhum dos dois basta para um app Dart: o
  /// servidor de desenvolvimento abre a porta e serve o `index.html` estatico
  /// **antes** de terminar a primeira compilacao, e um teste que corre nessa
  /// janela pega 404 no bundle ou o bundle da execucao anterior. Aponte
  /// [readyUrl] para o artefato que so existe depois do build -- tipicamente
  /// `main.dart.js` -- e a espera passa a medir o build, nao o socket.
  ///
  /// [readyBody] aperta mais um grau: o corpo da resposta tem de casar com o
  /// padrao. Util quando o servidor responde 200 com uma pagina de "compilando".
  ///
  /// [waitForStdout] e [waitForStderr] sao o `wait` do upstream: a espera
  /// tambem termina quando a saida do processo casar com o padrao.
  ///
  /// [reuseExistingServer] reaproveita o que ja estiver na porta. O padrao
  /// segue o upstream: reaproveita fora da CI (e o fluxo de desenvolvimento,
  /// onde o servidor fica aberto num terminal ao lado) e falha na CI, onde
  /// uma porta ocupada quase sempre significa um processo vazado da execucao
  /// anterior servindo codigo velho.
  static Future<PlaywrightWebServer> start({
    required String command,
    String? url,
    int? port,
    String? readyUrl,
    Pattern? readyBody,
    RegExp? waitForStdout,
    RegExp? waitForStderr,
    String? cwd,
    Map<String, String>? env,
    Duration timeout = const Duration(seconds: 60),
    bool? reuseExistingServer,
    Duration shutdownTimeout = const Duration(seconds: 10),
    bool pipeOutput = false,
    String name = 'WebServer',
  }) async {
    if (command.trim().isEmpty) {
      throw ArgumentError.value(command, 'command', 'nao pode ser vazio');
    }
    if ((url == null) == (port == null)) {
      throw ArgumentError("informe 'url' ou 'port', nao os dois nem nenhum");
    }

    final baseUrl = url ?? 'http://127.0.0.1:$port/';
    final baseUri = Uri.parse(baseUrl);
    final checkPortOnly = port != null;
    final effectivePort = port ?? (baseUri.hasPort ? baseUri.port : null);
    final reuse = reuseExistingServer ?? !_boolEnv(Platform.environment['CI']);

    final probe = _Probe(
      checkPortOnly: checkPortOnly,
      port: effectivePort,
      url: Uri.parse(readyUrl ?? baseUrl),
      body: readyBody,
    );

    if (await probe.isReady()) {
      if (reuse) {
        return PlaywrightWebServer._(
          baseURL: baseUrl,
          reusedExistingServer: true,
          name: name,
          process: null,
          scriptDir: null,
          output: null,
          port: effectivePort,
          shutdownTimeout: shutdownTimeout,
        );
      }
      throw StateError(
        '$baseUrl ja esta em uso. Garanta que nada esteja rodando nessa '
        'porta/URL, ou passe reuseExistingServer: true. '
        '(o padrao e reaproveitar fora da CI e recusar na CI, onde uma porta '
        'ocupada costuma ser um processo vazado da execucao anterior)',
      );
    }

    final buffer = _OutputBuffer(name: name, echo: pipeOutput);
    final lancado = await _spawn(command, cwd: cwd, env: env);
    final process = lancado.process;
    final server = PlaywrightWebServer._(
      baseURL: baseUrl,
      reusedExistingServer: false,
      name: name,
      process: process,
      scriptDir: lancado.scriptDir,
      output: buffer,
      port: effectivePort,
      shutdownTimeout: shutdownTimeout,
    );

    final stdoutMatched = Completer<void>();
    final stderrMatched = Completer<void>();
    buffer.attach(
      process.stdout,
      waitFor: waitForStdout,
      onMatch: () => _completeOnce(stdoutMatched),
    );
    buffer.attach(
      process.stderr,
      waitFor: waitForStderr,
      onMatch: () => _completeOnce(stderrMatched),
    );

    final exited = process.exitCode.then((code) => code);

    try {
      await server._waitUntilReady(
        probe: probe,
        exited: exited,
        timeout: timeout,
        command: command,
        stdioSignals: [
          if (waitForStdout != null) stdoutMatched.future,
          if (waitForStderr != null) stderrMatched.future,
        ],
        // Com um sinal de stdio explicito, o upstream nao exige mais nada; a
        // sonda HTTP vira uma segunda via, nao um requisito.
        stdioIsEnough: waitForStdout != null || waitForStderr != null,
      );
    } catch (_) {
      await server.stop();
      rethrow;
    }
    return server;
  }

  Future<void> _waitUntilReady({
    required _Probe probe,
    required Future<int> exited,
    required Duration timeout,
    required String command,
    required List<Future<void>> stdioSignals,
    required bool stdioIsEnough,
  }) async {
    final deadline = DateTime.now().add(timeout);
    var died = false;
    int? exitCode;
    unawaited(exited.then((code) {
      died = true;
      exitCode = code;
    }).catchError((_) {}));

    final signals = <Future<void>>[...stdioSignals];
    if (!stdioIsEnough) {
      signals.add(probe.pollUntilReady(deadline));
    }
    final ready = signals.isEmpty
        ? Future<void>.value()
        : Future.any(signals.map((f) => f.then((_) {})));

    var reached = false;
    // Uma corrida de tres: pronto, processo morto, ou estouro de prazo. O
    // `Future.any` sozinho deixaria o polling correndo depois da resposta.
    await Future.any<void>([
      ready.then((_) => reached = true),
      exited.then((_) {}),
      Future<void>.delayed(deadline.difference(DateTime.now())),
    ]);
    probe.cancel();

    if (reached) return;

    if (died) {
      throw StateError(
        'o processo do servidor ($command) terminou antes de ficar pronto '
        '(exit code $exitCode).\n${_outputSection()}',
      );
    }
    throw TimeoutException(
      'o servidor nao ficou pronto em ${timeout.inSeconds}s.\n'
      'Comando: $command\n'
      'Sonda: ${probe.describe()}\n'
      'O que fazer: rode o comando a mao e veja se ele sobe; se ele sobe mas '
      'demora (uma primeira compilacao de dart2js leva dezenas de segundos), '
      'aumente o timeout; se a sonda aponta para o bundle e ele nunca aparece, '
      'confira o caminho de readyUrl.\n'
      '${_outputSection()}',
      timeout,
    );
  }

  String _outputSection() {
    final text = output.trim();
    if (text.isEmpty) return 'O servidor nao imprimiu nada.';
    return 'Saida do servidor:\n$text';
  }

  /// Derruba o servidor e so retorna quando a porta estiver livre.
  ///
  /// Nao basta matar o processo que [start] criou. Um comando vai para o shell
  /// (`cmd /c ...` no Windows, `sh -c ...` fora dele) e ferramentas como
  /// `webdev` ainda lancam o servidor de verdade num processo filho: matar so
  /// o pai deixa o neto segurando a porta, e a proxima execucao encontra a
  /// porta ocupada servindo o build anterior. Por isso a arvore inteira morre,
  /// e depois disso ainda se espera a porta ser liberada -- o socket sobrevive
  /// alguns instantes ao processo.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    if (reusedExistingServer || _process == null) return;

    await _killTree(_process.pid);
    await _process.exitCode
        .timeout(_shutdownTimeout, onTimeout: () => -1)
        .catchError((_) => -1);
    await _output?.close();
    try {
      await _scriptDir?.delete(recursive: true);
    } catch (_) {
      // Um script que o shell ainda segura vai embora com a limpeza do TEMP.
    }

    final port = _port;
    if (port == null) return;
    final deadline = DateTime.now().add(_shutdownTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (!await _isPortUsed(port)) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw StateError(
      'a porta $port continua ocupada ${_shutdownTimeout.inSeconds}s depois de '
      'derrubar o servidor "$name"; provavelmente sobrou um processo. '
      'Verifique com `netstat -ano | findstr :$port`.',
    );
  }
}

/// Um comando lancado, com o script temporario que o carrega.
class _LaunchedCommand {
  final Process process;
  final Directory scriptDir;

  _LaunchedCommand(this.process, this.scriptDir);
}

/// Sobe [command] pelo shell, escrevendo-o antes num script temporario.
///
/// Pelo shell para que [command] possa ser a linha que a pessoa escreveria no
/// terminal, com argumentos e tudo -- e, no Windows, para que `webdev` e
/// outros wrappers `.bat` sejam encontrados.
///
/// Por um script, e nao por `cmd /c <comando>`, porque `Process.start` escapa
/// os argumentos que monta para o Windows: uma aspa dentro de [command] chega
/// ao `cmd` como `\"`, e um comando tao banal quanto `"C:\Program
/// Files\dart\bin\dart.exe" run servidor.dart` morre com "nao e reconhecido
/// como um comando interno ou externo". Num script o comando e literal, que e
/// o que o usuario escreveu.
Future<_LaunchedCommand> _spawn(
  String command, {
  String? cwd,
  Map<String, String>? env,
}) async {
  final environment = <String, String>{
    // Impede que um servidor de desenvolvimento abra o navegador do usuario no
    // meio da suite. E o mesmo que o upstream faz.
    'BROWSER': 'none',
    ...?env,
  };
  final dir = await Directory.systemTemp.createTemp('playwright_webserver_');
  final windows = Platform.isWindows;
  final script = File('${dir.path}/${windows ? 'run.cmd' : 'run.sh'}');
  await script.writeAsString(
      windows ? '@echo off\r\n$command\r\n' : '#!/bin/sh\n$command\n');

  // `/d` pula os comandos de AutoRun do registro; sem `/s`, que quebraria um
  // caminho de script com espaco.
  final process = await Process.start(
    windows ? 'cmd.exe' : '/bin/sh',
    windows ? ['/d', '/c', script.path] : [script.path],
    workingDirectory: cwd,
    environment: environment,
    runInShell: false,
  );
  return _LaunchedCommand(process, dir);
}

/// Mata [pid] e toda a sua descendencia.
Future<void> _killTree(int pid) async {
  if (Platform.isWindows) {
    // `/T` inclui a arvore, `/F` nao pede licenca. E a unica forma no Windows:
    // nao ha grupo de processos para sinalizar, e `Process.kill` atinge so o
    // processo nomeado.
    await Process.run('taskkill', ['/pid', '$pid', '/T', '/F'])
        .catchError((_) => ProcessResult(0, 0, '', ''));
    return;
  }
  // Os filhos primeiro: um pai morto reparenta os filhos ao init, e depois
  // disso `pgrep -P` ja nao os encontra.
  for (final child in await _posixChildren(pid)) {
    await _killTree(child);
  }
  try {
    Process.killPid(pid, ProcessSignal.sigterm);
  } catch (_) {
    // Ja morreu.
  }
  await Future<void>.delayed(const Duration(milliseconds: 200));
  try {
    Process.killPid(pid, ProcessSignal.sigkill);
  } catch (_) {
    // Ja morreu.
  }
}

Future<List<int>> _posixChildren(int pid) async {
  try {
    final result = await Process.run('pgrep', ['-P', '$pid']);
    if (result.exitCode != 0) return const [];
    return LineSplitter.split(result.stdout as String)
        .map((line) => int.tryParse(line.trim()))
        .whereType<int>()
        .toList();
  } catch (_) {
    return const [];
  }
}

/// Sonda de prontidao.
class _Probe {
  final bool checkPortOnly;
  final int? port;
  final Uri url;
  final Pattern? body;
  bool _canceled = false;

  _Probe({
    required this.checkPortOnly,
    required this.port,
    required this.url,
    required this.body,
  });

  void cancel() => _canceled = true;

  String describe() {
    if (checkPortOnly) return 'porta $port aceitando conexao';
    final extra = body == null ? '' : ' com corpo casando $body';
    return 'GET $url respondendo 2xx/3xx$extra';
  }

  Future<bool> isReady() async {
    if (checkPortOnly) {
      final p = port;
      return p != null && await _isPortUsed(p);
    }
    return _httpReady();
  }

  /// Poll com atraso crescente, como o upstream (100, 250, 500, depois 1000ms).
  Future<void> pollUntilReady(DateTime deadline) async {
    final schedule = <int>[100, 250, 500];
    while (!_canceled && DateTime.now().isBefore(deadline)) {
      if (await isReady()) return;
      final delay = schedule.isEmpty ? 1000 : schedule.removeAt(0);
      await Future<void>.delayed(Duration(milliseconds: delay));
    }
    // Sem prontidao dentro do prazo: quem chamou trata o estouro.
    await Completer<void>().future;
  }

  Future<bool> _httpReady() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.getUrl(url);
      request.headers.set(HttpHeaders.acceptHeader, '*/*');
      // Sem cache: um `webdev` que ainda nao terminou o build serve o bundle
      // anterior com 200, e um 304 do cliente o esconderia por completo.
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      final response = await request.close().timeout(
            const Duration(seconds: 10),
          );
      // A faixa e a do upstream: 2xx e 3xx contam, 404 nao. Um 404 e
      // exatamente o que um bundle ainda nao compilado devolve.
      final ok = response.statusCode >= 200 && response.statusCode < 400;
      if (!ok || body == null) {
        await response.drain<void>();
        return ok;
      }
      final text = await response
          .transform(const Utf8Decoder(allowMalformed: true))
          .join()
          .timeout(const Duration(seconds: 10));
      // Um corpo vazio com 200 e o caso classico do artefato "existe mas ainda
      // esta sendo escrito".
      return text.isNotEmpty && text.contains(body!);
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }
}

Future<bool> _isPortUsed(int port) async {
  // As duas familias: um servidor que so escuta em `::1` nao aparece em
  // `127.0.0.1` e vice-versa.
  for (final host in const ['127.0.0.1', '::1']) {
    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(milliseconds: 500),
      );
      socket.destroy();
      return true;
    } catch (_) {
      // Proxima familia.
    }
  }
  return false;
}

/// Guarda as ultimas linhas que o servidor imprimiu.
class _OutputBuffer {
  static const _maxLines = 200;

  final String name;
  final bool echo;
  final List<String> _lines = [];
  final List<StreamSubscription<String>> _subs = [];

  _OutputBuffer({required this.name, required this.echo});

  String get text => _lines.join('\n');

  void attach(
    Stream<List<int>> stream, {
    RegExp? waitFor,
    required void Function() onMatch,
  }) {
    final buffer = StringBuffer();
    final sub = stream
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) {
      _lines.add(line);
      if (_lines.length > _maxLines) _lines.removeAt(0);
      if (echo) stdout.writeln('[$name] $line');
      if (waitFor == null) return;
      buffer.writeln(line);
      if (waitFor.hasMatch(buffer.toString())) onMatch();
    }, onError: (_) {});
    _subs.add(sub);
  }

  Future<void> close() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
  }
}

void _completeOnce(Completer<void> completer) {
  if (!completer.isCompleted) completer.complete();
}

bool _boolEnv(String? value) {
  if (value == null) return false;
  final v = value.toLowerCase();
  return v.isNotEmpty && v != '0' && v != 'false';
}
