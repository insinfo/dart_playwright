import 'dart:async';

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
          final log = _SocketLog(page);
          addTearDown(log.dispose);
          await page
              .evaluate('() => window.openWs(${_json(server.wsUrl('/ws'))})');
          await _until(() => log.receivedText.contains('hello'));
          expect(log.received.first.isText, isTrue);
        });

        test('Deve reportar framesent da pagina', () async {
          await page.goto(server.url('/websocket'));
          final log = _SocketLog(page);
          addTearDown(log.dispose);
          await page
              .evaluate('() => window.openWs(${_json(server.wsUrl('/ws'))})');
          await page.evaluate("() => window.sendWs('ping')");
          await _until(() => log.sentText.contains('ping'));
          await _until(() => log.receivedText.contains('echo:ping'));
        });

        test('Deve decodificar frame binario em bytes', () async {
          await page.goto(server.url('/websocket'));
          final log = _SocketLog(page);
          addTearDown(log.dispose);
          await page
              .evaluate('() => window.openWs(${_json(server.wsUrl('/ws'))})');
          await page.evaluate('() => window.sendWsBinary()');
          await _until(() => log.received.any((frame) => !frame.isText));
          // The echo server adds one to every byte of [1, 2, 3].
          expect(log.received.firstWhere((frame) => !frame.isText).binary(),
              equals([2, 3, 4]));
          // What the page sent comes back untouched on the sent side.
          expect(log.sent.firstWhere((frame) => !frame.isText).binary(),
              equals([1, 2, 3]));
        });

        test('Deve emitir close quando a pagina fecha o socket', () async {
          await page.goto(server.url('/websocket'));
          final log = _SocketLog(page);
          addTearDown(log.dispose);
          await page
              .evaluate('() => window.openWs(${_json(server.wsUrl('/ws'))})');
          // Wait for the greeting so the socket is demonstrably open first.
          await _until(() => log.receivedText.contains('hello'));
          await page.evaluate('() => window.closeWs()');
          await _until(() => log.closed.isNotEmpty);
          expect(log.sockets.single.isClosed(), isTrue);
        });

        test('Deve emitir close quando o servidor fecha o socket', () async {
          await page.goto(server.url('/websocket'));
          final log = _SocketLog(page);
          addTearDown(log.dispose);
          await page
              .evaluate('() => window.openWs(${_json(server.wsUrl('/ws'))})');
          await page.evaluate("() => window.sendWs('bye')");
          await _until(() => log.closed.isNotEmpty);
          expect(log.sockets.single.isClosed(), isTrue);
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
          // The collector subscribes from inside the `websocket` event: a
          // refused handshake errors and closes in the same burst, and this
          // is what upstream's own test does too.
          final log = _SocketLog(page);
          addTearDown(log.dispose);
          await page.evaluate(
              '() => window.openWs(${_json(server.wsUrl('/ws-refused'))})');
          // Firefox reports the refused handshake as two sockets; see below.
          final expectedSockets = browserName == 'firefox' ? 2 : 1;
          await _until(() =>
              log.closed.length >= expectedSockets && log.errors.isNotEmpty);

          expect(log.sockets.map((socket) => socket.url()),
              everyElement(equals(server.wsUrl('/ws-refused'))));
          final errors = log.errors;
          if (browserName == 'firefox') {
            // Firefox reports the same refused handshake twice, and upstream
            // does nothing about it: the network layer sees a >= 400 response
            // and synthesises a whole socket (`ffPage.ts:143`), while Juggler
            // separately reports `Page.webSocketCreated` plus a
            // `Page.webSocketClosed` carrying `CLOSE_ABNORMAL`. Both errors
            // are real; neither is invented here.
            expect(log.sockets.length, equals(2));
            expect(errors, contains('Not Found: 404'));
            expect(errors, contains('CLOSE_ABNORMAL'));
          } else {
            expect(log.sockets.length, equals(1));
            // Chromium reports only the frame error; WebKit reports the
            // handshake response as well, so it produces two. What both share
            // is the status.
            expect(errors.any((e) => e.contains('404')), isTrue,
                reason: 'errors were $errors');
          }
        });

        // ------------------------------------------------ WebSocketRoute

        test('Deve mockar o socket inteiro sem servidor', () async {
          await page.routeWebSocket('**/*', (route) async {
            route.onMessage((message) {
              if (message.text() == 'ping') route.send('pong');
            });
          });
          // The mock lives in an init script, so it only reaches the next
          // document — the navigation has to come after the route.
          await page.goto(server.url('/websocket'));
          expect(
              await page
                  .evaluate('() => window.openWs(${_json(_unusedWs(server))})'),
              equals('open'));
          await page.evaluate("() => window.sendWs('ping')");
          await _until(() async {
            final received = await page.evaluate('() => window.__received');
            return (received as List).contains('pong');
          });
          // Nothing ever reached the real server: the URL does not even
          // exist there.
          expect(await page.evaluate('() => window.readyState()'), equals(1));
        });

        test('Deve repassar para o servidor com connectToServer', () async {
          final fromPage = <String>[];
          final fromServer = <String>[];
          await page.routeWebSocket('**/*', (route) async {
            final serverSide = route.connectToServer();
            route.onMessage((message) {
              fromPage.add(message.text());
              // Rewrite on the way out, to prove the handler is in the path.
              serverSide.send('routed:${message.text()}');
            });
            serverSide.onMessage((message) {
              fromServer.add(message.text());
              route.send(message.text());
            });
          });
          await page.goto(server.url('/websocket'));
          await page
              .evaluate('() => window.openWs(${_json(server.wsUrl('/ws'))})');
          await page.evaluate("() => window.sendWs('ping')");
          await _until(() async {
            final received = await page.evaluate('() => window.__received');
            return (received as List).contains('echo:routed:ping');
          });
          expect(fromPage, contains('ping'));
          expect(fromServer, contains('hello'));
        });

        test('Sem handler o socket passa direto', () async {
          // A route that matches nothing still installs the mock, so this
          // proves the passthrough path: the page talks to the real server
          // through a mocked WebSocket.
          await page.routeWebSocket('**/never-matches', (route) async {});
          await page.goto(server.url('/websocket'));
          await page
              .evaluate('() => window.openWs(${_json(server.wsUrl('/ws'))})');
          await page.evaluate("() => window.sendWs('ping')");
          await _until(() async {
            final received = await page.evaluate('() => window.__received');
            final list = received as List;
            return list.contains('hello') && list.contains('echo:ping');
          });
        });

        test('Deve fechar o socket mockado pelo handler', () async {
          await page.routeWebSocket('**/*', (route) async {
            route.onMessage((message) async {
              await route.close(code: 4321, reason: 'handler closed');
            });
          });
          await page.goto(server.url('/websocket'));
          await page
              .evaluate('() => window.openWs(${_json(_unusedWs(server))})');
          await page.evaluate("() => window.sendWs('close me')");
          await _until(() async {
            final closed = await page.evaluate('() => window.__closed');
            return closed != null;
          });
          final closed = await page.evaluate('() => window.__closed')
              as Map<dynamic, dynamic>;
          expect(closed['code'], equals(4321));
          expect(closed['reason'], equals('handler closed'));
        });

        test('Deve ver o fechamento vindo da pagina', () async {
          final seen = <({int? code, String? reason})>[];
          await page.routeWebSocket('**/*', (route) async {
            route.onClose((code, reason) => seen.add((
                  code: code,
                  reason: reason,
                )));
          });
          await page.goto(server.url('/websocket'));
          await page
              .evaluate('() => window.openWs(${_json(_unusedWs(server))})');
          await page.evaluate("() => window.__ws.close(3001, 'page said bye')");
          await _until(() async => seen.isNotEmpty);
          expect(seen.single.code, equals(3001));
          expect(seen.single.reason, equals('page said bye'));
        });

        test('Fechamento sem codigo chega como nulo', () async {
          final seen = <({int? code, String? reason})>[];
          await page.routeWebSocket('**/*', (route) async {
            route.onClose(
                (code, reason) => seen.add((code: code, reason: reason)));
          });
          await page.goto(server.url('/websocket'));
          await page
              .evaluate('() => window.openWs(${_json(_unusedWs(server))})');
          await page.evaluate('() => window.closeWs()');
          await _until(() async => seen.isNotEmpty);
          // `close()` with no arguments gives the handler no code, which is
          // upstream's `undefined`. 1000 is what the browser would put on the
          // wire, not what the routing API is told, and inventing it here
          // would be a lie about which of the two the caller is seeing.
          expect(seen.single.code, isNull);
          expect(seen.single.reason, isNull);
        });

        test('Deve rotear no nivel do contexto', () async {
          await context.routeWebSocket('**/*', (route) async {
            route.onMessage((message) => route.send('ctx:${message.text()}'));
          });
          final second = await context.newPage();
          await second.goto(server.url('/websocket'));
          await second
              .evaluate('() => window.openWs(${_json(_unusedWs(server))})');
          await second.evaluate("() => window.sendWs('hi')");
          await _until(() async {
            final received = await second.evaluate('() => window.__received');
            return (received as List).contains('ctx:hi');
          });
        });

        test('Deve enviar e receber binario pelo route', () async {
          await page.routeWebSocket('**/*', (route) async {
            route.onMessage((message) {
              if (!message.isText) {
                route.sendBinary(
                    <int>[for (final byte in message.binary()) byte * 2]);
              }
            });
          });
          await page.goto(server.url('/websocket'));
          await page
              .evaluate('() => window.openWs(${_json(_unusedWs(server))})');
          await page.evaluate('''() => {
            window.__binary = null;
            window.__ws.addEventListener('message', async (e) => {
              if (typeof e.data !== 'string')
                window.__binary = Array.from(new Uint8Array(await e.data.arrayBuffer()));
            });
            window.sendWsBinary();
          }''');
          await _until(
              () async => await page.evaluate('() => window.__binary') != null);
          expect(
              await page.evaluate('() => window.__binary'), equals([2, 4, 6]));
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
Future<void> _until(FutureOr<bool> Function() condition,
    {Duration timeout = const Duration(seconds: 20)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Condition never held within ${timeout.inSeconds}s');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

/// Everything the sockets of one page report.
///
/// It subscribes from inside the `websocket` event, so a frame or an error
/// emitted in the same burst as the socket itself is not missed — which is
/// exactly what the greeting the echo server sends on connect, and a refused
/// handshake, do. Waiting for the socket first and only then subscribing is
/// a race, and it is the race upstream's own tests avoid the same way.
class _SocketLog {
  final sockets = <WebSocket>[];
  final sent = <WebSocketFrame>[];
  final received = <WebSocketFrame>[];
  final errors = <String>[];
  final closed = <WebSocket>[];

  late final StreamSubscription<WebSocket> _subscription;

  _SocketLog(Page page) {
    _subscription = page.onWebSocket.listen((socket) {
      sockets.add(socket);
      socket.onFrameSent.listen(sent.add);
      socket.onFrameReceived.listen(received.add);
      socket.onSocketError.listen(errors.add);
      socket.onClose.listen(closed.add);
    });
  }

  List<String> get sentText => [
        for (final frame in sent)
          if (frame.isText) frame.text()
      ];

  List<String> get receivedText => [
        for (final frame in received)
          if (frame.isText) frame.text()
      ];

  Future<void> dispose() => _subscription.cancel();
}

/// A `ws://` URL on the test server that nothing answers.
///
/// A socket pointed at it can only work if `routeWebSocket` mocked it whole:
/// the server replies 404 to the upgrade.
String _unusedWs(TestServer server) => server.wsUrl('/mocked-only');
