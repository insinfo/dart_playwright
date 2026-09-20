import 'package:playwright/playwright.dart';
import 'package:test/test.dart';

import 'test_server.dart';

/// Parity coverage for `WebSocket`, `WebSocketRoute` and `Worker` on
/// Chromium, Firefox and WebKit.
///
/// Where an engine reports less than the others the test says so out loud
/// instead of skipping: a divergence that nobody asserts on is a divergence
/// that comes back.
void main() {
  group('WebSocket, WebSocketRoute e Worker', () {
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

        // ----------------------------------------------------- WebSocket

        test('Deve emitir websocket com a url do handshake', () async {
          await page.goto(server.url('/websocket'));
          final socketFuture =
              page.waitForWebSocket(timeout: const Duration(seconds: 20));
          await page
              .evaluate('() => window.openWs(${_json(server.wsUrl('/ws'))})');
          final socket = await socketFuture;
          expect(socket.url(), equals(server.wsUrl('/ws')));
          expect(socket.isClosed(), isFalse);
        });

        test('Deve reportar framereceived do servidor', () async {
          await page.goto(server.url('/websocket'));
          final socketFuture =
              page.waitForWebSocket(timeout: const Duration(seconds: 20));
          await page
              .evaluate('() => window.openWs(${_json(server.wsUrl('/ws'))})');
          final socket = await socketFuture;
          final frame = await socket.waitForFrameReceived(
              predicate: (f) => f.text() == 'hello',
              timeout: const Duration(seconds: 20));
          expect(frame.isText, isTrue);
          expect(frame.text(), equals('hello'));
        });

        test('Deve reportar framesent da pagina', () async {
          await page.goto(server.url('/websocket'));
          final socketFuture =
              page.waitForWebSocket(timeout: const Duration(seconds: 20));
          await page
              .evaluate('() => window.openWs(${_json(server.wsUrl('/ws'))})');
          final socket = await socketFuture;
          final sent = socket.waitForFrameSent(
              predicate: (f) => f.text() == 'ping',
              timeout: const Duration(seconds: 20));
          await page.evaluate("() => window.sendWs('ping')");
          expect((await sent).text(), equals('ping'));

          final echoed = await socket.waitForFrameReceived(
              predicate: (f) => f.text().startsWith('echo:'),
              timeout: const Duration(seconds: 20));
          expect(echoed.text(), equals('echo:ping'));
        });

        test('Deve decodificar frame binario em bytes', () async {
          await page.goto(server.url('/websocket'));
          final socketFuture =
              page.waitForWebSocket(timeout: const Duration(seconds: 20));
          await page
              .evaluate('() => window.openWs(${_json(server.wsUrl('/ws'))})');
          final socket = await socketFuture;
          final received = socket.waitForFrameReceived(
              predicate: (f) => !f.isText,
              timeout: const Duration(seconds: 20));
          await page.evaluate('() => window.sendWsBinary()');
          final frame = await received;
          // The echo server adds one to every byte of [1, 2, 3].
          expect(frame.isText, isFalse);
          expect(frame.binary(), equals([2, 3, 4]));
        });

        test('Deve emitir close quando a pagina fecha o socket', () async {
          await page.goto(server.url('/websocket'));
          final socketFuture =
              page.waitForWebSocket(timeout: const Duration(seconds: 20));
          await page
              .evaluate('() => window.openWs(${_json(server.wsUrl('/ws'))})');
          final socket = await socketFuture;
          // Wait for the greeting so the socket is demonstrably open first.
          await socket.waitForFrameReceived(
              predicate: (f) => f.text() == 'hello',
              timeout: const Duration(seconds: 20));
          final closed =
              socket.waitForClose(timeout: const Duration(seconds: 20));
          await page.evaluate('() => window.closeWs()');
          await closed;
          expect(socket.isClosed(), isTrue);
        });

        test('Deve emitir close quando o servidor fecha o socket', () async {
          await page.goto(server.url('/websocket'));
          final socketFuture =
              page.waitForWebSocket(timeout: const Duration(seconds: 20));
          await page
              .evaluate('() => window.openWs(${_json(server.wsUrl('/ws'))})');
          final socket = await socketFuture;
          final closed =
              socket.waitForClose(timeout: const Duration(seconds: 20));
          await page.evaluate("() => window.sendWs('bye')");
          await closed;
          expect(socket.isClosed(), isTrue);
          final reported = await page.evaluate('() => window.__closed');
          expect((reported as Map)['code'], equals(4001));
        });

        test('Deve limpar os sockets quando o documento navega', () async {
          await page.goto(server.url('/websocket'));
          final socketFuture =
              page.waitForWebSocket(timeout: const Duration(seconds: 20));
          await page
              .evaluate('() => window.openWs(${_json(server.wsUrl('/ws'))})');
          await socketFuture;
          await page.goto(server.url('/hello'));
          // A second page-level socket after the navigation must still be
          // announced: the registry was dropped, not poisoned.
          await page.goto(server.url('/websocket'));
          final again =
              page.waitForWebSocket(timeout: const Duration(seconds: 20));
          await page
              .evaluate('() => window.openWs(${_json(server.wsUrl('/ws'))})');
          expect((await again).url(), equals(server.wsUrl('/ws')));
        });

        test('Handshake recusado vira socketerror e close', () async {
          await page.goto(server.url('/websocket'));
          final urls = <String>[];
          final errors = <String>[];
          final closed = <String>[];
          // The listeners are attached from inside the `websocket` event: a
          // refused handshake errors and closes in the same burst, and this
          // is what upstream's own test does too.
          final subscription = page.onWebSocket.listen((socket) {
            urls.add(socket.url());
            socket.onSocketError.listen(errors.add);
            socket.onClose.listen((s) => closed.add(s.url()));
          });
          addTearDown(subscription.cancel);
          await page.evaluate(
              '() => window.openWs(${_json(server.wsUrl('/ws-refused'))})');
          // Firefox reports the refused handshake as two sockets; see below.
          final expectedSockets = browserName == 'firefox' ? 2 : 1;
          await _until(
              () => closed.length >= expectedSockets && errors.isNotEmpty);

          expect(urls, everyElement(equals(server.wsUrl('/ws-refused'))));
          expect(closed, isNotEmpty);
          if (browserName == 'firefox') {
            // Firefox reports the same refused handshake twice, and upstream
            // does nothing about it: the network layer sees a >= 400 response
            // and synthesises a whole socket (`ffPage.ts:143`), while Juggler
            // separately reports `Page.webSocketCreated` plus a
            // `Page.webSocketClosed` carrying `CLOSE_ABNORMAL`. Both errors
            // are real; neither is invented here.
            expect(urls.length, equals(2));
            expect(errors, contains('Not Found: 404'));
            expect(errors, contains('CLOSE_ABNORMAL'));
          } else {
            expect(urls.length, equals(1));
            // Chromium reports only the frame error; WebKit reports the
            // handshake response as well, so it produces two. What both share
            // is the status.
            expect(errors.any((e) => e.contains('404')), isTrue,
                reason: 'errors were $errors');
          }
        });

        // -------------------------------------------------------- Worker

        test('Deve emitir worker com a url do script', () async {
          await page.goto(server.url('/worker-host'));
          final workerFuture =
              page.waitForWorker(timeout: const Duration(seconds: 20));
          await page.evaluate('() => window.spawnWorker()');
          final worker = await workerFuture;
          expect(worker.url(), endsWith('/worker.js'));
          expect(page.workers().map((w) => w.url()),
              contains(endsWith('/worker.js')));
        });

        test('Deve avaliar dentro do worker', () async {
          await page.goto(server.url('/worker-host'));
          final workerFuture =
              page.waitForWorker(timeout: const Duration(seconds: 20));
          await page.evaluate('() => window.spawnWorker()');
          final worker = await workerFuture;
          expect(await worker.evaluate('() => 6 * 7'), equals(42));
          // Proves the evaluation really happens in the worker's global, not
          // in the page's: the page has no __workerMark, and no `document`
          // exists in a worker.
          expect(await worker.evaluate('() => self.__workerMark'),
              equals('from worker'));
          expect(await worker.evaluate("() => typeof document"),
              equals('undefined'));
        });

        test('Deve devolver handle do worker', () async {
          await page.goto(server.url('/worker-host'));
          final workerFuture =
              page.waitForWorker(timeout: const Duration(seconds: 20));
          await page.evaluate('() => window.spawnWorker()');
          final worker = await workerFuture;
          final handle = await worker.evaluateHandle('() => ({ answer: 42 })');
          expect(await handle.evaluate('(o) => o.answer'), equals(42));
          await handle.dispose();
        });

        test('Deve emitir close quando o worker termina', () async {
          await page.goto(server.url('/worker-host'));
          final workerFuture =
              page.waitForWorker(timeout: const Duration(seconds: 20));
          await page.evaluate('() => window.spawnWorker()');
          final worker = await workerFuture;
          final closed =
              worker.waitForClose(timeout: const Duration(seconds: 20));
          await page.evaluate('() => window.killWorker()');
          await closed;
          expect(worker.isClosed(), isTrue);
          expect(page.workers(), isEmpty);
        });

        test('Deve fechar os workers quando a pagina fecha', () async {
          final victim = await context.newPage();
          await victim.goto(server.url('/worker-host'));
          final workerFuture =
              victim.waitForWorker(timeout: const Duration(seconds: 20));
          await victim.evaluate('() => window.spawnWorker()');
          final worker = await workerFuture;
          final closed =
              worker.waitForClose(timeout: const Duration(seconds: 20));
          await victim.close();
          await closed;
          expect(worker.isClosed(), isTrue);
        });
      });
    }
  });
}

/// A JSON string literal, so a URL can be interpolated into an evaluated
/// expression without quoting accidents.
String _json(String value) => '"${value.replaceAll('"', r'\"')}"';

/// Polls [condition] until it holds or [timeout] runs out.
///
/// Used where the events being collected arrive in one burst and there is no
/// single one to wait for.
Future<void> _until(bool Function() condition,
    {Duration timeout = const Duration(seconds: 20)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Condition never held within ${timeout.inSeconds}s');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}
