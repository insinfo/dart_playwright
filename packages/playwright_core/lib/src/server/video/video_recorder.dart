// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/playwright-core/src/server/videoRecorder.ts
// (a classe `FfmpegVideoRecorder`)

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:playwright_protocol/playwright_protocol.dart';

import '../../registry/registry.dart';
import 'ebml.dart';
import 'mjpeg_writer.dart';
import 'video_frame.dart';

/// Quanto o ffmpeg pode ficar devendo antes de o gravador comecar a descartar
/// quadros.
///
/// Numa maquina com a CPU cheia o VP8 nao acompanha o screencast, e o pipe
/// enche. Sem um teto a fila cresce sem limite e o processo Dart morre por
/// memoria antes de o video ficar pronto. Descartar um quadro custa apenas que
/// o quadro anterior fique mais tempo na tela — o Matroska carrega o timestamp
/// de cada quadro, entao a duracao do video nao muda.
const _maxQueuedBytes = 16 * 1024 * 1024;

/// Quanto tempo o ultimo quadro fica na tela ao parar a gravacao.
///
/// Sem isso o video termina no instante do ultimo quadro, que num teste ou num
/// `page.close()` logo apos uma acao significa um arquivo que acaba antes de
/// dar para ver o que aconteceu. O upstream usa o mesmo minimo de 1s.
const _minTrailingFrameMs = 1000;

/// Quanto esperar o ffmpeg fechar o arquivo depois de o stdin ser fechado.
const _closeTimeout = Duration(seconds: 30);

/// Grava quadros de screencast num arquivo .webm (VP8) via ffmpeg.
///
/// Cada quadro MJPEG e embrulhado num Cluster Matroska com o seu timestamp e
/// empurrado para o stdin do ffmpeg; e o ffmpeg, com `-r fps` na saida, que
/// duplica quadros quando a pagina fica parada. Ver [ebml.dart].
class VideoRecorder {
  final Process _process;
  final IOSink _stdin;
  final String outputPath;
  final int width;
  final int height;
  final int fps;

  /// stderr do ffmpeg, guardado para virar mensagem de erro no [stop].
  final StringBuffer _stderr = StringBuffer();
  late final Future<void> _stderrDone;

  final Queue<Uint8List> _queue = Queue<Uint8List>();
  int _queuedBytes = 0;
  Future<void>? _pump;

  Uint8List? _lastFrame;
  int _lastTimestampMs = 0;
  bool _stopped = false;
  Future<void>? _stopping;
  Object? _failure;

  int _droppedOutOfOrder = 0;
  int _droppedForBackpressure = 0;

