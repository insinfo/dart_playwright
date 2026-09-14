import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';

import 'package:playwright/playwright.dart';
import 'package:test/test.dart';

import 'test_server.dart';

/// `recordVideo`, `page.video()` and the artifact lifecycle, on all three
/// engines.
///
/// What is being checked here is *when* the file is ready, not that a file
/// appeared: a recorder that hands back a path while it is still writing into
/// it produces a truncated video and a test that passes. So every case pins
/// down an ordering — the path future does not resolve while the page is
/// alive, `saveAs` still works once the context is gone, an ending nobody
/// asked for (a crash, a window closing itself) still finishes the file
/// instead of leaving the future hanging forever.
///
/// The screencast and the muxer underneath are stand-ins until their own
/// slices land; the lifecycle above them is real and is what these tests
/// exercise. Nothing here asserts anything about the *format* of the file,
/// only about when it is complete — that is what survives the real encoder
/// replacing the stub.
void main() {
  group('Video', () {
    late Playwright playwright;
    late TestServer server;
    late Directory outputDir;

    setUpAll(() async {
      server = await TestServer.start();
      playwright = await Playwright.create();
      outputDir = Directory.systemTemp.createTempSync('pw-dart-video-test-');
    });

    tearDownAll(() async {
      await server.stop();
      if (outputDir.existsSync()) {
        try {
          outputDir.deleteSync(recursive: true);
        } catch (_) {
          // A recorder that outlived the test still holds its file open on
          // Windows; leave it to the TEMP sweeper rather than fail the run.
        }
      }
    });

    var ordinal = 0;
    Directory nextDir() =>
        Directory('${outputDir.path}/videos-${ordinal++}')..createSync();

    /// Waits until [file] holds more than [threshold] bytes and returns the
    /// size it reached.
    ///
    /// Not a fixed delay: it stops on an observable fact — the recorder has
    /// written — with a deadline only as a failure mode. Which is what keeps
    /// these tests meaningful when the encoder underneath changes pace.
    Future<int> sizeAbove(File file, int threshold,
        {Duration timeout = const Duration(seconds: 40)}) async {
      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        final size = file.existsSync() ? file.lengthSync() : 0;
        if (size > threshold) return size;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      throw StateError(
          'o gravador nao passou de $threshold bytes em ${file.path}');
    }

    /// A recorded page that actually paints.
    ///
    /// The engines only emit a screencast frame when the page paints, so a
    /// page left on `about:blank` produces almost nothing and the file does
    /// not grow while it is open. That is not a quirk of these tests, it is
    /// the rule of the screencast: measured on this port, three seconds of
    /// Chromium on a static page yields **one** frame, against 179 on one
    /// that animates.
    ///
    /// These tests used to open a bare page because the stand-in backend
    /// polled screenshots and produced frames regardless of what the page was
    /// doing. The engine backends do not, so anything asserting that the
    /// recorder wrote has to record a page that gives it something to write.
    Future<Page> recordedPage(BrowserContext context) async {
      final page = await recordedPage(context);
      await page.goto(server.url('/animated'));
      return page;
    }

    /// The video files [dir] holds, once the recorder has created [count] of
    /// them. They appear a moment after the page does, because opening the
    /// file is asynchronous.
    Future<List<File>> videoFilesIn(Directory dir, {int count = 1}) async {
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (DateTime.now().isBefore(deadline)) {
        final files = dir.listSync().whereType<File>().toList();
        if (files.length >= count) return files;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      throw StateError('menos de $count arquivos de video em ${dir.path}');
    }

    Future<File> videoFileIn(Directory dir) async =>
        (await videoFilesIn(dir)).single;

    for (final browserName in ['chromium', 'firefox', 'webkit']) {
      group('[$browserName]', () {
        late Browser browser;
        var browserLaunched = false;

        setUpAll(() async {
          browser = await switch (browserName) {
            'chromium' => playwright.chromium.launch(headless: true),
            'firefox' => playwright.firefox.launch(headless: true),
            _ => playwright.webkit.launch(headless: true),
          };
          browserLaunched = true;
        });

        tearDownAll(() async {
          if (browserLaunched) await browser.close();
        });

        Future<BrowserContext> recordingContext(Directory dir) =>
            browser.newContext(
              viewport: (width: 640, height: 480),
              recordVideo: RecordVideoOptions(dir: dir.path),
            );

        test('sem recordVideo a pagina nao tem video', () async {
          final context =
              await browser.newContext(viewport: (width: 640, height: 480));
          try {
            final page = await recordedPage(context);
            expect(page.video(), isNull);
          } finally {
            await context.close();
          }
        });

        test('page.video() existe antes de a pagina fechar, e e o mesmo objeto',
            () async {
          final dir = nextDir();
          final context = await recordingContext(dir);
          try {
            final page = await recordedPage(context);
            final video = page.video();
            expect(video, isNotNull);
            // Duas chamadas tem de devolver o mesmo objeto: codigo de usuario
            // compara identidade, como faz com `context.pages()`.
            expect(identical(page.video(), video), isTrue);
          } finally {
            await context.close();
          }
        });

        test(
            'path() so resolve depois que a pagina fecha, e nunca durante a '
            'escrita', () async {
          final dir = nextDir();
          final context = await recordingContext(dir);
          final page = await recordedPage(context);
          final video = page.video()!;

          var resolved = false;
          final pathFuture = video.path().then((value) {
            resolved = true;
            return value;
          });

          final file = await videoFileIn(dir);
          // Duas leituras crescentes: a segunda prova que o gravador ainda
          // estava escrevendo no arquivo. Qualquer caminho entregue entre elas
          // apontaria para um video cortado no meio.
          final firstBytes = await sizeAbove(file, 0);
          final secondBytes = await sizeAbove(file, firstBytes);
          expect(secondBytes, greaterThan(firstBytes));
          expect(resolved, isFalse,
              reason: 'path() resolveu com a pagina aberta e o arquivo ainda '
                  'sendo escrito');

          await page.close();
          final path = await pathFuture.timeout(const Duration(seconds: 60));
          expect(resolved, isTrue);
          expect(path, file.path);

          final finished = File(path);
          expect(finished.existsSync(), isTrue);
          expect(finished.lengthSync(), greaterThanOrEqualTo(secondBytes));

          // E esta estavel: ninguem continua escrevendo nele.
          final settled = finished.lengthSync();
          await Future<void>.delayed(const Duration(milliseconds: 500));
          expect(finished.lengthSync(), settled);

          await context.close();
        });

        test('fechar o contexto finaliza o video das paginas ainda abertas',
            () async {
          final dir = nextDir();
          final context = await recordingContext(dir);
          final pageA = await recordedPage(context);
          final pageB = await recordedPage(context);

          final videoA = pageA.video()!;
          final videoB = pageB.video()!;
          var resolvedA = false;
          final pathA = videoA.path().then((value) {
            resolvedA = true;
            return value;
          });

          // Os dois arquivos existem e estao sendo escritos antes de fechar.
          final files = await videoFilesIn(dir, count: 2);
          expect(files, hasLength(2));
          await sizeAbove(files[0], 0);
          await sizeAbove(files[1], 0);
          expect(resolvedA, isFalse);

          // Ninguem fechou pagina nenhuma: fechar o contexto e que finaliza.
          await context.close();

          final a = await pathA.timeout(const Duration(seconds: 60));
          final b = await videoB.path().timeout(const Duration(seconds: 60));
          // Um video por pagina, nomeado pela pagina: dois nomes distintos.
          expect(a, isNot(b));
          expect(File(a).lengthSync(), greaterThan(0));
          expect(File(b).lengthSync(), greaterThan(0));
          expect(dir.listSync().whereType<File>().map((f) => f.path).toSet(),
              {a, b});
        });

        test('saveAs funciona depois do contexto fechado e copia os bytes',
            () async {
          final dir = nextDir();
          final context = await recordingContext(dir);
          final page = await recordedPage(context);
          final video = page.video()!;
          await sizeAbove(await videoFileIn(dir), 0);

          await context.close();
          expect(context.isClosed(), isTrue);

          // Depois do contexto fechado, que e como o upstream documenta o uso
          // normal: fecha, depois salva.
          final target = '${dir.path}/saved/copy.webm';
          await video.saveAs(target).timeout(const Duration(seconds: 60));
          final original = File(await video.path()).readAsBytesSync();
          final copy = File(target).readAsBytesSync();
          expect(copy, isNotEmpty);
          expect(copy, original);
        });

        test('saveAs chamado antes de fechar espera e grava o arquivo inteiro',
            () async {
          final dir = nextDir();
          final context = await recordingContext(dir);
          final page = await recordedPage(context);
          final video = page.video()!;
          final file = await videoFileIn(dir);
          await sizeAbove(file, 0);

          final target = '${dir.path}/early/copy.webm';
          var saved = false;
          final save = video.saveAs(target).then((_) => saved = true);

          await sizeAbove(file, file.lengthSync());
          expect(saved, isFalse,
              reason: 'saveAs copiou o arquivo ainda em gravacao');

          await context.close();
          await save.timeout(const Duration(seconds: 60));
          expect(File(target).readAsBytesSync(),
              File(await video.path()).readAsBytesSync());
        });

        test('delete() apaga o arquivo e saveAs depois dele falha', () async {
          final dir = nextDir();
          final context = await recordingContext(dir);
          final page = await recordedPage(context);
          final video = page.video()!;
          await sizeAbove(await videoFileIn(dir), 0);
          await context.close();

          final path = await video.path();
          expect(File(path).existsSync(), isTrue);
          await video.delete().timeout(const Duration(seconds: 60));
          expect(File(path).existsSync(), isFalse);
          expect(dir.listSync().whereType<File>(), isEmpty);

          await expectLater(
              video.saveAs('${dir.path}/nope.webm'), throwsA(isA<Error>()));
        });

        test(
            'gravar video e tracar a tira de filme ao mesmo tempo usa um '
            'screencast so', () async {
          final dir = nextDir();
          final context = await recordingContext(dir);
          try {
            // Os motores rodam um screencast por pagina, e o Stream que eles
            // entregam e de assinatura unica. Se cada consumidor assinasse o
            // do motor, o segundo a chegar levaria "Stream has already been
            // listened to" e o trace (ou o video) sairia vazio sem dizer por
            // que.
            await context.tracing.start(screenshots: true);
            final page = await context.newPage();
            await page.goto(server.url('/title'));
            final video = page.video()!;

            final file = await videoFileIn(dir);
            await sizeAbove(file, 0);

            final tracePath = '${dir.path}/trace.zip';
            await context.tracing.stop(path: tracePath);
            expect(File(tracePath).existsSync(), isTrue);

            await context.close();

            // Os dois consumidores receberam quadros: o video tem bytes...
            final videoPath = await video.path();
            expect(File(videoPath).lengthSync(), greaterThan(0));
            // ...e a tira de filme tem quadros no trace.
            final trace = _readTraceFrames(tracePath);
            expect(trace, isNotEmpty,
                reason: 'a tira de filme ficou vazia com recordVideo ligado: '
                    'os dois consumidores brigaram pelo screencast');
          } finally {
            if (!context.isClosed()) await context.close();
          }
        });

        test('o arquivo produzido e um WebM, nao bytes soltos', () async {
          final dir = nextDir();
          final context = await recordingContext(dir);
          final page = await recordedPage(context);
          final video = page.video()!;
          await sizeAbove(await videoFileIn(dir), 0);
          await context.close();

          // Existir e ter bytes nao prova nada: esta sessao ja viu um `.webm`
          // com bytes dentro que nao era video. O cabecalho EBML e o que
          // separa um arquivo que abre de um que so ocupa espaco.
          final bytes = File(await video.path()).readAsBytesSync();
          expect(bytes.take(4).toList(), [0x1A, 0x45, 0xDF, 0xA3],
              reason: 'o arquivo nao comeca com a assinatura EBML do Matroska');
        });

        test('uma pagina que o proprio site fecha ainda produz o video',
            () async {
          final dir = nextDir();
          final context = await recordingContext(dir);
          try {
            final page = await context.newPage();
            await page.goto(server.url('/title'));
            final popupFuture = page.waitForPopup();
            // O `window` devolvido por `window.open` nao e serializavel; o
            // bloco descarta o valor.
            await page.evaluate(
                "() => { window.open('${server.url('/text')}', '_blank'); }");
            final popup = await popupFuture;
            await popup.waitForLoadState();

            // A pagina que o site abriu tambem e filmada.
            final video = popup.video();
            expect(video, isNotNull);
            final files = await videoFilesIn(dir, count: 2);
            expect(files, hasLength(2));
            for (final file in files) {
              await sizeAbove(file, 0);
            }

            // O site fecha a propria janela; ninguem chamou `close()`.
            final closed = popup.onClose.first;
            // A chamada morre junto com a pagina que a executa: o que importa
            // e o fechamento, nao a resposta.
            await popup
                .evaluate('() => window.close()')
                .catchError((Object _) => null);
            await closed.timeout(const Duration(seconds: 30));

            final path =
                await video!.path().timeout(const Duration(seconds: 60));
            expect(File(path).lengthSync(), greaterThan(0));
          } finally {
            await context.close();
          }
        });
      });
    }

    // Um crash de renderer so e provocavel de forma confiavel no Chromium:
    // `chrome://crash` existe para isto. Firefox e WebKit nao tem equivalente,
    // e derrubar o processo por fora mataria o navegador inteiro em vez de uma
    // aba.
    group('[chromium]', () {
      test('uma pagina que crasha nao pendura o Future do video', () async {
        final browser = await playwright.chromium.launch(headless: true);
        final dir = nextDir();
        try {
          final context = await browser.newContext(
            viewport: (width: 640, height: 480),
            recordVideo: RecordVideoOptions(dir: dir.path),
          );
          final page = await context.newPage();
          await page.goto(server.url('/title'));
          final video = page.video()!;

          final crashed = page.onCrash.first;
          // A navegacao em si nunca responde; o crash e o resultado.
          unawaited(page.goto('chrome://crash').catchError((Object _) {}));
          await crashed.timeout(const Duration(seconds: 30));

          // O contrato: resolve com um caminho ou falha com um erro claro.
          // O que nao pode e ficar pendurado — foi por isso que a finalizacao
          // ganhou prazo.
          String? path;
          Object? error;
          try {
            path = await video.path().timeout(const Duration(seconds: 60));
          } catch (e) {
            error = e;
          }
          expect(error, isNot(isA<TimeoutException>()),
              reason: 'video.path() ficou pendurado depois do crash');
          if (path != null) expect(File(path).existsSync(), isTrue);

          await context.close();
        } finally {
          await browser.close();
        }
      });
    });

    test('launchPersistentContext tambem grava video', () async {
      final dir = nextDir();
      final profile = Directory.systemTemp.createTempSync('pw_video_profile_');
      final context = await playwright.chromium.launchPersistentContext(
        profile.path,
        headless: true,
        viewport: (width: 640, height: 480),
        recordVideo: RecordVideoOptions(dir: dir.path),
      );
      try {
        final page = await recordedPage(context);
        final video = page.video();
        expect(video, isNotNull);
        await sizeAbove(await videoFileIn(dir), 0);
        await context.close();
        final path = await video!.path().timeout(const Duration(seconds: 60));
        expect(File(path).lengthSync(), greaterThan(0));
      } finally {
        if (!context.isClosed()) await context.close();
        try {
          profile.deleteSync(recursive: true);
        } catch (_) {
          // Windows segura o perfil por um instante depois que o processo
          // morre.
        }
      }
    });
  }, timeout: const Timeout(Duration(minutes: 6)));
}

/// The `screencast-frame` events of a trace archive.
///
/// Read here rather than through the tracing tests' reader because this file
/// only needs the one event type, and the point is whether any arrived at all.
List<Map<String, dynamic>> _readTraceFrames(String path) {
  final archive = ZipDecoder().decodeBytes(File(path).readAsBytesSync());
  final trace = archive.files.firstWhere((f) => f.name == 'trace.trace');
  return [
    for (final line in const LineSplitter()
        .convert(utf8.decode(trace.content as List<int>)))
      if (line.trim().isNotEmpty) jsonDecode(line) as Map<String, dynamic>,
  ].where((event) => event['type'] == 'screencast-frame').toList();
}
