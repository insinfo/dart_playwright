import 'dart:async';
import 'dart:convert';

import 'package:playwright/playwright.dart';
import 'package:test/test.dart';

import 'test_server.dart';

/// Parity coverage for the P0 event model: the page/context/browser events and
/// the waiters built on them, exercised on Chromium, Firefox and WebKit.
///
/// Every popup test triggers the popup with a *trusted* click, never with
/// `evaluate(() => window.open())`: an engine's popup blocker rejects a
/// `window.open` that no user gesture asked for, and the test would be
/// measuring the blocker instead of the event.
void main() {
  group('Eventos de Page, BrowserContext e Browser', () {
    late Playwright playwright;
    late TestServer server;

    setUpAll(() async {
      server = await TestServer.start();
      playwright = await Playwright.create();
    });

    tearDownAll(() async {
      await server.stop();
    });

    final browsers = ['chromium', 'firefox', 'webkit'];

    for (final browserName in browsers) {
      group('[$browserName]', () {
        late Browser browser;
        var browserLaunched = false;
        late BrowserContext context;
        late Page page;

        Future<Browser> launch() {
          switch (browserName) {
            case 'chromium':
              return playwright.chromium.launch(headless: true);
            case 'firefox':
              return playwright.firefox.launch(headless: true);
            default:
              return playwright.webkit.launch(headless: true);
          }
        }

        setUpAll(() async {
          browser = await launch();
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

        // ------------------------------------------------------- console

        test('Deve emitir console com tipo e texto', () async {
          await page.goto(server.url('/console'));
          // Filter on the text: the browser itself logs to the console too
          // (a 404 for the favicon, for one), and the first message is not
          // necessarily ours.
          final message = page.waitForConsoleMessage(
              predicate: (m) => m.text().contains('hello'),
              timeout: const Duration(seconds: 15));
          await page.evaluate('() => window.emitLog()');
          final console = await message;
          expect(console.type(), equals('log'));
          expect(console.text(), contains('hello'));
          expect(console.text(), contains('42'));
        });

        test('Deve normalizar console.warn para warning', () async {
          await page.goto(server.url('/console'));
          final message = page.waitForConsoleMessage(
              predicate: (m) => m.text().contains('watch out'),
              timeout: const Duration(seconds: 15));
          await page.evaluate('() => window.emitWarning()');
          expect((await message).type(), equals('warning'));
        });

        test('Deve emitir console no BrowserContext tambem', () async {
          await page.goto(server.url('/console'));
          final message = context.waitForConsoleMessage(
              predicate: (m) => m.text().contains('it broke'),
              timeout: const Duration(seconds: 15));
          await page.evaluate('() => window.emitError()');
          expect((await message).type(), equals('error'));
        });

        // ----------------------------------------------------- pageError

        test('Deve emitir pageError com nome e mensagem', () async {
          await page.goto(server.url('/pageerror'));
          final error = page.onPageError.first;
          await page.evaluate('() => window.boom()');
          final pageError = await error.timeout(const Duration(seconds: 15));
          expect(pageError.name, equals('TypeError'));
          expect(pageError.message, equals('kaboom'));
        });

        test('Deve emitir pageError no BrowserContext tambem', () async {
          await page.goto(server.url('/pageerror'));
          final error = context.onPageError.first;
          await page.evaluate('() => window.boom()');
          expect((await error.timeout(const Duration(seconds: 15))).message,
              equals('kaboom'));
        });

        // --------------------------------------------------------- popup

        test('Deve esperar popup aberto por window.open', () async {
          await page.goto(server.url('/popup'));
          final popupFuture =
              page.waitForPopup(timeout: const Duration(seconds: 20));
          await page.locator('#open').click();
          final popup = await popupFuture;
          // The popup may still be navigating; the locator polls until the
          // element shows up, which is true regardless of whether the load
          // event landed before or after the attach.
          expect(await popup.locator('#popup').textContent(),
              equals('I am a popup'));
        });

        test('Deve esperar popup aberto por link target=_blank', () async {
          await page.goto(server.url('/popup'));
          final popupFuture =
              page.waitForPopup(timeout: const Duration(seconds: 20));
          await page.locator('#link').click();
          final popup = await popupFuture;
          expect(await popup.locator('#popup').textContent(),
              equals('I am a popup'));
        });

        test('Popup deve apontar para a pagina que o abriu', () async {
          await page.goto(server.url('/popup'));
          final popupFuture =
              page.waitForPopup(timeout: const Duration(seconds: 20));
          await page.locator('#open').click();
          final popup = await popupFuture;
          await popup.locator('#popup').textContent();
          expect(popup.opener(), same(page));
          expect(page.opener(), isNull);
        });

        test('context.waitForPage deve ver o popup e context.pages cresce',
            () async {
          await page.goto(server.url('/popup'));
          final pageFuture =
              context.waitForPage(timeout: const Duration(seconds: 20));
          await page.locator('#open').click();
          final opened = await pageFuture;
          await opened.locator('#popup').textContent();
          expect(context.pages(), contains(opened));
          expect(context.pages().length, equals(2));
        });

        test('context.waitForPage deve ver a pagina criada por newPage',
            () async {
          final pageFuture =
              context.waitForPage(timeout: const Duration(seconds: 20));
          final created = await context.newPage();
          expect(await pageFuture, same(created));
          await created.close();
        });

        // -------------------------------------------------------- dialog

        test('Deve receber dialog como stream na pagina', () async {
          await page.goto(server.url('/dialog'));
          final subscription = page.onDialog.listen((dialog) {
            expect(dialog.type, equals('prompt'));
            dialog.accept('via stream');
          });
          addTearDown(subscription.cancel);
          await page.evaluate('() => window.runPrompt()');
          expect(await page.locator('#result').textContent(),
              equals('got:via stream'));
        });

        test('Deve receber dialog no BrowserContext', () async {
          await page.goto(server.url('/dialog'));
          final subscription =
              context.onDialog.listen((dialog) => dialog.accept('via context'));
          addTearDown(subscription.cancel);
          await page.evaluate('() => window.runPrompt()');
          expect(await page.locator('#result').textContent(),
              equals('got:via context'));
        });

        test('Dialog sem ouvinte deve ser dispensado automaticamente',
            () async {
          await page.goto(server.url('/dialog'));
          // Nobody is listening: the dialog must be dismissed, not block the
          // page forever. A prompt dismissed yields null.
          await page
              .evaluate('() => window.runPrompt()')
              .timeout(const Duration(seconds: 15));
          expect(
              await page.locator('#result').textContent(), equals('got:null'));
        });

        // ---------------------------------------------------- rede/close

        test('BrowserContext deve reemitir request e response', () async {
          final request = context.onRequest.first;
          final response = context.onResponse.first;
          await page.goto(server.url('/hello'));
          expect((await request.timeout(const Duration(seconds: 15))).url(),
              contains('/hello'));
          expect((await response.timeout(const Duration(seconds: 15))).status(),
              equals(200));
        });

        test('page.onClose deve disparar ao fechar a pagina', () async {
          final other = await context.newPage();
          final closed = other.onClose.first;
          await other.close();
          await closed.timeout(const Duration(seconds: 15));
          expect(other.isClosed(), isTrue);
        });

        test('context.onClose deve disparar ao fechar o contexto', () async {
          final other = await browser.newContext();
          final closed = other.onClose.first;
          await other.close();
          await closed.timeout(const Duration(seconds: 15));
          expect(other.isClosed(), isTrue);
        });

        // ------------------------------------------------ cancelamento

        test('waitForPopup deve estourar timeout com TimeoutException',
            () async {
          await page.goto(server.url('/popup'));
          expect(
            () => page.waitForPopup(timeout: const Duration(milliseconds: 300)),
            throwsA(isA<TimeoutException>()),
          );
        });

        test('waitForPopup deve ser cancelado quando a pagina fecha', () async {
          final other = await context.newPage();
          await other.goto(server.url('/popup'));
          final popupFuture =
              other.waitForPopup(timeout: const Duration(seconds: 20));
          // Attach the expectation *before* closing. How fast the rejection
          // arrives is engine and platform specific -- WebKit on Linux and
          // macOS rejects while close() is still being awaited -- and a
          // rejection that lands while nothing is listening is reported as an
          // unhandled async error, failing the test even though the wait was
          // cancelled exactly as it should be.
          final cancelled =
              expectLater(popupFuture, throwsA(isA<PlaywrightException>()));
          await other.close();
          await cancelled;
        });

        test('context.waitForPage deve ser cancelado quando o contexto fecha',
            () async {
          final other = await browser.newContext();
          await other.newPage();
          final pageFuture =
              other.waitForPage(timeout: const Duration(seconds: 20));
          final cancelled =
              expectLater(pageFuture, throwsA(isA<PlaywrightException>()));
          await other.close();
          await cancelled;
        });

        // ------------------------------------- viewport e headers extras

        test('setViewportSize deve redimensionar a pagina', () async {
          await page.goto(server.url('/hello'));
          await page.setViewportSize(500, 400);
          expect(await page.evaluate('() => window.innerWidth'), equals(500));
          expect(await page.evaluate('() => window.innerHeight'), equals(400));
        });

        test('setExtraHTTPHeaders deve chegar no servidor', () async {
          await page.setExtraHTTPHeaders({'X-Dart-Playwright': 'sim'});
          await page.goto(server.url('/echo-headers'));
          final body = await page.evaluate('() => document.body.innerText');
          final headers = jsonDecode(body.toString()) as Map<String, dynamic>;
          expect(headers['x-dart-playwright'], equals('sim'));
        });
      });
    }

    // -------------------------------------------------------------- crash

    // Only Chromium offers a supported way to kill a renderer on demand
    // (`chrome://crash`). Firefox's `about:crashcontent` needs a debug build
    // and WebKit has no equivalent, so `onCrash` is proven on Chromium alone;
    // the wiring for the other two is in place but untested end to end.
    test('[chromium] page.onCrash deve disparar quando o renderer morre',
        () async {
      final browser = await playwright.chromium.launch(headless: true);
      // Close through a tear-down, not at the end of the body: if the wait
      // below ever times out, the browser has to go away anyway.
      addTearDown(browser.close);
      final context = await browser.newContext();
      final page = await context.newPage();
      final crashed = page.onCrash.first;
      // The navigation never completes: the renderer dies serving it.
      unawaited(page.goto('chrome://crash').catchError((Object _) {}));
      // Generous on purpose. This test launches its own browser while the
      // three engine groups are still busy, and a loaded machine has made
      // the whole thing miss a 20s budget before.
      await crashed.timeout(const Duration(seconds: 60));
    }, timeout: const Timeout(Duration(minutes: 3)));

    // ------------------------------------------------------- disconnected

    for (final browserName in browsers) {
      test('[$browserName] browser.onDisconnected deve disparar no close',
          () async {
        final browser = switch (browserName) {
          'chromium' => await playwright.chromium.launch(headless: true),
          'firefox' => await playwright.firefox.launch(headless: true),
          _ => await playwright.webkit.launch(headless: true),
        };
        final disconnected = browser.onDisconnected.first;
        expect(browser.isConnected(), isTrue);
        await browser.close();
        await disconnected.timeout(const Duration(seconds: 20));
        expect(browser.isConnected(), isFalse);
      });
    }
  });
}
