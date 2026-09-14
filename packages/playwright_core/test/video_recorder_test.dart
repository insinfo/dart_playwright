// Testa a fatia "quadro -> .webm" sem navegador nenhum: os quadros sao JPEGs
// sinteticos e o arquivo resultante e lido de volta com o ffmpeg/ffprobe.

import 'dart:io';
import 'dart:typed_data';

import 'package:playwright_core/src/registry/registry.dart';
import 'package:playwright_core/src/server/video/mjpeg_writer.dart';
import 'package:playwright_core/src/server/video/video_frame.dart';
import 'package:playwright_core/src/server/video/video_recorder.dart';
import 'package:test/test.dart';

/// Um quadro com um retangulo preto que anda para a direita, sobre branco.
VideoFrame movingRectangle({
  required int width,
  required int height,
  required int index,
  required Duration timestamp,
  VideoFrameFormat format = VideoFrameFormat.jpeg,
}) {
  final blocksX = (width + 7) ~/ 8;
  final left = index % (blocksX > 3 ? blocksX - 3 : 1);
  final data = encodeBlockJpeg(
    width: width,
    height: height,
    luma: (bx, by) =>
        (bx >= left && bx < left + 3 && by >= 1 && by < 4) ? 0 : 255,
  );
  return VideoFrame(
    data: data,
    format: format,
    width: width,
    height: height,
    timestamp: timestamp,
  );
}

/// O que se consegue ler de volta de um .webm.
class ProbeResult {
  final int width;
  final int height;
  final double duration;
  final int? frameCount;
  const ProbeResult(this.width, this.height, this.duration, this.frameCount);

  @override
  String toString() =>
      '${width}x$height, ${duration}s, ${frameCount ?? '?'} frames';
}

String? _findFfprobe() {
  final fromEnv = Platform.environment['FFPROBE_PATH'];
  if (fromEnv != null && File(fromEnv).existsSync()) return fromEnv;
  final name = Platform.isWindows ? 'ffprobe.exe' : 'ffprobe';
  for (final dir in (Platform.environment['PATH'] ?? '')
      .split(Platform.isWindows ? ';' : ':')) {
    if (dir.isEmpty) continue;
    final candidate = File('$dir${Platform.pathSeparator}$name');
    if (candidate.existsSync()) return candidate.path;
  }
  return null;
}

/// Le dimensoes, duracao e numero de quadros do arquivo.
///
/// O `ffprobe` da a contagem exata de quadros decodificados; a build de ffmpeg
/// que a Playwright publica nao o inclui (nem o muxer `null`, que permitiria
/// contar com o proprio ffmpeg), entao sem ele sobram dimensoes e duracao,
/// lidas do stderr de `ffmpeg -i`.
Future<ProbeResult> probe(String path) async {
  final ffprobe = _findFfprobe();
  if (ffprobe != null) {
    final result = await Process.run(ffprobe, [
      '-v',
      'error',
      '-select_streams',
      'v:0',
      '-count_frames',
      '-show_entries',
      'stream=width,height,nb_read_frames:format=duration',
      '-of',
      'default=noprint_wrappers=1',
      path,
    ]);
    if (result.exitCode != 0) {
      throw StateError('ffprobe failed: ${result.stderr}');
    }
    final fields = <String, String>{};
    for (final line in (result.stdout as String).split('\n')) {
      final i = line.indexOf('=');
      if (i > 0)
        fields[line.substring(0, i).trim()] = line.substring(i + 1).trim();
    }
    return ProbeResult(
      int.parse(fields['width']!),
      int.parse(fields['height']!),
      double.parse(fields['duration']!),
      int.tryParse(fields['nb_read_frames'] ?? ''),
    );
  }

  final ffmpeg = BrowserRegistry().ffmpegExecutablePathOrDie();
  final result = await Process.run(ffmpeg, ['-hide_banner', '-i', path]);
  final text = '${result.stdout}${result.stderr}';
  final size = RegExp(r'Video: vp8.*?, (\d+)x(\d+)').firstMatch(text);
  final duration = RegExp(r'Duration: (\d+):(\d+):(\d+\.\d+)').firstMatch(text);
  if (size == null || duration == null) {
    throw StateError('could not parse ffmpeg output:\n$text');
  }
  final seconds = int.parse(duration.group(1)!) * 3600 +
      int.parse(duration.group(2)!) * 60 +
      double.parse(duration.group(3)!);
  return ProbeResult(
      int.parse(size.group(1)!), int.parse(size.group(2)!), seconds, null);
}

