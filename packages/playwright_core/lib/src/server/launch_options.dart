import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:playwright_protocol/playwright_protocol.dart';

import '../registry/browser_channels.dart';
import 'core_browser.dart';

/// Proxy settings, used both at launch (one proxy for the whole browser) and
/// per context (`newContext(proxy: ...)`).
///
/// [server] is `scheme://host:port`; `http`, `https` and `socks5` are the
/// schemes the engines understand. [bypass] is a comma-separated list of
/// hosts that skip the proxy. [username]/[password] answer a proxy auth
/// challenge.
class CoreProxySettings {
  final String server;
  final String? bypass;
  final String? username;
  final String? password;

  const CoreProxySettings({
    required this.server,
    this.bypass,
    this.username,
    this.password,
  });

  /// Normalizes a bare `host:port` into a URL, as upstream's
  /// `normalizeProxySettings` does, and rejects what no engine can use.
  CoreProxySettings normalized() {
    var url = server.trim();
    if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(url)) {
      url = 'http://$url';
    }
    final parsed = Uri.tryParse(url);
    if (parsed == null || parsed.host.isEmpty) {
      throw ArgumentError.value(server, 'proxy.server', 'Invalid proxy URL');
    }
    const known = {'http', 'https', 'socks5'};
    if (!known.contains(parsed.scheme)) {
      throw ArgumentError.value(
          server,
          'proxy.server',
          'Unsupported proxy scheme "${parsed.scheme}". Use one of: '
              '${known.join(', ')}');
    }
    return CoreProxySettings(
      server: parsed.port == 0
          ? '${parsed.scheme}://${parsed.host}'
          : '${parsed.scheme}://${parsed.host}:${parsed.port}',
      bypass: bypass,
      username: username,
      password: password,
    );
  }
}

/// Everything the three engine launchers take, in one place.
///
/// The options that only one engine honours are named for it ([channel] and
/// [chromiumSandbox] for Chromium, [firefoxUserPrefs] for Firefox) and the
/// launchers reject them elsewhere rather than ignoring them: an option that
/// silently does nothing is how a test passes for the wrong reason.
class CoreLaunchOptions {
  final bool headless;

  /// A branded Chromium build — `chrome`, `msedge`, `chrome-beta`, … — instead
  /// of the bundled one. Chromium only.
  final String? channel;

  /// An explicit browser binary, bypassing the registry.
  final String? executablePath;

  /// Extra command-line arguments for the browser.
  final List<String> args;

  /// Default arguments to drop. `true` in [ignoreAllDefaultArgs] drops all of
  /// them, which is upstream's `ignoreDefaultArgs: true`.
  final List<String> ignoreDefaultArgs;
  final bool ignoreAllDefaultArgs;

  /// Environment for the browser process. Null inherits this process's.
  final Map<String, String>? env;

  /// Where downloads are written. Null means a temporary directory removed
  /// when the browser closes.
  final String? downloadsPath;

  /// Where trace artifacts are written.
  final String? tracesDir;

  /// How long to wait for the browser to start and hand us a usable
  /// connection. `Duration.zero` disables the timeout.
  final Duration timeout;

  /// Slows every protocol operation down by this much, to watch what happens.
  final Duration? slowMo;

  /// Keeps Chromium's sandbox on. Off by default, as upstream.
  final bool chromiumSandbox;

  /// `about:config` preferences written into the Firefox profile.
  final Map<String, dynamic>? firefoxUserPrefs;

  /// One proxy for every context of this browser.
  final CoreProxySettings? proxy;

  /// Which interruptions of the Dart process take the browser down with it.
  final bool handleSIGINT;
  final bool handleSIGTERM;
  final bool handleSIGHUP;

  /// The on-disk profile for `launchPersistentContext`. Null launches with a
  /// throwaway profile.
  final String? userDataDir;

  /// Context options for the profile's own context. Only meaningful with
  /// [userDataDir] set: that context exists from the moment the browser
  /// starts, so its options are applied during startup rather than by a
  /// later `newContext`.
  final CoreContextOptions persistentContextOptions;

