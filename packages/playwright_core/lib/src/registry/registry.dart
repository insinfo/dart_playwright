import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:playwright_protocol/playwright_protocol.dart';

import 'browser_descriptor.dart';
import 'browser_fetcher.dart';
import 'browsers_json.dart';
import 'host_platform.dart';

/// Central registry for managing browser binaries.
/// Handles resolution, caching, and downloading of official Playwright browsers.
class BrowserRegistry {
  late final String _cacheDir;
  late final List<BrowserDescriptor> _browsers;

  /// CDN mirrors for downloading binaries.
  static const cdnMirrors = [
    'https://cdn.playwright.dev/dbazure/download/playwright',
    'https://playwright.download.prss.microsoft.com/dbazure/download/playwright',
    'https://cdn.playwright.dev',
  ];

  BrowserRegistry() {
    _cacheDir = _resolveCacheDir();
    _browsers = _loadBrowsersJson();
  }

  List<BrowserDescriptor> get browsers => _browsers;

  String _resolveCacheDir() {
    final envPath = Platform.environment['PLAYWRIGHT_BROWSERS_PATH'];
    if (envPath != null && envPath.isNotEmpty) return envPath;

    if (Platform.isWindows) {
      final appData = Platform.environment['LOCALAPPDATA'] ??
          path.join(Platform.environment['USERPROFILE']!, 'AppData', 'Local');
      return path.join(appData, 'ms-playwright');
    } else if (Platform.isMacOS) {
      return path.join(
          Platform.environment['HOME']!, 'Library', 'Caches', 'ms-playwright');
    } else {
      final xdgCache = Platform.environment['XDG_CACHE_HOME'] ??
          path.join(Platform.environment['HOME']!, '.cache');
      return path.join(xdgCache, 'ms-playwright');
    }
  }

  List<BrowserDescriptor> _loadBrowsersJson() {
    final json = jsonDecode(browsersJsonString) as Map<String, dynamic>;
    final browsersList = json['browsers'] as List<dynamic>;
    return browsersList
        .map((b) => BrowserDescriptor.fromJson(b as Map<String, dynamic>))
        .toList();
  }

  BrowserDescriptor? getDescriptor(String name) {
    for (final b in _browsers) {
      if (b.name == name) return b;
    }
    return null;
  }

  /// Check if a browser is installed.
  bool isInstalled(String browserName) {
    final execPath = executablePath(browserName);
    return execPath != null && File(execPath).existsSync();
  }

  /// Get the executable path for a browser.
  String? executablePath(String browserName) {
    final descriptor = getDescriptor(browserName);
    if (descriptor == null) return null;

    final platform = HostPlatform.detect();
    final pathSegments = _executablePaths[browserName]?[platform];
    if (pathSegments == null) return null;

    final browserDir =
        _browserDirectory(browserName, descriptor.effectiveRevision(platform));
    return path.joinAll([browserDir, ...pathSegments]);
  }

  String _browserDirectory(String browserName, String revision) {
    return path.join(_cacheDir, '$browserName-$revision');
  }

  /// Install a specific browser.
  Future<void> install(String browserName,
      {void Function(double progress)? onProgress}) async {
    final descriptor = getDescriptor(browserName);
    if (descriptor == null) {
      throw PlaywrightException('Unknown browser: $browserName');
    }

    if (isInstalled(browserName)) {
      return; // Already installed
    }

    final platform = HostPlatform.detect();
    final revision = descriptor.effectiveRevision(platform);
    final downloadPath = _downloadPaths[browserName]?[platform];

    String? downloadUrl;
    if (downloadPath != null) {
      downloadUrl = downloadPath.replaceFirst('%s', revision);
    } else if (browserName == 'chromium') {
      // Chromium uses Chrome for Testing (CFT) URLs
      final suffix = _cftSuffixes[platform];
      if (suffix != null && descriptor.browserVersion != null) {
        downloadUrl = 'builds/cft/${descriptor.browserVersion}/$suffix';
      }
    }

    if (downloadUrl == null) {
      throw PlaywrightException('$browserName is not available for $platform');
    }

    final browserDir = _browserDirectory(browserName, revision);

    await BrowserFetcher.downloadAndExtract(
      url: downloadUrl,
      destinationDir: browserDir,
      onProgress: onProgress,
    );

    // Make binaries executable on Unix systems
    if (!Platform.isWindows) {
      final execPath = executablePath(browserName);
      if (execPath != null) {
        await Process.run('chmod', ['+x', execPath]);
      }
    }
  }