void main() {
  late Directory tempDir;
  late String outputPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('playwright_video_mux_');
    outputPath = '${tempDir.path}${Platform.pathSeparator}out.webm';
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('ffmpeg is registered for this platform', () {
    final registry = BrowserRegistry();
    final path = registry.executablePath('ffmpeg');
    expect(path, isNotNull, reason: 'the registry must know where ffmpeg goes');
    // Sem esta entrada o `install` morre com "ffmpeg is not available for
    // win-x64" e o gravador nunca chega a rodar nesta maquina.
    expect(registry.downloadUrl('ffmpeg'), isNotNull,
        reason: 'ffmpeg must be downloadable on ${Platform.operatingSystem}');
    expect(registry.downloadUrl('ffmpeg'), contains('builds/ffmpeg/'));
    expect(registry.isInstalled('ffmpeg'), isTrue,
        reason: 'run `dart run playwright install ffmpeg` first');
    expect(registry.ffmpegExecutablePathOrDie(), path);
  });

  test('encodes a stream of frames into a playable webm', () async {
    final recorder = await VideoRecorder.start(
        outputPath: outputPath, width: 160, height: 120);
    for (var i = 0; i < 50; i++) {
      recorder.writeFrame(movingRectangle(
        width: 160,
        height: 120,
        index: i,
        timestamp: Duration(milliseconds: i * 40),
      ));
    }
    await recorder.stop();

    final result = await probe(outputPath);
    printOnFailure('probe: $result');
    expect(result.width, 160);
    expect(result.height, 120);
    // 49 * 40ms de quadros mais 1s do ultimo quadro no fim. Medido nesta
    // maquina: 2.96s e 74 quadros.
    expect(result.duration, closeTo(2.96, 0.25));
    if (result.frameCount != null) {
      expect(result.frameCount, closeTo(74, 3));
    }
  });

  test('rounds odd dimensions down to even', () async {
    // Uma pagina de 101 de largura entrega quadros de 101 de largura; sem o
    // arredondamento o filtro `pad` do ffmpeg aborta e nada e escrito.
    final recorder = await VideoRecorder.start(
        outputPath: outputPath, width: 101, height: 63);
    expect(recorder.width, 100);
    expect(recorder.height, 62);
    for (var i = 0; i < 25; i++) {
      recorder.writeFrame(movingRectangle(
        width: 101,
        height: 63,
        index: i,
        timestamp: Duration(milliseconds: i * 40),
      ));
    }
    await recorder.stop();

    final result = await probe(outputPath);
    printOnFailure('probe: $result');
    expect(result.width, 100);
    expect(result.height, 62);
    expect(result.width.isEven, isTrue);
    expect(result.height.isEven, isTrue);
  });

  test('fills the gaps when frames arrive slower than the fps', () async {
    final recorder = await VideoRecorder.start(
        outputPath: outputPath, width: 64, height: 48, fps: 25);
    // Tres quadros em dois segundos: 1/25 do que 25fps pediria.
    for (var i = 0; i < 3; i++) {
      recorder.writeFrame(movingRectangle(
        width: 64,
        height: 48,
        index: i,
        timestamp: Duration(seconds: i),
      ));
    }
    await recorder.stop();

    final result = await probe(outputPath);
    printOnFailure('probe: $result');
    // 2s entre o primeiro e o ultimo quadro, mais 1s de cauda, mais o que o
    // ffmpeg da de duracao ao quadro final — ele a estima pelos primeiros
    // intervalos da entrada, e aqui o primeiro intervalo e de 1s. Medido nesta
    // maquina: 3.96s e 99 quadros. O limite de baixo e o que interessa: com 3
    // quadros de entrada o video tem de passar dos 3 segundos, nao congelar em
    // 3 quadros.
    expect(result.duration, inInclusiveRange(3.0, 4.5));
    if (result.frameCount != null) {
      expect(result.frameCount, greaterThan(70));
    }
  });

  test('honours a non-default fps', () async {
    final recorder = await VideoRecorder.start(
        outputPath: outputPath, width: 64, height: 48, fps: 10);
    for (var i = 0; i < 20; i++) {
      recorder.writeFrame(movingRectangle(
        width: 64,
        height: 48,
        index: i,
        timestamp: Duration(milliseconds: i * 100),
      ));
    }
    await recorder.stop();

    final result = await probe(outputPath);
    printOnFailure('probe: $result');
    if (result.frameCount != null) {
      // 1.9s de quadros mais 1s de cauda, a 10fps. Medido nesta maquina:
      // 2.9s e 29 quadros; a 25fps seriam mais de 70.
      expect(result.frameCount, lessThan(40));
      expect(result.frameCount! / result.duration, closeTo(10, 1));
    }
  });

  test('drops out-of-order and duplicate frames', () async {
    final recorder = await VideoRecorder.start(
        outputPath: outputPath, width: 64, height: 48);
    VideoFrame at(int ms) => movingRectangle(
        width: 64,
        height: 48,
        index: ms ~/ 40,
        timestamp: Duration(milliseconds: ms));

    recorder.writeFrame(at(0));
    recorder.writeFrame(at(400));
    recorder.writeFrame(at(200)); // atrasado
    recorder.writeFrame(at(400)); // repetido
    recorder.writeFrame(at(800));
    await recorder.stop();

    expect(recorder.droppedOutOfOrderFrames, 2);
    final result = await probe(outputPath);
    printOnFailure('probe: $result');
    // Os quadros aceitos vao de 0 a 800ms, mais 1s de cauda. Medido nesta
    // maquina: 2.16s e 54 quadros — a sobra e a duracao que o ffmpeg atribui
    // ao quadro final.
    expect(result.duration, inInclusiveRange(1.8, 2.6));
  });

  test('produces a file even when no frame ever arrives', () async {
    final recorder = await VideoRecorder.start(
        outputPath: outputPath, width: 64, height: 48);
    await recorder.stop();

    expect(File(outputPath).existsSync(), isTrue);
    final result = await probe(outputPath);
    printOnFailure('probe: $result');
    expect(result.width, 64);
    expect(result.height, 48);
    expect(result.duration, greaterThan(0.9));
  });

  test('creates the output directory', () async {
    final nested =
        '${tempDir.path}${Platform.pathSeparator}a${Platform.pathSeparator}b.webm';
    final recorder =
        await VideoRecorder.start(outputPath: nested, width: 64, height: 48);
    recorder.writeFrame(movingRectangle(
        width: 64, height: 48, index: 0, timestamp: Duration.zero));
    await recorder.stop();
    expect(File(nested).existsSync(), isTrue);
  });

  test('refuses a non-webm output path', () {
    expect(
      VideoRecorder.start(
          outputPath: '${tempDir.path}${Platform.pathSeparator}out.mp4',
          width: 64,
          height: 48),
      throwsA(isA<Exception>()),
    );
  });

  test('reports PNG frames as unsupported instead of writing garbage',
      () async {
    final recorder = await VideoRecorder.start(
        outputPath: outputPath, width: 64, height: 48);
    recorder.writeFrame(VideoFrame(
      data:
          Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
      format: VideoFrameFormat.png,
      width: 64,
      height: 48,
      timestamp: Duration.zero,
    ));
    await expectLater(recorder.stop(),
        throwsA(predicate((Object e) => '$e'.contains('JPEG'))));
  });

  test('does not grow without bound when ffmpeg cannot keep up', () async {
    final recorder = await VideoRecorder.start(
        outputPath: outputPath, width: 320, height: 240);
    // Cada quadro leva ~1.5 MB de preenchimento; 30 deles sao ~45 MB, bem
    // acima do teto da fila. O gravador tem de descartar em vez de acumular.
    final padding = Uint8List(1500 * 1024);
    for (var i = 0; i < 30; i++) {
      final real = movingRectangle(
          width: 320,
          height: 240,
          index: i,
          timestamp: Duration(milliseconds: i * 40));
      final fat = Uint8List(real.data.length + padding.length)
        ..setRange(0, real.data.length, real.data)
        ..setRange(
            real.data.length, real.data.length + padding.length, padding);
      recorder.writeFrame(VideoFrame(
        data: fat,
        format: VideoFrameFormat.jpeg,
        width: 320,
        height: 240,
        timestamp: real.timestamp,
      ));
    }
    expect(recorder.droppedForBackpressureFrames, greaterThan(0),
        reason: 'the queue must have a ceiling');
    await recorder.stop();
    expect(File(outputPath).existsSync(), isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