  const CoreLaunchOptions({
    this.headless = true,
    this.channel,
    this.executablePath,
    this.args = const [],
    this.ignoreDefaultArgs = const [],
    this.ignoreAllDefaultArgs = false,
    this.env,
    this.downloadsPath,
    this.tracesDir,
    this.timeout = const Duration(seconds: 30),
    this.slowMo,
    this.chromiumSandbox = false,
    this.firefoxUserPrefs,
    this.proxy,
    this.handleSIGINT = true,
    this.handleSIGTERM = true,
    this.handleSIGHUP = true,
    this.userDataDir,
    this.persistentContextOptions = const CoreContextOptions(),
  });

  /// Whether this is a `launchPersistentContext`.
  bool get isPersistent => userDataDir != null;

  /// The environment handed to the browser process.
  Map<String, String>? get processEnvironment => env;

  /// Applies [ignoreDefaultArgs]/[ignoreAllDefaultArgs] to [defaults] and
  /// appends the user's [args], which is the order upstream uses.
  List<String> assembleArgs(List<String> defaults) {
    final assembled = <String>[];
    if (!ignoreAllDefaultArgs) {
      assembled.addAll(
        ignoreDefaultArgs.isEmpty
            ? defaults
            : defaults.where((a) => !_isIgnored(a)),
      );
    }
    assembled.addAll(args);
    return assembled;
  }

  /// Matches `--flag` against `--flag=value` too, which is what a caller
  /// passing `ignoreDefaultArgs: ['--mute-audio']` expects.
  bool _isIgnored(String arg) {
    for (final ignored in ignoreDefaultArgs) {
      if (arg == ignored) return true;
      if (arg.startsWith('$ignored=')) return true;
    }
    return false;
  }

  /// Rejects the options this engine cannot honour.
  void validateFor(String browserName) {
    if (channel != null && browserName != 'chromium') {
      throw ArgumentError.value(channel, 'channel',
          'channel selects a branded Chromium build; $browserName has none');
    }
    if (chromiumSandbox && browserName != 'chromium') {
      throw ArgumentError.value(
          chromiumSandbox,
          'chromiumSandbox',
          'chromiumSandbox is a Chromium option; $browserName has no such '
              'sandbox to configure');
    }
    if (firefoxUserPrefs != null && browserName != 'firefox') {
      throw ArgumentError.value(
          firefoxUserPrefs,
          'firefoxUserPrefs',
          'firefoxUserPrefs writes Firefox about:config preferences; '
              '$browserName has none');
    }
    if (userDataDir != null && !p.isAbsolute(userDataDir!)) {
      throw ArgumentError.value(
          userDataDir, 'userDataDir', 'userDataDir must be an absolute path');
    }
  }

  /// Creates [userDataDir] if needed and returns the profile directory to
  /// launch with, plus the temporary directories the browser owns.
  ///
  /// Firefox refuses to start on a profile directory that does not exist and
  /// Chromium creates one; upstream levels that difference here, and so do we.
  ({String dir, List<String> temporary}) resolveUserDataDir(
      String browserName) {
    final explicit = userDataDir;
    if (explicit != null) {
      final directory = Directory(explicit);
      if (!directory.existsSync()) directory.createSync(recursive: true);
      return (dir: explicit, temporary: const []);
    }
    final temp = Directory.systemTemp
        .createTempSync('playwright_${browserName}dev_profile-');
    return (dir: temp.path, temporary: [temp.path]);
  }

  /// Resolves the executable, honouring [executablePath] and [channel].
  String resolveExecutable(
      String browserName, String? Function(String) fromRegistry) {
    final explicit = executablePath;
    if (explicit != null) {
      if (!File(explicit).existsSync()) {
        throw PlaywrightException(
            'executablePath "$explicit" does not point at a file.');
      }
      return explicit;
    }
    final wanted = channel;
    if (wanted != null) {
      if (!BrowserChannels.isKnown(wanted)) {
        throw PlaywrightException(
            'Unknown Chromium channel "$wanted". Known channels: '
            '${BrowserChannels.known.join(', ')}.');
      }
      final found = BrowserChannels.find(wanted);
      if (found == null) {
        throw PlaywrightException(
            'Chromium channel "$wanted" is not installed on this machine. '
            'Install it, or pass executablePath.');
      }
      return found;
    }
    final path = fromRegistry(browserName);
    if (path == null || !File(path).existsSync()) {
      throw PlaywrightException(
          '$browserName executable not found. Run `playwright install '
          '$browserName`.');
    }
    return path;
  }
}