  VideoRecorder._({
    required Process process,
    required this.outputPath,
    required this.width,
    required this.height,
    required this.fps,
  })  : _process = process,
        _stdin = process.stdin {
    _stderrDone = process.stderr
        .fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk)).then(
            (bytes) => _stderr.write(String.fromCharCodes(bytes)));
    _stdin.done.catchError((Object e) {
      // O ffmpeg pode morrer com o pipe cheio; o erro do sink e ruido, o que
      // importa e o codigo de saida, lido no [stop].
      _failure ??= e;
    });
  }

  /// Sobe o ffmpeg e devolve um gravador pronto para receber quadros.
  ///
  /// [width] e [height] sao arredondados para baixo ate ficarem pares, porque o
  /// filtro `pad` recusa uma dimensao impar num formato com croma subamostrado
  /// ("Padded dimensions cannot be smaller than input dimensions") e o video
  /// sai vazio. O upstream faz o mesmo arredondamento, no screencast.
  static Future<VideoRecorder> start({
    required String outputPath,
    required int width,
    required int height,
    int fps = 25,
  }) async {
    if (!outputPath.endsWith('.webm')) {
      throw PlaywrightException('File must have .webm extension: $outputPath');
    }
    if (fps <= 0) {
      throw PlaywrightException('fps must be positive, got $fps');
    }
    final evenWidth = _roundDownToEven(width);
    final evenHeight = _roundDownToEven(height);

    // Isto gosta de lancar excecao; que lance antes de qualquer processo subir.
    final ffmpegPath = BrowserRegistry().ffmpegExecutablePathOrDie();
    await Directory(p.dirname(p.absolute(outputPath))).create(recursive: true);

    final process = await Process.start(
        ffmpegPath, _buildArgs(evenWidth, evenHeight, fps, outputPath));
    final recorder = VideoRecorder._(
      process: process,
      outputPath: outputPath,
      width: evenWidth,
      height: evenHeight,
      fps: fps,
    );
    recorder._enqueue(writeHeader());
    return recorder;
  }

  /// Como afinar o codec:
  /// 1. A documentacao do vp8 explica as opcoes.
  ///   https://www.webmproject.org/docs/encoder-parameters/
  /// 2. `ffmpeg -h encoder=vp8` mapeia essas opcoes para argumentos.
  /// 3. Mais sobre passar opcoes de vp8 ao ffmpeg:
  ///   https://trac.ffmpeg.org/wiki/Encode/VP8
  ///
  /// As opcoes de vp8 sao as do upstream:
  ///   "-qmin 0 -qmax 50" — variacao de qualidade de 0 a 50.
  ///   "-crf 8" — modo de qualidade constante, 4-63, menor e melhor.
  ///   "-deadline realtime -speed 8" — nao gastar CPU demais, para acompanhar
  ///     os quadros que chegam.
  ///   "-b:v 1M" — taxa de bits; o padrao e baixo demais para vp8.
  ///   "-threads 1" — uma thread so reduz muito o travamento quando a CPU esta
  ///     sobrecarregada; por padrao o vp8 tenta usar todas.
  ///
  /// "-f matroska -i pipe:0" le a entrada da stdin como Matroska, e
  /// "-fpsprobesize 0 -probesize 32 -analyzeduration 0" reduz o buffer inicial
  /// da analise. "-avioflags direct" NAO pode entrar aqui: ele desliga o buffer
  /// de entrada de que o demuxer de Matroska precisa e quebra o cabecalho.
  ///
  /// "-r fps" na saida forca taxa constante: o ffmpeg duplica quadros conforme
  /// os timestamps da entrada, entao nao repetimos quadros por conta propria.
  ///
  /// O filtro difere do upstream numa coisa: o upstream usa
  /// `pad=W:H:0:0:gray,crop=W:H:0:0`, que so funciona porque la o screencast
  /// pede ao navegador exatamente W×H. Aqui os quadros vem de outra camada e
  /// podem ser maiores que o alvo — uma pagina de largura impar, por exemplo —,
  /// e `pad` para um tamanho menor que a entrada e um erro fatal. Recortar
  /// antes, com `min(iw,W)`, aceita quadro maior; o `pad` seguinte continua
  /// cobrindo o quadro menor.
  static List<String> _buildArgs(
      int width, int height, int fps, String outputPath) {
    return ('-loglevel error -f matroska -fpsprobesize 0 -probesize 32 '
            '-analyzeduration 0 -i pipe:0 -y -an -r $fps -c:v vp8 -qmin 0 '
            '-qmax 50 -crf 8 -deadline realtime -speed 8 -b:v 1M -threads 1 '
            '-vf')
        .split(' ')
      // A barra invertida e do ffmpeg, nao do Dart: sem ela o parser de
      // filtergraph corta a expressao na virgula de `min` e ve dois filtros.
      ..add('crop=min(iw\\,$width):min(ih\\,$height):0:0,'
          'pad=$width:$height:0:0:gray')
      ..add(outputPath);
  }

  static int _roundDownToEven(int value) {
    final even = value & ~1;
    // O vp8 nao aceita dimensao zero, e o `pad` tambem nao.
    return even < 2 ? 2 : even;
  }

  /// Numero de quadros descartados por chegarem fora de ordem ou repetidos.
  int get droppedOutOfOrderFrames => _droppedOutOfOrder;

  /// Numero de quadros descartados porque o ffmpeg nao consumia no ritmo.
  int get droppedForBackpressureFrames => _droppedForBackpressure;

  /// Não bloqueia. Quadros fora de ordem ou repetidos são tratados aqui.
  void writeFrame(VideoFrame frame) {
    if (_stopped || _failure != null) return;

    if (frame.format != VideoFrameFormat.jpeg) {
      // A build de ffmpeg que a Playwright publica so traz o decodificador
      // MJPEG, entao um quadro PNG so produziria "Unknown decoder". Falhar
      // aqui e mudo (writeFrame nao pode lancar), entao o erro fica guardado
      // para o [stop] — o gravador ja nao vai produzir um video util.

      _failure ??= PlaywrightException(
          'VideoRecorder only accepts JPEG frames: the ffmpeg build shipped by '
          'Playwright has no PNG decoder. Ask the screencast for JPEG.');
      return;
    }
    if (frame.data.isEmpty) return;

    final timestampMs = frame.timestamp.inMilliseconds;
    // Os Clusters de um Matroska tem de ter timestamp nao decrescente; um
    // quadro atrasado ou repetido escrito assim mesmo quebraria o demuxer.
    if (timestampMs < 0 ||
        (_lastFrame != null && timestampMs <= _lastTimestampMs)) {
      _droppedOutOfOrder++;
      return;
    }

    final clusterHeader = writeClusterHeader(timestampMs, frame.data.length);
    if (_queuedBytes + clusterHeader.length + frame.data.length >
        _maxQueuedBytes) {
      _droppedForBackpressure++;
      return;
    }

    _lastFrame = frame.data;
    _lastTimestampMs = timestampMs;
    _enqueue(clusterHeader);
    _enqueue(frame.data);
  }

  void _enqueue(Uint8List chunk) {
    _queue.add(chunk);
    _queuedBytes += chunk.length;
    _pump ??= _drain().whenComplete(() => _pump = null);
  }

  /// Escoa a fila respeitando a contrapressao: um `flush` por bloco espera o
  /// sistema aceitar os bytes antes de o proximo ser oferecido.
  Future<void> _drain() async {
    while (_queue.isNotEmpty) {
      final chunk = _queue.removeFirst();
      _queuedBytes -= chunk.length;
      try {
        _stdin.add(chunk);
        await _stdin.flush();
      } catch (e) {
        _failure ??= e;
        _queue.clear();
        _queuedBytes = 0;
        return;
      }
    }
  }

  Future<void> stop() => _stopping ??= _stop();

  Future<void> _stop() async {
    _stopped = true;

    if (_failure == null) {
      // O ffmpeg so cria o arquivo depois de receber alguma entrada: uma
      // gravacao sem nenhum quadro ainda precisa produzir um .webm.
      if (_lastFrame == null) {
        _lastFrame = encodeSolidJpeg(width, height);
        _lastTimestampMs = 0;
        _enqueue(writeClusterHeader(0, _lastFrame!.length));
        _enqueue(_lastFrame!);
      }
      // Repete o ultimo quadro adiante no tempo para ele ter duracao propria.
      final trailingMs = _lastTimestampMs + _minTrailingFrameMs;
      _enqueue(writeClusterHeader(trailingMs, _lastFrame!.length));
      _enqueue(_lastFrame!);
    }

    while (_pump != null) {
      await _pump;
    }

    try {
      await _stdin.close();
    } catch (e) {
      _failure ??= e;
    }

    // Esperar o processo sair e o que garante o arquivo fechado: o ffmpeg so
    // escreve o Cues e o tamanho do Segment do webm no encerramento, e matar o
    // processo antes disso deixa um arquivo truncado que nenhum player abre.
    int exitCode;
    try {
      exitCode = await _process.exitCode.timeout(_closeTimeout);
    } on TimeoutException {
      _process.kill(ProcessSignal.sigkill);
      await _process.exitCode;
      throw PlaywrightException(
          'ffmpeg did not finish writing $outputPath within '
          '${_closeTimeout.inSeconds}s and was killed; the file is truncated.');
    }
    await _stderrDone;

    if (_failure != null) {
      final failure = _failure;
      _failure = null;
      throw PlaywrightException('Video recording failed: $failure'
          '${_stderrSuffix()}');
    }
    if (exitCode != 0) {
      throw PlaywrightException(
          'ffmpeg exited with code $exitCode while writing $outputPath'
          '${_stderrSuffix()}');
    }
  }

  String _stderrSuffix() {
    final text = _stderr.toString().trim();
    return text.isEmpty ? '' : '\n$text';
  }
}
