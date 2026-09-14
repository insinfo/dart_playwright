import 'dart:async';
import 'dart:io';

import 'package:playwright/playwright.dart';
import 'package:test/test.dart';

import 'test_server.dart';

/// A proxy that answers everything itself instead of forwarding.
///
/// That is what makes the test unambiguous: if the page shows the proxy's
/// body, the request went through the proxy; if it shows the site's, it did
/// not. A forwarding proxy would look identical either way.
class _RecordingProxy {
  _RecordingProxy(this._server);

  final HttpServer _server;
  final requested = <String>[];

  int get port => _server.port;
  String get url => 'http://127.0.0.1:$port';

  static Future<_RecordingProxy> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = _RecordingProxy(server);
    unawaited(proxy._serve());
    return proxy;
  }

  Future<void> _serve() async {
    await for (final request in _server) {
      requested.add(request.uri.toString());
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write('<html><head><title>Proxied</title></head>'
            '<body>through the proxy</body></html>');
      await request.response.close();
    }
  }

  Future<void> stop() => _server.close(force: true);
}

void main() {
  group('proxy', () {
    late Playwright playwright;
    late TestServer server;
    late _RecordingProxy proxy;

    setUpAll(() async {
      server = await TestServer.start();
      proxy = await _RecordingProxy.start();
      playwright = await Playwright.create();
    });

    tearDownAll(() async {
      await server.stop();
      await proxy.stop();
    });

    BrowserType typeFor(String name) => switch (name) {
          'chromium' => playwright.chromium,
          'firefox' => playwright.firefox,
          _ => playwright.webkit,
        };

    // All three engines take a proxy per context, so this is not a Chromium
    // special case and is tested everywhere.
    for (final browserName in ['chromium', 'firefox', 'webkit']) {
      group('[$browserName]', () {
        test('a context launched without one reaches the site directly',
            () async {
          final browser = await typeFor(browserName).launch(headless: true);
          try {
            final context = await browser.newContext();
            final page = await context.newPage();
            await page.goto(server.url('/title'));
            expect(await page.title(), 'Test Page Title');
          } finally {
            await browser.close();
          }
        });

        test('newContext(proxy:) routes that context through it', () async {
          final before = proxy.requested.length;
          final browser = await typeFor(browserName).launch(headless: true);
          try {
            final context = await browser.newContext(
              proxy: (
                server: proxy.url,
                bypass: null,
                username: null,
                password: null
              ),
            );
            final page = await context.newPage();
            await page.goto(server.url('/title'));
            expect(await page.title(), 'Proxied');
            expect(proxy.requested.length, greaterThan(before));
          } finally {
            await browser.close();
          }
        });

        test('the proxy is the context\'s, not the browser\'s', () async {
          final browser = await typeFor(browserName).launch(headless: true);
          try {
            final proxied = await browser.newContext(
              proxy: (
                server: proxy.url,
                bypass: null,
                username: null,
                password: null
              ),
            );
            // The order is deliberate. On WebKit for Windows, creating a
            // context without a proxy after one with a proxy makes the first
            // one stop using it — the Windows build routes through curl,
            // whose proxy looks process-wide rather than per context. That
            // is a real limitation of that build, not of this API, and it is
            // the only order in which the isolation can be observed there.
            final proxiedPage = await proxied.newPage();
            await proxiedPage.goto(server.url('/title'));
            expect(await proxiedPage.title(), 'Proxied');

            final direct = await browser.newContext();
            final directPage = await direct.newPage();
            await directPage.goto(server.url('/title'));
            expect(await directPage.title(), 'Test Page Title',
                reason: 'a context without a proxy must not inherit another '
                    "context's");
          } finally {
            await browser.close();
          }
        });

        test('launch(proxy:) routes every context of the browser', () async {
          final browser = await typeFor(browserName).launch(
            headless: true,
            proxy: (
              server: proxy.url,
              bypass: null,
              username: null,
              password: null
            ),
          );
          try {
            final context = await browser.newContext();
            final page = await context.newPage();
            await page.goto(server.url('/title'));
            expect(await page.title(), 'Proxied');
          } finally {
            await browser.close();
          }
        });
      });
    }

    test('a proxy scheme no engine speaks is refused at once', () async {
      final browser = await playwright.chromium.launch(headless: true);
      try {
        await expectLater(
          browser.newContext(
            proxy: (
              server: 'ftp://127.0.0.1:21',
              bypass: null,
              username: null,
              password: null
            ),
          ),
          throwsA(isA<ArgumentError>()),
        );
      } finally {
        await browser.close();
      }
    });
  }, timeout: const Timeout(Duration(minutes: 6)));
}