  /// Install all default browsers.
  Future<void> installAll(
      {void Function(String browser, double progress)? onProgress}) async {
    for (final browser in _browsers) {
      if (browser.installByDefault) {
        await install(browser.name, onProgress: (p) {
          onProgress?.call(browser.name, p);
        });
      }
    }
  }
}

// === Path Mappings (Extracted from TS official implementation) ===

const _executablePaths = <String, Map<String, List<String>?>>{
  'chromium': {
    'win-x64': ['chrome-win64', 'chrome.exe'],
    'mac-x64': ['chrome-mac-x64', 'Google Chrome for Testing.app', 'Contents', 'MacOS', 'Google Chrome for Testing'],
    'mac-arm64': ['chrome-mac-arm64', 'Google Chrome for Testing.app', 'Contents', 'MacOS', 'Google Chrome for Testing'],
    'linux-x64': ['chrome-linux64', 'chrome'],
    'linux-arm64': ['chrome-linux', 'chrome'],
  },
  'firefox': {
    'win-x64': ['firefox', 'firefox.exe'],
    'mac-x64': ['firefox', 'Nightly.app', 'Contents', 'MacOS', 'firefox'],
    'mac-arm64': ['firefox', 'Nightly.app', 'Contents', 'MacOS', 'firefox'],
    'linux-x64': ['firefox', 'firefox'],
    'linux-arm64': ['firefox', 'firefox'],
  },
  'webkit': {
    'win-x64': ['Playwright.exe'],
    'mac-x64': ['pw_run.sh'],
    'mac-arm64': ['pw_run.sh'],
    'linux-x64': ['pw_run.sh'],
    'linux-arm64': ['pw_run.sh'],
  },
  'ffmpeg': {
    'win-x64': ['ffmpeg-win64.exe'],
    'mac-x64': ['ffmpeg-mac'],
    'mac-arm64': ['ffmpeg-mac'],
    'linux-x64': ['ffmpeg-linux'],
    'linux-arm64': ['ffmpeg-linux'],
  },
};

const _downloadPaths = <String, Map<String, String?>>{
  'chromium': {
    'linux-arm64': 'builds/chromium/%s/chromium-linux-arm64.zip',
  },
  'firefox': {
    'win-x64': 'builds/firefox/%s/firefox-win64.zip',
    'mac-x64': 'builds/firefox/%s/firefox-mac.zip',
    'mac-arm64': 'builds/firefox/%s/firefox-mac-arm64.zip',
    'linux-x64': 'builds/firefox/%s/firefox-ubuntu-22.04.zip',
    'linux-arm64': 'builds/firefox/%s/firefox-ubuntu-22.04-arm64.zip',
  },
  'webkit': {
    'win-x64': 'builds/webkit/%s/webkit-win64.zip',
    'mac-x64': 'builds/webkit/%s/webkit-mac-15.zip',
    'mac-arm64': 'builds/webkit/%s/webkit-mac-15-arm64.zip',
    'linux-x64': 'builds/webkit/%s/webkit-ubuntu-22.04.zip',
    'linux-arm64': 'builds/webkit/%s/webkit-ubuntu-22.04-arm64.zip',
  },
};

const _cftSuffixes = {
  'win-x64': 'win64/chrome-win64.zip',
  'mac-x64': 'mac-x64/chrome-mac-x64.zip',
  'mac-arm64': 'mac-arm64/chrome-mac-arm64.zip',
  'linux-x64': 'linux64/chrome-linux64.zip',
};
