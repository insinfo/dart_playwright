import 'dart:io';

import 'package:playwright/playwright.dart';
import 'package:test/test.dart';

import 'test_server.dart';

/// `launchPersistentContext` in all three engines: the profile is on disk, so
/// what a run leaves in it is still there for the next one. That is the whole
/// difference from `launch` + `newContext`, and it is what these tests check —
/// not that a page loads, but that the state survives the browser.
void main() {
  group('launchPersistentContext', () {
    late Playwright playwright;
    late TestServer server;
    final profiles = <Directory>[];

    setUpAll(() async {
      server = await TestServer.start();
      playwright = await Playwright.create();
    });

    tearDownAll(() async {
      await server.stop();
      for (final profile in profiles) {
        try {
          profile.deleteSync(recursive: true);
        } catch (_) {
          // Windows holds the profile open for a moment after the browser
          // dies; leaving it for the TEMP sweeper is better than failing the
          // run over a directory.
        }
      }
    });

    Directory newProfile(String name) {
      final dir = Directory.systemTemp.createTempSync('pw_persist_${name}_');
      profiles.add(dir);
      return dir;
    }

    BrowserType typeFor(String name) => switch (name) {
          'chromium' => playwright.chromium,
          'firefox' => playwright.firefox,
          _ => playwright.webkit,
        };

    for (final browserName in ['chromium', 'firefox', 'webkit']) {
      group('[$browserName]', () {
        test('returns a usable context rather than a browser', () async {
          final profile = newProfile(browserName);
          final context = await typeFor(browserName)
              .launchPersistentContext(profile.path, headless: true);
          try {
            final page = await context.newPage();
            await page.goto(server.url('/title'));
            expect(await page.title(), 'Test Page Title');
            expect(context.isClosed(), isFalse);
          } finally {
            await context.close();
          }
        });

        test('localStorage written in one run is there in the next', () async {
          final profile = newProfile(browserName);

          final first = await typeFor(browserName)
              .launchPersistentContext(profile.path, headless: true);
          try {
            final page = await first.newPage();
            await page.goto(server.url('/hello'));
            await page.evaluate(
                "() => localStorage.setItem('survivor', 'still here')");
            // Give the engine a moment to flush the profile to disk before
            // the process goes away.
            await page.evaluate("() => localStorage.getItem('survivor')");
          } finally {
            await first.close();
          }

          final second = await typeFor(browserName)
              .launchPersistentContext(profile.path, headless: true);
          try {
            final page = await second.newPage();
            await page.goto(server.url('/hello'));
            final value = await page
                .evaluate("() => localStorage.getItem('survivor')");
            expect(value, 'still here',
                reason: 'the profile at ${profile.path} did not persist '
                    'localStorage across runs');
          } finally {
            await second.close();
          }
        });

        test('a cookie with an expiry outlives the browser', () async {
          final profile = newProfile(browserName);
          final expires = DateTime.now()
                  .add(const Duration(days: 1))
                  .millisecondsSinceEpoch /
              1000;

          final first = await typeFor(browserName)
              .launchPersistentContext(profile.path, headless: true);
          try {
            await first.addCookies([
              {
                'name': 'persisted',
                'value': 'yes',
                'domain': '127.0.0.1',
                'path': '/',
                'expires': expires,
              }
            ]);
          } finally {
            await first.close();
          }

          final second = await typeFor(browserName)
              .launchPersistentContext(profile.path, headless: true);
          try {
            final cookies = await second.cookies();
            expect(cookies.map((c) => c['name']), contains('persisted'));
          } finally {
            await second.close();
          }
        });

        test('closing the context closes the browser with it', () async {
          final profile = newProfile(browserName);
          final context = await typeFor(browserName)
              .launchPersistentContext(profile.path, headless: true);
          final page = await context.newPage();
          await page.goto(server.url('/hello'));

          await context.close();

          expect(context.isClosed(), isTrue);
          // There is no browser left to make a page in: a persistent context
          // owns the process, so this must fail rather than hang.
          await expectLater(
            context.newPage().timeout(const Duration(seconds: 10)),
            throwsA(anything),
          );
        });

        test('context options apply to the profile context too', () async {
          final profile = newProfile(browserName);
          final context = await typeFor(browserName).launchPersistentContext(
            profile.path,
            headless: true,
            viewport: (width: 501, height: 407),
            userAgent: 'PersistentContextProbe/1.0',
          );
          try {
            final page = await context.newPage();
            await page.goto(server.url('/hello'));
            expect(await page.evaluate('() => navigator.userAgent'),
                'PersistentContextProbe/1.0');
            expect(await page.evaluate('() => window.innerWidth'), 501);
          } finally {
            await context.close();
          }
        });
      });
    }

    test('userDataDir must be an absolute path', () async {
      await expectLater(
        playwright.chromium.launchPersistentContext('relative/profile'),
        throwsA(isA<ArgumentError>()),
      );
    });
  }, timeout: const Timeout(Duration(minutes: 5)));
}
