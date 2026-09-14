import 'package:playwright_core/playwright_core.dart';
import 'package:playwright_core/src/server/chromium/chromium.dart';
import 'package:playwright_core/src/server/firefox/ff_browser.dart';
import 'package:playwright_core/src/server/firefox/firefox.dart';
import 'package:playwright_core/src/server/launch_options.dart';
import 'package:playwright_core/src/server/webkit/webkit.dart';
import 'package:test/test.dart';

void main() {
  final registry = BrowserRegistry();
  final chromium = ChromiumBrowserType(registry);
  final firefox = FirefoxBrowserType(registry);
  final webkit = WebKitBrowserType(registry);

  // The command line is the whole of what a launch option does for most of
  // these, and it can be checked without spending a browser process on it.
  group('default arguments', () {
    test('[chromium] a persistent launch opens a page, a plain one does not',
        () {
      final plain = chromium.defaultArgs(const CoreLaunchOptions(), '/profile');
      expect(plain, contains('--no-startup-window'));
      expect(plain, isNot(contains('about:blank')));
      expect(plain, contains('--user-data-dir=/profile'));

      final persistent = chromium.defaultArgs(
          const CoreLaunchOptions(userDataDir: '/p'), '/p');
      expect(persistent, contains('about:blank'));
      expect(persistent, isNot(contains('--no-startup-window')));
    });

    test('[firefox] a persistent launch opens a page, a plain one is silent',
        () {
      final plain = firefox.defaultArgs(const CoreLaunchOptions(), '/profile');
      expect(plain, contains('-silent'));
      expect(plain, containsAllInOrder(['-profile', '/profile']));

      final persistent =
          firefox.defaultArgs(const CoreLaunchOptions(userDataDir: '/p'), '/p');
      expect(persistent, contains('about:blank'));
      expect(persistent, isNot(contains('-silent')));
    });

    test('[webkit] only a persistent launch is given the profile', () {
      final plain = webkit.defaultArgs(const CoreLaunchOptions(), '/profile');
      expect(plain, contains('--no-startup-window'));
      expect(plain.where((a) => a.startsWith('--user-data-dir')), isEmpty);

      final persistent =
          webkit.defaultArgs(const CoreLaunchOptions(userDataDir: '/p'), '/p');
      expect(persistent, contains('--user-data-dir=/p'));
      expect(persistent, contains('about:blank'));
    });

    test('headless is what adds the headless switches', () {
      expect(chromium.defaultArgs(const CoreLaunchOptions(), '/p'),
          contains('--headless'));
      expect(
          chromium.defaultArgs(const CoreLaunchOptions(headless: false), '/p'),
          isNot(contains('--headless')));
      expect(firefox.defaultArgs(const CoreLaunchOptions(), '/p'),
          contains('-headless'));
      expect(webkit.defaultArgs(const CoreLaunchOptions(), '/p'),
          contains('--headless'));
    });

    test('[chromium] chromiumSandbox: true is what keeps the sandbox on', () {
      expect(chromium.defaultArgs(const CoreLaunchOptions(), '/p'),
          contains('--no-sandbox'));
      expect(
          chromium.defaultArgs(
              const CoreLaunchOptions(chromiumSandbox: true), '/p'),
          isNot(contains('--no-sandbox')));
    });
  });

  group('ignoreDefaultArgs', () {
    test('drops the named defaults and keeps the rest', () {
      final args = chromium.defaultArgs(
          const CoreLaunchOptions(ignoreDefaultArgs: ['--mute-audio']), '/p');
      expect(args, isNot(contains('--mute-audio')));
      expect(args, contains('--headless'));
    });

    test('matches a default written as --flag=value', () {
      final args = chromium.defaultArgs(
          const CoreLaunchOptions(ignoreDefaultArgs: ['--force-color-profile']),
          '/p');
      expect(args.where((a) => a.startsWith('--force-color-profile')), isEmpty);
    });

    test(
        'ignoreAllDefaultArgs keeps only what the caller passed, plus what '
        'the connection itself needs', () {
      final args = chromium.defaultArgs(
          const CoreLaunchOptions(ignoreAllDefaultArgs: true, args: ['--mine']),
          '/p');
      expect(args, contains('--mine'));
      expect(args, isNot(contains('--disable-breakpad')));
      // Without these there is no profile and no protocol connection at all,
      // so they are not the caller's to drop.
      expect(args, contains('--user-data-dir=/p'));
      expect(args, contains('--remote-debugging-pipe'));
    });
  });

  group('arguments the launcher owns are refused, not silently overridden', () {
    test('[chromium] --user-data-dir', () {
      expect(
          () => chromium.defaultArgs(
              const CoreLaunchOptions(args: ['--user-data-dir=/x']), '/p'),
          throwsA(isA<ArgumentError>()));
    });

    test('[chromium] --remote-debugging-port', () {
      expect(
          () => chromium.defaultArgs(
              const CoreLaunchOptions(args: ['--remote-debugging-port=9222']),
              '/p'),
          throwsA(isA<ArgumentError>()));
    });

    test('[firefox] -profile', () {
      expect(
          () => firefox.defaultArgs(
              const CoreLaunchOptions(args: ['-profile']), '/p'),
          throwsA(isA<ArgumentError>()));
    });

    test('[webkit] --user-data-dir', () {
      expect(
          () => webkit.defaultArgs(
              const CoreLaunchOptions(args: ['--user-data-dir=/x']), '/p'),
          throwsA(isA<ArgumentError>()));
    });
  });

  // An option one engine has and the others do not is rejected rather than
  // ignored: an option that silently does nothing is how a test ends up
  // passing for the wrong reason.
  group('engine-specific options are refused elsewhere', () {
    test('channel is Chromium only', () {
      const options = CoreLaunchOptions(channel: 'chrome');
      expect(() => options.validateFor('chromium'), returnsNormally);
      expect(
          () => options.validateFor('firefox'), throwsA(isA<ArgumentError>()));
      expect(
          () => options.validateFor('webkit'), throwsA(isA<ArgumentError>()));
    });

    test('chromiumSandbox is Chromium only', () {
      const options = CoreLaunchOptions(chromiumSandbox: true);
      expect(() => options.validateFor('chromium'), returnsNormally);
      expect(
          () => options.validateFor('firefox'), throwsA(isA<ArgumentError>()));
    });

    test('firefoxUserPrefs is Firefox only', () {
      const options = CoreLaunchOptions(firefoxUserPrefs: {'a': 1});
      expect(() => options.validateFor('firefox'), returnsNormally);
      expect(
          () => options.validateFor('chromium'), throwsA(isA<ArgumentError>()));
    });

    test('userDataDir must be absolute', () {
      expect(
          () => const CoreLaunchOptions(userDataDir: 'relative/profile')
              .validateFor('chromium'),
          throwsA(isA<ArgumentError>()));
    });
  });

  group('proxy settings', () {
    test('a bare host:port is read as http', () {
      expect(
          const CoreProxySettings(server: '127.0.0.1:8080').normalized().server,
          'http://127.0.0.1:8080');
    });

    test('a scheme no engine speaks is refused', () {
      expect(
          () => const CoreProxySettings(server: 'ftp://host:21').normalized(),
          throwsA(isA<ArgumentError>()));
    });

    test('[chromium] the proxy reaches the command line', () {
      final args = chromium.defaultArgs(
          const CoreLaunchOptions(
              proxy: CoreProxySettings(
                  server: 'http://127.0.0.1:8080', bypass: '.example.com')),
          '/p');
      expect(args, contains('--proxy-server=http://127.0.0.1:8080'));
      // `<-loopback>` first: Chromium exempts loopback from every proxy
      // unless told otherwise, which would skip a local proxy silently.
      expect(args, contains('--proxy-bypass-list=<-loopback>;*.example.com'));
    });

    test('[chromium] a socks5 proxy also blocks the DNS leak', () {
      final args = chromium.defaultArgs(
          const CoreLaunchOptions(
              proxy: CoreProxySettings(server: 'socks5://127.0.0.1:1080')),
          '/p');
      expect(args.any((a) => a.startsWith('--host-resolver-rules=')), isTrue);
    });

    test('[webkit] the proxy reaches the command line', () {
      final args = webkit.defaultArgs(
          const CoreLaunchOptions(
              proxy: CoreProxySettings(server: 'http://127.0.0.1:8080')),
          '/p');
      expect(args.any((a) => a.contains('127.0.0.1:8080')), isTrue);
    });

    test('[firefox] Juggler takes the proxy apart instead of as a URL', () {
      final options = FfBrowser.jugglerProxyOptions(const CoreProxySettings(
              server: 'socks5://127.0.0.1:1080', bypass: 'a.com, b.com')
          .normalized());
      expect(options['type'], 'socks');
      expect(options['host'], '127.0.0.1');
      expect(options['port'], 1080);
      expect(options['bypass'], ['a.com', 'b.com']);
    });
  });
}
