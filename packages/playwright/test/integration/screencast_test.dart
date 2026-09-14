import 'dart:async';

import 'package:image/image.dart' as img;
import 'package:playwright/playwright.dart';
import 'package:playwright_core/src/server/video/page_screencast.dart';
import 'package:playwright_core/src/server/video/screencast_factory.dart';
import 'package:playwright_core/src/server/video/video_frame.dart';
import 'package:test/test.dart';

import 'test_server.dart';

/// O screencast por pagina nos tres motores: o que sai de
/// `Page.startScreencast` (Chromium e Firefox) e de `Screencast.startScreencast`
/// (WebKit) ate virar um [VideoFrame].
///
/// O viewport e 800x600 e a gravacao pede 640x480 de proposito: os tres
/// protocolos mandam o tamanho do *viewport* junto do quadro, entao um teste
/// que gravasse no tamanho do viewport passaria mesmo se a implementacao
/// confiasse no numero errado.
void main() {
  group('Screencast', () {
    late Playwright playwright;
    late TestServer server;

    setUpAll(() async {
      server = await TestServer.start();
      playwright = await Playwright.create();
    });

    tearDownAll(() async {
      await server.stop();
    });

    for (final browserName in ['chromium', 'firefox', 'webkit']) {
      group('[$browserName]', () {
        late Browser browser;
        var browserLaunched = false;
        late BrowserContext context;

        setUpAll(() async {
          browser = await switch (browserName) {
            'chromium' => playwright.chromium.launch(headless: true),
            'firefox' => playwright.firefox.launch(headless: true),
            _ => playwright.webkit.launch(headless: true),
          };
          browserLaunched = true;
        });

        setUp(() async {
          context =
              await browser.newContext(viewport: (width: 800, height: 600));
        });

        tearDown(() async {
          await context.close();
        });

        tearDownAll(() async {
          if (browserLaunched) await browser.close();
        });

        /// Uma pagina que repinta sozinha, ja gravando.
        Future<(Page, PageScreencast)> recording(
            {int width = 640, int height = 480}) async {
          final page = await context.newPage();
          await page.goto(server.url('/animated'));
          final screencast = createPageScreencast(corePageOf(page));
          await screencast.start(width: width, height: height);
          return (page, screencast);
        }

        test('Deve entregar quadros JPEG no tamanho pedido', () async {
          final (_, screencast) = await recording();
          final frames = await screencast.frames
              .take(5)
              .toList()
              .timeout(const Duration(seconds: 30));
          await screencast.stop();

          expect(frames, hasLength(5));
          for (final frame in frames) {
            // JPEG e nao PNG: o ffmpeg publicado pela Playwright so tem os
            // decoders mjpeg e libvpx, entao um quadro PNG nao entra no
            // encoder do video.
            expect(frame.format, VideoFrameFormat.jpeg);
            expect(frame.data, isNotEmpty);
            // Decodificado de verdade, nao pelo mesmo leitor de cabecalho que
            // a implementacao usa para preencher width/height.
            final decoded = img.decodeJpg(frame.data);
            expect(decoded, isNotNull,
                reason: 'o quadro nao decodifica como JPEG');
            expect(decoded!.width, 640);
            expect(decoded.height, 480);
            expect(frame.width, decoded.width);
            expect(frame.height, decoded.height);
          }
        });

        test('Deve continuar mandando quadros depois de dezenas deles',
            () async {
          // O teste do ack. Sem `screencastFrameAck` os tres motores param
          // sozinhos depois de um punhado de quadros (medido: 3 no Chromium,
          // 2 no WebKit, 1 no Firefox em 3s), entao qualquer numero bem acima
          // disso so e alcancavel reconhecendo cada quadro.
          final (_, screencast) = await recording();
          final stopwatch = Stopwatch()..start();
          final frames = await screencast.frames
              .take(60)
              .toList()
              .timeout(const Duration(seconds: 60));
          stopwatch.stop();
          await screencast.stop();

          expect(frames, hasLength(60));
          printOnFailure(
              '$browserName: 60 quadros em ${stopwatch.elapsedMilliseconds}ms');
        });

        test('Deve retomar o fluxo quando alguem assina depois do start',
            () async {
          // O ack e a contrapressao: enquanto ninguem consome, o ack fica
          // preso e o motor para. Assinar depois tem de soltar os acks
          // presos, senao a gravacao nunca mais anda.
          final (_, screencast) = await recording();
          await Future<void>.delayed(const Duration(seconds: 2));
          final frames = await screencast.frames
              .take(20)
              .toList()
              .timeout(const Duration(seconds: 30));
          await screencast.stop();
          expect(frames, hasLength(20));
        });

        test('Deve carimbar os quadros desde o inicio da gravacao', () async {
          final (_, screencast) = await recording();
          final frames = await screencast.frames
              .take(10)
              .toList()
              .timeout(const Duration(seconds: 30));
          await screencast.stop();

          expect(frames.first.timestamp, greaterThanOrEqualTo(Duration.zero));
          // O primeiro quadro sai logo depois do start, nao minutos depois:
          // um carimbo ancorado na epoch em vez do inicio da gravacao
          // apareceria aqui como decadas.
          expect(frames.first.timestamp, lessThan(const Duration(seconds: 30)));
          for (var i = 1; i < frames.length; i++) {
            expect(frames[i].timestamp,
                greaterThanOrEqualTo(frames[i - 1].timestamp),
                reason: 'carimbo do quadro $i andou para tras');
          }
          expect(frames.last.timestamp, greaterThan(frames.first.timestamp));
        });

        test('Deve seguir gravando depois de a pagina navegar', () async {
          final (page, screencast) = await recording();
          final afterNavigation = Completer<VideoFrame>();
          var navigated = false;
          final subscription = screencast.frames.listen((frame) {
            if (navigated && !afterNavigation.isCompleted) {
              afterNavigation.complete(frame);
            }
          });

          // Documento novo no mesmo target: o screencast e da pagina, nao do
          // documento, e tem de atravessar a navegacao.
          await page.goto(server.url('/animated?segundo'));
          navigated = true;
          final frame =
              await afterNavigation.future.timeout(const Duration(seconds: 30));
          expect(frame.width, 640);
          expect(frame.height, 480);

          await subscription.cancel();
          await screencast.stop();
        });

        test('Deve fechar o stream quando a pagina fecha', () async {
          // Um Stream que nao fecha trava quem espera por ele: quem estiver
          // num `await for` fica ali para sempre depois que a pagina sumiu.
          final (page, screencast) = await recording();
          final closed = Completer<void>();
          final subscription =
              screencast.frames.listen((_) {}, onDone: () => closed.complete());
          await Future<void>.delayed(const Duration(milliseconds: 500));
          await page.close();

          await expectLater(
              closed.future.timeout(const Duration(seconds: 10)), completes);
          await subscription.cancel();
        });

        test('Deve fechar o stream quando o contexto fecha', () async {
          final (_, screencast) = await recording();
          final closed = Completer<void>();
          final subscription =
              screencast.frames.listen((_) {}, onDone: () => closed.complete());
          await Future<void>.delayed(const Duration(milliseconds: 500));
          await context.close();

          await expectLater(
              closed.future.timeout(const Duration(seconds: 10)), completes);
          await subscription.cancel();
          // O tearDown fecha o contexto de novo; fechar duas vezes e inocuo.
        });

        test('Deve relatar que entrega quadros, e nao um arquivo', () async {
          // O contrato previa `ScreencastKind.directFile` para o WebKit, por
          // conta do antigo `Screencast.startVideo`. Esse comando nao existe
          // mais (WebKit 26.5 responde `'Screencast.startVideo' was not
          // found`): os tres motores mandam quadro.
          final page = await context.newPage();
          final screencast = createPageScreencast(corePageOf(page));
          expect(screencast.kind, ScreencastKind.frames);
          expect(await screencast.stop(), '');
        });

        test('Deve fechar o stream quando a pagina ja estava fechada',
            () async {
          final page = await context.newPage();
          final screencast = createPageScreencast(corePageOf(page));
          await page.close();
          await screencast.start(width: 640, height: 480);
          await expectLater(
              screencast.frames.isEmpty.timeout(const Duration(seconds: 10)),
              completion(isTrue));
        });
      });
    }

    group('[chromium] crash', () {
      late Browser browser;
      var browserLaunched = false;

      setUpAll(() async {
        browser = await playwright.chromium.launch(headless: true);
        browserLaunched = true;
      });

      tearDownAll(() async {
        if (browserLaunched) await browser.close();
      });

      test('Deve fechar o stream quando a pagina crasha', () async {
        // So o Chromium tem um jeito de matar o renderer sob comando; o
        // caminho de codigo (`crash` -> stop) e o mesmo dos tres.
        final context =
            await browser.newContext(viewport: (width: 800, height: 600));
        final page = await context.newPage();
        await page.goto(server.url('/animated'));
        final screencast = createPageScreencast(corePageOf(page));
        await screencast.start(width: 640, height: 480);
        final closed = Completer<void>();
        final subscription =
            screencast.frames.listen((_) {}, onDone: () => closed.complete());
        await Future<void>.delayed(const Duration(milliseconds: 500));

        // `goto` nunca volta de uma pagina que mata o renderer.
        unawaited(page.goto('chrome://crash').catchError((Object _) {}));

        await expectLater(
            closed.future.timeout(const Duration(seconds: 20)), completes);
        await subscription.cancel();
        await context.close();
      });
    });
  });
}
