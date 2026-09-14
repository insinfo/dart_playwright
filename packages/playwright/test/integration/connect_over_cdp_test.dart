import 'dart:io';

import 'package:playwright/playwright.dart';
import 'package:playwright_core/playwright_core.dart';
import 'package:test/test.dart';

import 'test_server.dart';

/// `connectOverCDP` against a Chromium this test started itself, the way a
/// user attaches to a browser they are already running.
///
/// Chromium only, and deliberately so: CDP is Chromium's protocol. Firefox
/// speaks Juggler and WebKit its own inspector protocol, so there is no
/// parity run to do here — only the promise that asking them says so
/// clearly, which the last test checks.
void main() {
  group('connectOverCDP', () {
    late Playwright playwright;
    late TestServer server;
    Process? chromium;
    Directory? profile;
    late String httpEndpoint;

    setUpAll(() async {
      server = await TestServer.start();
      playwright = await Playwright.create();

      final executable = BrowserRegistry().executablePath('chromium');
      if (executable == null || !File(executable).existsSync()) {
        throw StateError('Chromium is not installed; run `playwright install '
            'chromium` before this suite.');
      }

      profile = Directory.systemTemp.createTempSync('pw_cdp_profile_');
      // Port 0 lets the OS pick; Chromium writes the one it got into
      // DevToolsActivePort, which is how the endpoint is discovered without
      // guessing a free port.
      chromium = await Process.start(executable, [
        '--headless',
        '--no-first-run',
        '--no-default-browser-check',
        '--disable-gpu',
        '--remote-debugging-port=0',
        '--user-data-dir=${profile!.path}',
      ]);
      chromium!.stdout.drain<void>().catchError((_) {});
      chromium!.stderr.drain<void>().catchError((_) {});

      final portFile = File('${profile!.path}/DevToolsActivePort');
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (DateTime.now().isBefore(deadline)) {
        if (portFile.existsSync()) {
          final lines = portFile.readAsLinesSync();
          if (lines.isNotEmpty && int.tryParse(lines.first.trim()) != null) {
            httpEndpoint = 'http://127.0.0.1:${lines.first.trim()}';
            return;
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      throw StateError('Chromium never reported a DevTools port');
    });

    tearDownAll(() async {
      await server.stop();
      final pid = chromium?.pid;
      if (pid != null) {
        // The whole tree: this browser was started outside the registry, so
        // nothing else is going to reap its renderer children.
        try {
          Process.runSync('taskkill', ['/pid', '$pid', '/T', '/F']);
        } catch (_) {
          chromium?.kill(ProcessSignal.sigkill);
        }
      }
      try {
        profile?.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('an http endpoint is resolved to the websocket one', () async {
      final browser = await playwright.chromium.connectOverCDP(httpEndpoint);
      try {
        expect(browser.isConnected(), isTrue);
        expect(await browser.version(), contains('Chrome'));
      } finally {
        await browser.close();
      }
    });

    test('a page created over the connection works', () async {
      final browser = await playwright.chromium.connectOverCDP(httpEndpoint);
      try {
        expect(browser.contexts(), isNotEmpty,
            reason: 'the browser already has its default context');
        final context = browser.contexts().first;
        final page = await context.newPage();
        await page.goto(server.url('/title'));
        expect(await page.title(), 'Test Page Title');
        await page.close();
      } finally {
        await browser.close();
      }
    });

    test('close() disconnects but leaves the browser running', () async {
      final browser = await playwright.chromium.connectOverCDP(httpEndpoint);
      await browser.close();
      expect(browser.isConnected(), isFalse);

      // The proof it is still alive: connecting again works.
      final again = await playwright.chromium.connectOverCDP(httpEndpoint);
      try {
        expect(again.isConnected(), isTrue);
      } finally {
        await again.close();
      }
    });

    test('a websocket endpoint is taken as given', () async {
      final portFile = File('${profile!.path}/DevToolsActivePort');
      final lines = portFile.readAsLinesSync();
      final wsEndpoint =
          'ws://127.0.0.1:${lines[0].trim()}${lines[1].trim()}';
      final browser = await playwright.chromium.connectOverCDP(wsEndpoint);
      try {
        expect(browser.isConnected(), isTrue);
      } finally {
        await browser.close();
      }
    });

    test('an endpoint that answers nothing fails instead of hanging',
        () async {
      await expectLater(
        playwright.chromium.connectOverCDP('http://127.0.0.1:1',
            timeout: const Duration(seconds: 5)),
        throwsA(isA<PlaywrightException>()),
      );
    });

    // Not a gap in this port: neither engine implements CDP at all.
    for (final engine in ['firefox', 'webkit']) {
      test('[$engine] says CDP is Chromium-only rather than failing obscurely',
          () async {
        final type =
            engine == 'firefox' ? playwright.firefox : playwright.webkit;
        await expectLater(
          type.connectOverCDP(httpEndpoint),
          throwsA(
            isA<PlaywrightException>().having(
              (e) => e.toString(),
              'message',
              contains('Chromium-only'),
            ),
          ),
        );
      });
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
