import 'dart:convert';

import 'package:playwright/playwright.dart';
import 'package:test/test.dart';

import 'test_server.dart';

/// Parity coverage for the Milestone 4 context options, on Chromium, Firefox
/// and WebKit.
///
/// Each option is asserted through what the *page* observes, not through the
/// protocol command that was sent: the three engines apply these at three
/// different layers, and the only thing that matters is that the page agrees.
void main() {
  group('Emulacao de contexto', () {
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

        /// Opens a context with [build]'s options, runs [body], closes it.
        Future<void> withContext(Future<BrowserContext> Function() build,
            Future<void> Function(Page page) body) async {
          final context = await build();
          try {
            final page = await context.newPage();
            await body(page);
          } finally {
            await context.close();
          }
        }

        test('locale deve chegar em navigator.language', () async {
          await withContext(
            () => browser.newContext(locale: 'pt-BR'),
            (page) async {
              await page.goto(server.url('/hello'));
              expect(await page.evaluate('() => navigator.language'),
                  equals('pt-BR'));
            },
          );
        });

        test('locale deve chegar no Accept-Language do servidor', () async {
          await withContext(
            () => browser.newContext(locale: 'pt-BR'),
            (page) async {
              await page.goto(server.url('/echo-headers'));
              final headers = jsonDecode(
                  (await page.evaluate('() => document.body.innerText'))
                      .toString()) as Map<String, dynamic>;
              expect(headers['accept-language'], contains('pt-BR'));
            },
          );
        });

        test('timezoneId deve mudar o fuso da pagina', () async {
          await withContext(
            () => browser.newContext(timezoneId: 'America/Sao_Paulo'),
            (page) async {
              await page.goto(server.url('/hello'));
              final zone = await page.evaluate(
                  '() => Intl.DateTimeFormat().resolvedOptions().timeZone');
              expect(zone, equals('America/Sao_Paulo'));
            },
          );
        });

        test('timezoneId invalido deve ser recusado', () async {
          // Chromium and WebKit reject when the override is set; Firefox only
          // when the page is created. Either way the caller sees the same
          // error, which is the point.
          expect(
            () async {
              final context =
                  await browser.newContext(timezoneId: 'Nao/Existe');
              try {
                await context.newPage();
              } finally {
                await context.close();
              }
            },
            throwsA(isA<PlaywrightException>()),
          );
        });

        test('colorScheme deve dirigir prefers-color-scheme', () async {
          await withContext(
            () => browser.newContext(colorScheme: 'dark'),
            (page) async {
              await page.goto(server.url('/hello'));
              expect(
                  await page.evaluate(
                      "() => matchMedia('(prefers-color-scheme: dark)').matches"),
                  isTrue);
            },
          );
          await withContext(
            () => browser.newContext(colorScheme: 'light'),
            (page) async {
              await page.goto(server.url('/hello'));
              expect(
                  await page.evaluate(
                      "() => matchMedia('(prefers-color-scheme: dark)').matches"),
                  isFalse);
            },
          );
        });

        test('reducedMotion deve dirigir prefers-reduced-motion', () async {
          await withContext(
            () => browser.newContext(reducedMotion: 'reduce'),
            (page) async {
              await page.goto(server.url('/hello'));
              expect(
                  await page.evaluate(
                      "() => matchMedia('(prefers-reduced-motion: reduce)').matches"),
                  isTrue);
            },
          );
        });

        test('deviceScaleFactor deve chegar em devicePixelRatio', () async {
          await withContext(
            () => browser.newContext(
                viewport: (width: 400, height: 300), deviceScaleFactor: 2),
            (page) async {
              await page.goto(server.url('/hello'));
              expect(await page.evaluate('() => window.devicePixelRatio'),
                  equals(2));
            },
          );
        });

        test('hasTouch deve expor touch e permitir tap', () async {
          await withContext(
            () => browser.newContext(
                viewport: (width: 400, height: 400), hasTouch: true),
            (page) async {
              await page.goto(server.url('/touch'));
              expect(await page.evaluate("() => 'ontouchstart' in window"),
                  isTrue);
              await page.locator('#pad').tap();
              // The page records event.isTrusted, so a synthetic tap would
              // not pass this.
              expect(await page.evaluate('() => window.__tapped'), isTrue);
            },
          );
        });

        test('offline deve derrubar a rede da pagina', () async {
          await withContext(
            () => browser.newContext(offline: true),
            (page) async {
              // The engines differ in how they refuse: some fail the
              // navigation outright, others stall it. Either way it must not
              // succeed, and the bounded timeout is what turns a stall into a
              // failure instead of a hang.
              await expectLater(
                page.goto(server.url('/hello'),
                    timeout: const Duration(seconds: 10)),
                throwsA(isA<Object>()),
              );
            },
          );
        });

        test('extraHTTPHeaders do contexto devem chegar no servidor', () async {
          await withContext(
            () => browser
                .newContext(extraHTTPHeaders: {'X-Context-Header': 'presente'}),
            (page) async {
              await page.goto(server.url('/echo-headers'));
              final headers = jsonDecode(
                  (await page.evaluate('() => document.body.innerText'))
                      .toString()) as Map<String, dynamic>;
              expect(headers['x-context-header'], equals('presente'));
            },
          );
        });

        test('geolocation deve ser reportada por navigator.geolocation',
            () async {
          await withContext(
            () => browser.newContext(
              geolocation: (
                latitude: -23.5505,
                longitude: -46.6333,
                accuracy: 10
              ),
              permissions: ['geolocation'],
            ),
            (page) async {
              await page.goto(server.url('/hello'));
              // Ask the page to stash the result and poll for it, rather than
              // returning a promise from evaluate: Juggler's Runtime.evaluate
              // has no awaitPromise flag and no equivalent, so a promise
              // cannot be awaited through the Firefox protocol at all.
              await page.evaluate('''
                () => {
                  window.__geo = null;
                  navigator.geolocation.getCurrentPosition(
                    (p) => { window.__geo = { lat: p.coords.latitude, lon: p.coords.longitude }; },
                    (e) => { window.__geo = { error: e.message }; },
                    { timeout: 5000 });
                }
              ''');
              final position = await page.waitForFunction('() => window.__geo',
                  timeout: const Duration(seconds: 15)) as Map;
              expect(position['error'], isNull,
                  reason: 'geolocation was refused: ${position['error']}');
              expect((position['lat'] as num).toStringAsFixed(4),
                  equals('-23.5505'));
              expect((position['lon'] as num).toStringAsFixed(4),
                  equals('-46.6333'));
            },
          );
        }, timeout: const Timeout(Duration(minutes: 2)));

        test('permissao desconhecida no motor deve ser recusada', () async {
          // The engines know very different sets, and asking for one an
          // engine does not have fails loudly instead of passing for the
          // wrong reason. `camera` is known to Chromium and WebKit but not
          // to Firefox; `push` is the other way round.
          final unknown = browserName == 'firefox' ? 'camera' : 'push';
          await expectLater(
            browser.newContext(permissions: [unknown]),
            throwsArgumentError,
          );
        });
      });
    }

    // These two share one browser and launch it in setUpAll. Launching a
    // fourth browser inline, while the three engine groups are tearing theirs
    // down, is enough to time out on a loaded machine -- which is exactly how
    // this pair flaked once before.
    group('[chromium] catalogo e test id', () {
      late Browser browser;
      var launched = false;

      setUpAll(() async {
        browser = await playwright.chromium.launch(headless: true);
        launched = true;
      });

      tearDownAll(() async {
        if (launched) await browser.close();
      });

      test('setTestIdAttribute deve mudar o atributo de getByTestId', () async {
        final context = await browser.newContext();
        addTearDown(context.close);
        final page = await context.newPage();
        await page.setContent('<button data-qa="salvar">Salvar</button>'
            '<button data-testid="salvar">Outro</button>');

        // The default is data-testid.
        expect(await page.getByTestId('salvar').textContent(), equals('Outro'));

        setTestIdAttribute('data-qa');
        addTearDown(() => setTestIdAttribute('data-testid'));
        expect(
            await page.getByTestId('salvar').textContent(), equals('Salvar'));

        // An explicit attribute still wins over the global.
        expect(
            await page
                .getByTestId('salvar', attributeName: 'data-testid')
                .textContent(),
            equals('Outro'));
      });

      test('devices deve emular um preset conhecido', () async {
        final device = devices['Pixel 5']!;
        final context = await browser.newContext(
          viewport: device.viewport,
          userAgent: device.userAgent,
          deviceScaleFactor: device.deviceScaleFactor,
          isMobile: device.isMobile,
          hasTouch: device.hasTouch,
        );
        addTearDown(context.close);
        final page = await context.newPage();
        await page.goto(server.url('/hello'));
        // Not innerWidth: with isMobile on, a page without a viewport meta tag
        // gets the 980px fallback layout viewport, which is correct mobile
        // emulation and not the device width. screen.width is the device.
        expect(await page.evaluate('() => window.screen.width'),
            equals(device.viewport.width));
        expect(await page.evaluate('() => navigator.userAgent'),
            equals(device.userAgent));
        expect(await page.evaluate('() => window.devicePixelRatio'),
            equals(device.deviceScaleFactor));
        expect(await page.evaluate("() => 'ontouchstart' in window"), isTrue);
      });
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
