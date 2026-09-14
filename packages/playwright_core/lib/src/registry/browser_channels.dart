import 'dart:io';

/// Branded Chromium builds installed by the operating system rather than
/// downloaded by Playwright: `chrome`, `msedge` and their pre-release rings.
///
/// These are never fetched — `launch(channel: 'chrome')` uses the Chrome the
/// machine already has, which is the point of the option: testing against the
/// shipping browser instead of the Chromium snapshot pinned by this package.
/// Only Chromium has them; Firefox and WebKit ship a single build each.
class BrowserChannels {
  BrowserChannels._();

  /// Channel names this port knows, for error messages.
  static List<String> get known => _windows.keys.toList();

  static const _windows = <String, List<String>>{
    'chrome': [
      r'%ProgramFiles%\Google\Chrome\Application\chrome.exe',
      r'%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe',
      r'%LocalAppData%\Google\Chrome\Application\chrome.exe',
    ],
    'chrome-beta': [
      r'%ProgramFiles%\Google\Chrome Beta\Application\chrome.exe',
      r'%ProgramFiles(x86)%\Google\Chrome Beta\Application\chrome.exe',
    ],
    'chrome-dev': [
      r'%ProgramFiles%\Google\Chrome Dev\Application\chrome.exe',
      r'%ProgramFiles(x86)%\Google\Chrome Dev\Application\chrome.exe',
    ],
    'chrome-canary': [
      r'%LocalAppData%\Google\Chrome SxS\Application\chrome.exe',
    ],
    'msedge': [
      r'%ProgramFiles%\Microsoft\Edge\Application\msedge.exe',
      r'%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe',
    ],
    'msedge-beta': [
      r'%ProgramFiles%\Microsoft\Edge Beta\Application\msedge.exe',
      r'%ProgramFiles(x86)%\Microsoft\Edge Beta\Application\msedge.exe',
    ],
    'msedge-dev': [
      r'%ProgramFiles%\Microsoft\Edge Dev\Application\msedge.exe',
      r'%ProgramFiles(x86)%\Microsoft\Edge Dev\Application\msedge.exe',
    ],
    'msedge-canary': [
      r'%LocalAppData%\Microsoft\Edge SxS\Application\msedge.exe',
    ],
  };

  static const _macOS = <String, List<String>>{
    'chrome': [
      '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    ],
    'chrome-beta': [
      '/Applications/Google Chrome Beta.app/Contents/MacOS/Google Chrome Beta',
    ],
    'chrome-dev': [
      '/Applications/Google Chrome Dev.app/Contents/MacOS/Google Chrome Dev',
    ],
    'chrome-canary': [
      '/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary',
    ],
    'msedge': [
      '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
    ],
    'msedge-beta': [
      '/Applications/Microsoft Edge Beta.app/Contents/MacOS/Microsoft Edge Beta',
    ],
    'msedge-dev': [
      '/Applications/Microsoft Edge Dev.app/Contents/MacOS/Microsoft Edge Dev',
    ],
    'msedge-canary': [
      '/Applications/Microsoft Edge Canary.app/Contents/MacOS/Microsoft Edge Canary',
    ],
  };

  static const _linux = <String, List<String>>{
    'chrome': ['/opt/google/chrome/chrome'],
    'chrome-beta': ['/opt/google/chrome-beta/chrome'],
    'chrome-dev': ['/opt/google/chrome-unstable/chrome'],
    'chrome-canary': <String>[],
    'msedge': ['/opt/microsoft/msedge/msedge'],
    'msedge-beta': ['/opt/microsoft/msedge-beta/msedge'],
    'msedge-dev': ['/opt/microsoft/msedge-dev/msedge'],
    'msedge-canary': <String>[],
  };

  /// Whether [channel] is a name this port knows at all, regardless of
  /// whether it is installed here.
  static bool isKnown(String channel) => _windows.containsKey(channel);

  /// The executable for [channel] on this machine, or null if that build is
  /// not installed (or the channel does not exist on this OS).
  static String? find(String channel) {
    final table = Platform.isWindows
        ? _windows
        : Platform.isMacOS
            ? _macOS
            : _linux;
    for (final candidate in table[channel] ?? const <String>[]) {
      final resolved = _expand(candidate);
      if (resolved != null && File(resolved).existsSync()) return resolved;
    }
    return null;
  }

  /// Expands `%VAR%` placeholders; returns null when the variable is unset,
  /// which is how a 32-bit-only path is skipped on a 64-bit-only machine.
  static String? _expand(String path) {
    final pattern = RegExp(r'%([^%]+)%');
    var missing = false;
    final expanded = path.replaceAllMapped(pattern, (match) {
      final value = Platform.environment[match.group(1)!];
      if (value == null) missing = true;
      return value ?? '';
    });
    return missing ? null : expanded;
  }
}
