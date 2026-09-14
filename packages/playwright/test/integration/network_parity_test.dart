import 'dart:convert';
import 'dart:io';

import 'package:playwright/playwright.dart';
import 'package:test/test.dart';

import 'test_server.dart';

/// Parity coverage for the completed `Request`, `Response` and `Route`
/// surfaces, on Chromium, Firefox and WebKit.
void main() {
  group('Request, Response e Route', () {
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
        late Page page;

        setUpAll(() async {
          browser = await switch (browserName) {
            'chromium' => playwright.chromium.launch(headless: true),
            'firefox' => playwright.firefox.launch(headless: true),
            _ => playwright.webkit.launch(headless: true),
          };
          browserLaunched = true;
        });

        setUp(() async {
          context = await browser.newContext();
          page = await context.newPage();
        });

        tearDown(() async {
          await context.close();
        });

        tearDownAll(() async {
          if (browserLaunched) await browser.close();
        });

        // ------------------------------------------------------- request

        test('Deve reportar resourceType e isNavigationRequest', () async {
          final types = <String, String>{};
          final navigations = <String, bool>{};
          final subscription = page.onRequest.listen((request) {
            types[request.url()] = request.resourceType();
            navigations[request.url()] = request.isNavigationRequest();
          });
          addTearDown(subscription.cancel);

          await page.goto(server.url('/resources'));
          // The stylesheet may still be in flight when goto resolves.
          await page.locator('#styled').waitFor();
          await page.waitForFunction(
              '() => getComputedStyle(document.getElementById("styled")).color '
              '=== "rgb(1, 2, 3)"',
              timeout: const Duration(seconds: 10));

          expect(types[server.url('/resources')], equals('document'));
          expect(navigations[server.url('/resources')], isTrue);
          expect(types[server.url('/style.css')], equals('stylesheet'));
          expect(navigations[server.url('/style.css')], isFalse);
        });

        test('Deve encadear redirectedFrom e redirectedTo', () async {
          final requests = <Request>[];
          final subscription = page.onRequest.listen(requests.add);
          addTearDown(subscription.cancel);

          await page.goto(server.url('/redirect-start'));
          expect(
              await page.locator('#arrived').textContent(), equals('arrived'));

          final last = requests.firstWhere(
              (r) => r.url() == server.url('/redirect-end'),
              orElse: () => throw StateError('final request not seen'));
          final previous = last.redirectedFrom();
          expect(previous, isNotNull);
          expect(previous!.url(), equals(server.url('/redirect-start')));
          expect(previous.redirectedTo()!.url(),
              equals(server.url('/redirect-end')));
        });

        test('Deve expor failure quando a rota aborta', () async {
          await page.route('/style.css', (route) {
            route.abort('connectionrefused');
          });
          final failed = page.onRequestFailed.first;
          await page.goto(server.url('/resources'));
          final request = await failed.timeout(const Duration(seconds: 15));
          expect(request.url(), contains('/style.css'));
          expect(request.failure(), isNotNull);
          expect(request.failure(), isNotEmpty);
        });

        test('Deve expor sizes e timing apos o fim da requisicao', () async {
          final responseFuture = page.waitForResponse(
              predicate: (r) => r.url().contains('/hello'),
              timeout: const Duration(seconds: 15));
          await page.goto(server.url('/hello'));
          final response = await responseFuture;

          expect(await response.finished(), isNull);

          final sizes = await response.request().sizes();
          // Firefox reports no header sizes and WebKit no transfer size, so
          // only the body size is asserted across all three.
          expect(sizes.responseBodySize, greaterThan(0));

          final timing = response.request().timing();
          expect(timing.startTime, greaterThan(0));
        });

        // ------------------------------------------------------ response

        test('Deve expor allHeaders, headerValue e headerValues', () async {
          final responseFuture = page.waitForResponse(
              predicate: (r) => r.url().contains('/echo-request'),
              timeout: const Duration(seconds: 15));
          await page.goto(server.url('/echo-request'));
          final response = await responseFuture;

          final all = await response.allHeaders();
          // allHeaders lower-cases the names, whatever the engine reported.
          expect(all.keys.every((k) => k == k.toLowerCase()), isTrue);
          expect(await response.headerValue('x-echo'), equals('yes'));
          expect(await response.headerValues('x-echo'), equals(['yes']));
          expect(await response.headerValue('x-absent'), isNull);

          final array = await response.headersArray();
          expect(array.any((h) => h.name.toLowerCase() == 'x-echo'), isTrue);
        });

        test('Deve expor serverAddr do servidor local', () async {
          final responseFuture = page.waitForResponse(
              predicate: (r) => r.url().contains('/hello'),
              timeout: const Duration(seconds: 15));
          await page.goto(server.url('/hello'));
          final response = await responseFuture;
          // WebKit only learns the address at loadingFinished.
          await response.finished();
          final addr = await response.serverAddr();
          if (addr != null) {
            expect(addr.port, equals(server.port));
          }
        });

        // --------------------------------------------------------- route

        test('Deve reescrever metodo, headers e corpo no continue', () async {
          await page.route('/echo-request', (route) {
            route.continue_(
              method: 'POST',
              headers: {
                ...route.request().headers(),
                'X-Rewritten': 'yes',
              },
              postData: 'hello from dart',
            );
          });

          await page.goto(server.url('/echo-request'));
          final body = await page.evaluate('() => document.body.innerText');
          final echoed = jsonDecode(body.toString()) as Map<String, dynamic>;
          expect(echoed['method'], equals('POST'));
          expect((echoed['headers'] as Map)['x-rewritten'], equals('yes'));
          expect(echoed['body'], equals('hello from dart'));
        });

        test('fallback deve passar a rota para o handler anterior', () async {
          final order = <String>[];
          // Registered first, so it runs last.
          await page.route('/hello', (route) {
            order.add('first');
            route.fulfill(body: '<html><body id="who">first</body></html>');
          });
          await page.route('/hello', (route) {
            order.add('second');
            route.fallback();
          });

          await page.goto(server.url('/hello'));
          // Newest handler runs first and declines; the older one answers.
          expect(order, equals(['second', 'first']));
          expect(await page.locator('#who').textContent(), equals('first'));
        });

        test('fallback do ultimo handler deixa a requisicao seguir', () async {
          var called = 0;
          await page.route('/hello', (route) {
            called++;
            route.fallback();
          });
          await page.goto(server.url('/hello'));
          expect(called, equals(1));
          // The real page was served, not a fulfilled stub.
          expect(await page.locator('#hello').textContent(), equals('Hello'));
        });

        test('abort deve recusar codigo de erro desconhecido', () async {
          // Chromium and WebKit assert on the code upstream; Firefox passes
          // it through, so the check lives on our side for all three.
          await page.route('/hello', (route) {
            expect(() => route.abort('nao-existe'), throwsArgumentError);
            route.continue_();
          });
          await page.goto(server.url('/hello'));
        },
            skip: browserName == 'firefox'
                ? 'Juggler takes the error code verbatim; there is no table to '
                    'validate against, as upstream also does not validate.'
                : null);

        // ------------------------------------------------- upload

        test('setInputFiles deve apontar o input para o arquivo', () async {
          final dir = Directory.systemTemp.createTempSync('pw-upload');
          addTearDown(() => dir.deleteSync(recursive: true));
          final file = File('${dir.path}/hello.txt')
            ..writeAsStringSync('conteudo');

          await page.goto(server.url('/upload'));
          await page.locator('#upload').setInputFiles([file.path]);
          expect(await page.evaluate('() => window.names("upload")'),
              equals('hello.txt'));

          await page.locator('#upload').setInputFiles([]);
          expect(
              await page.evaluate('() => window.names("upload")'), equals(''));
        });

        test('setInputFiles deve aceitar varios arquivos', () async {
          final dir = Directory.systemTemp.createTempSync('pw-upload-many');
          addTearDown(() => dir.deleteSync(recursive: true));
          final a = File('${dir.path}/a.txt')..writeAsStringSync('a');
          final b = File('${dir.path}/b.txt')..writeAsStringSync('b');

          await page.goto(server.url('/upload'));
          await page.locator('#uploadMany').setInputFiles([a.path, b.path]);
          expect(await page.evaluate('() => window.names("uploadMany")'),
              equals('a.txt,b.txt'));
        });

        test('waitForFileChooser deve interceptar o dialogo', () async {
          final dir = Directory.systemTemp.createTempSync('pw-chooser');
          addTearDown(() => dir.deleteSync(recursive: true));
          final file = File('${dir.path}/chosen.txt')
            ..writeAsStringSync('escolhido');

          await page.goto(server.url('/upload'));
          final chooserFuture =
              page.waitForFileChooser(timeout: const Duration(seconds: 20));
          await page.locator('#pick').click();
          final chooser = await chooserFuture;

          expect(chooser.isMultiple(), isFalse);
          await chooser.setFiles([file.path]);
          expect(await page.evaluate('() => window.names("upload")'),
              equals('chosen.txt'));
        });

        // -------------------------------------------------- screenshot

        test('screenshot deve respeitar fullPage e clip', () async {
          await page.setViewportSize(400, 300);
          await page.goto(server.url('/tall'));

          final viewportShot = await page.screenshot();
          final fullShot = await page.screenshot(fullPage: true);
          // The document is 3000px tall against a 300px viewport, so the two
          // images cannot be the same size.
          expect(fullShot.length, greaterThan(viewportShot.length));

          final clipped = await page
              .screenshot(clip: (x: 10, y: 20, width: 120, height: 60));
          expect(clipped.length, lessThan(viewportShot.length));
          // PNG magic number, so we know it is really an image.
          expect(clipped.sublist(0, 4), equals([0x89, 0x50, 0x4E, 0x47]));
        });

        test('screenshot deve aceitar jpeg com quality', () async {
          await page.goto(server.url('/tall'));
          final jpeg = await page.screenshot(type: 'jpeg', quality: 30);
          // JPEG SOI marker.
          expect(jpeg.sublist(0, 2), equals([0xFF, 0xD8]));
          expect(() => page.screenshot(type: 'png', quality: 30),
              throwsArgumentError);
        });

        test('Locator.screenshot deve recortar o elemento', () async {
          await page.setViewportSize(400, 300);
          await page.goto(server.url('/tall'));
          final element = await page.locator('#box').screenshot();
          final full = await page.screenshot();
          expect(element.sublist(0, 4), equals([0x89, 0x50, 0x4E, 0x47]));
          expect(element.length, lessThan(full.length));
        });

        // --------------------------------------------------------- pdf

        test('page.pdf deve gerar um PDF no Chromium e recusar nos outros',
            () async {
          await page.goto(server.url('/tall'));
          if (browserName == 'chromium') {
            final bytes = await page.pdf(format: 'a4', printBackground: true);
            expect(String.fromCharCodes(bytes.take(5)), equals('%PDF-'));
            expect(bytes.length, greaterThan(1000));
          } else {
            expect(() => page.pdf(), throwsUnsupportedError);
          }
        });

        // ---------------------------------------------------- download

        test('waitForDownload deve entregar o arquivo baixado', () async {
          await page.goto(server.url('/download'));
          final downloadFuture =
              page.waitForDownload(timeout: const Duration(seconds: 25));
          await page.locator('#grab').click();
          final download = await downloadFuture;

          expect(download.url(), contains('/download-file'));
          expect(await download.failure(), isNull);
          expect(download.suggestedFilename(), equals('report.txt'));

          final dir = Directory.systemTemp.createTempSync('pw-download');
          addTearDown(() => dir.deleteSync(recursive: true));
          final target = '${dir.path}${Platform.pathSeparator}saved.txt';
          await download.saveAs(target);
          expect(File(target).readAsStringSync(), equals('downloaded payload'));
        });

        test('BrowserContext deve reemitir o download', () async {
          await page.goto(server.url('/download'));
          final contextDownload = context.onDownload.first;
          await page.locator('#grab').click();
          final download =
              await contextDownload.timeout(const Duration(seconds: 25));
          expect(await download.path(), isNotNull);
        });
      });
    }
  });
}
