import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:playwright_core/src/server/video/core_video.dart';
import 'package:test/test.dart';

/// The video artifact on its own, without a browser.
///
/// The lifecycle is the whole point of the class — a path handed out too early
/// names a half-written file, and a recording that never reports itself
/// finished hangs the caller forever — so it is checked here where every
/// ending can actually be produced on demand, including the ones a real
/// browser will not perform to order.
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('pw-dart-video-unit-');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  String pathIn(String name) => p.join(dir.path, name);

  /// A file standing in for what the recorder writes.
  File write(String name, String contents) =>
      File(pathIn(name))..writeAsStringSync(contents);

  test('path() espera o fim da gravacao', () async {
    final video = CoreVideo(pathIn('a.webm'));
    final stopped = Completer<void>();
    video.attachRecording(() => stopped.future);

    var resolved = false;
    final path = video.pathAfterFinished().then((value) {
      resolved = true;
      return value;
    });

    unawaited(video.finish());
    // Several turns of the event loop: if `path()` were resolving on its own
    // it would have done so by now.
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(resolved, isFalse,
        reason: 'path() resolveu antes de a gravacao terminar');

    write('a.webm', 'video');
    stopped.complete();
    expect(await path, pathIn('a.webm'));
  });

  test('path() falha com o erro da gravacao em vez de pendurar', () async {
    final video = CoreVideo(pathIn('b.webm'));
    video
        .attachRecording(() => Future<void>.error(StateError('ffmpeg morreu')));

    unawaited(video.finish());
    await expectLater(video.pathAfterFinished(), throwsA(isA<StateError>()));
    // E a falha fica: uma segunda espera nao pode voltar a pendurar.
    await expectLater(video.pathAfterFinished(), throwsA(isA<StateError>()));
  });

  test('uma gravacao que nunca para vira erro, nao espera eterna', () async {
    final video = CoreVideo(pathIn('c.webm'));
    // Nunca completa: o encoder travou.
    video.attachRecording(() => Completer<void>().future);

    unawaited(video.finish());
    await expectLater(
      video.pathAfterFinished().timeout(kVideoFinalizeTimeout * 2),
      throwsA(isA<TimeoutException>()),
    );
  }, timeout: Timeout(kVideoFinalizeTimeout * 3));

  test('path() sem gravacao nenhuma falha em vez de pendurar', () async {
    final video = CoreVideo(pathIn('d.webm'));
    unawaited(video.finish());
    await expectLater(video.pathAfterFinished(), throwsA(isA<StateError>()));
  });

  test('finish() e idempotente e so para a gravacao uma vez', () async {
    final video = CoreVideo(pathIn('e.webm'));
    var stops = 0;
    video.attachRecording(() async => stops++);

    await Future.wait([video.finish(), video.finish(), video.finish()]);
    await video.finish();
    expect(stops, 1);
    expect(video.isFinished, isTrue);
  });

  test('saveAs espera o fim e copia os bytes', () async {
    final video = CoreVideo(pathIn('f.webm'));
    final stopped = Completer<void>();
    video.attachRecording(() => stopped.future);

    var saved = false;
    final target = pathIn('out/saved.webm');
    final save = video.saveAs(target).then((_) => saved = true);

    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    unawaited(video.finish());
    expect(saved, isFalse, reason: 'saveAs copiou antes do arquivo fechar');

    write('f.webm', 'conteudo completo');
    stopped.complete();
    await save;
    expect(File(target).readAsStringSync(), 'conteudo completo');
  });

  test('saveAs depois de delete() falha em vez de escrever nada', () async {
    final video = CoreVideo(pathIn('g.webm'));
    write('g.webm', 'x');
    video.attachRecording(() async {});
    await video.finish();

    await video.delete();
    expect(File(pathIn('g.webm')).existsSync(), isFalse);
    expect(video.isDeleted, isTrue);
    await expectLater(
        video.saveAs(pathIn('nope.webm')), throwsA(isA<StateError>()));
  });

  test('delete() espera o fim da gravacao', () async {
    final video = CoreVideo(pathIn('h.webm'));
    final stopped = Completer<void>();
    video.attachRecording(() => stopped.future);
    write('h.webm', 'ainda gravando');

    var deleted = false;
    final delete = video.delete().then((_) => deleted = true);
    unawaited(video.finish());
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(deleted, isFalse, reason: 'delete() apagou o arquivo em uso');
    expect(File(pathIn('h.webm')).existsSync(), isTrue);

    stopped.complete();
    await delete;
    expect(File(pathIn('h.webm')).existsSync(), isFalse);
  });

  test('delete() duas vezes nao falha', () async {
    final video = CoreVideo(pathIn('i.webm'));
    write('i.webm', 'x');
    video.attachRecording(() async {});
    await video.finish();
    await video.delete();
    await video.delete();
    expect(File(pathIn('i.webm')).existsSync(), isFalse);
  });
}
