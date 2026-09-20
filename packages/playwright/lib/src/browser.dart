import 'package:playwright_core/src/server/core_browser.dart';
import 'package:playwright_core/src/server/launch_options.dart';
import 'browser_context.dart';
import 'browser_type.dart' show ProxySettings;
import 'har.dart';
import 'video.dart';

/// A browser instance.
abstract class Browser {
  /// Create a new browser context.
  ///
  /// [viewport] sets the page viewport size and [userAgent] overrides the
  /// browser user agent for every page in the context.
  ///
  /// [acceptDownloads] decides whether downloads are written to disk at all;
  /// with it off the engines refuse them. [downloadsPath] is where they land,
  /// defaulting to a temporary directory removed when the browser closes.
  ///
  /// [locale] is a BCP 47 tag driving `navigator.language`, `Accept-Language`
  /// and locale-dependent formatting. [timezoneId] is an IANA zone; an
  /// unknown one is rejected with `Invalid timezone ID`.
  ///
  /// [colorScheme] (`light`, `dark`, `no-preference`), [reducedMotion]
  /// (`reduce`, `no-preference`) and [forcedColors] (`active`, `none`) drive
  /// the matching media queries.
  ///
  /// [deviceScaleFactor], [isMobile] and [hasTouch] emulate a device;
  /// [isMobile] needs a [viewport], and [hasTouch] is what makes
  /// [Page.tap] land — without it the engines discard the touch event. The
  /// `devices` map has ready-made combinations.
  ///
  /// [offline] cuts the pages off the network. [extraHTTPHeaders] are added
  /// to every request. [httpCredentials] answers HTTP basic auth challenges.
  ///
  /// [proxy] routes this context alone, overriding any proxy the browser was
  /// launched with. All three engines take one per context.
  ///
  /// [recordVideo] films every page of the context into a directory. The file
  /// of a page is only complete once that page closes, so read it through
  /// [Page.video]; see [RecordVideoOptions].
  ///
  /// [recordHar] records every request of the context into a HAR document,
  /// written when the context closes; see [RecordHarOptions].
  ///
  /// [geolocation] sets what `navigator.geolocation` reports; it also needs
  /// `geolocation` in [permissions]. The permission names each engine knows
  /// differ a lot — Chromium seventeen, WebKit six, Firefox five — and asking
  /// for one an engine does not have throws rather than passing silently.
  Future<BrowserContext> newContext({
    ({int width, int height})? viewport,
    String? userAgent,
    bool acceptDownloads,
    String? downloadsPath,
    String? locale,
    String? timezoneId,
    String? colorScheme,
    String? reducedMotion,
    String? forcedColors,
    double? deviceScaleFactor,
    bool isMobile,
    bool hasTouch,
    bool offline,
    Map<String, String>? extraHTTPHeaders,
    ({String username, String password, String? origin})? httpCredentials,
    ({double latitude, double longitude, double accuracy})? geolocation,
    List<String>? permissions,
    ProxySettings? proxy,
    RecordVideoOptions? recordVideo,
    RecordHarOptions? recordHar,
  });

  /// Currently open browser contexts.
  List<BrowserContext> contexts();

  /// Whether the browser connection is still open.
  bool isConnected();

  /// Event emitted when the browser disconnects.
  Stream<void> get onDisconnected;

  /// Close the browser.
  Future<void> close();

  /// Browser version.
  Future<String> version();
}

class BrowserImpl implements Browser {
  final CoreBrowser _coreBrowser;

  BrowserImpl(this._coreBrowser);

  @override
  Future<BrowserContext> newContext({
    ({int width, int height})? viewport,
    String? userAgent,
    bool acceptDownloads = true,
    String? downloadsPath,
    String? locale,
    String? timezoneId,
    String? colorScheme,
    String? reducedMotion,
    String? forcedColors,
    double? deviceScaleFactor,
    bool isMobile = false,
    bool hasTouch = false,
    bool offline = false,
    Map<String, String>? extraHTTPHeaders,
    ({String username, String password, String? origin})? httpCredentials,
    ({double latitude, double longitude, double accuracy})? geolocation,
    List<String>? permissions,
    ProxySettings? proxy,
    RecordVideoOptions? recordVideo,
    RecordHarOptions? recordHar,
  }) async {
    if (isMobile && viewport == null) {
      throw ArgumentError('isMobile needs a viewport');
    }
    final coreContext = await _coreBrowser.createBrowserContext(
        options: CoreContextOptions(
      viewport: viewport,
      userAgent: userAgent,
      acceptDownloads: acceptDownloads,
      downloadsPath: downloadsPath,
      locale: locale,
      timezoneId: timezoneId,
      colorScheme: colorScheme,
      reducedMotion: reducedMotion,
      forcedColors: forcedColors,
      deviceScaleFactor: deviceScaleFactor,
      isMobile: isMobile,
      hasTouch: hasTouch,
      offline: offline,
      extraHTTPHeaders: extraHTTPHeaders,
      httpCredentials: httpCredentials,
      geolocation: geolocation,
      permissions: permissions,
      proxy: proxy == null
          ? null
          : CoreProxySettings(
              server: proxy.server,
              bypass: proxy.bypass,
              username: proxy.username,
              password: proxy.password,
            ),
      recordVideo: recordVideo?.toCore(),
      recordHar: recordHar?.toCore(),
    ));
    return BrowserContextImpl.forCore(coreContext);
  }

  @override
  List<BrowserContext> contexts() =>
      _coreBrowser.contexts.map(BrowserContextImpl.forCore).toList();

  @override
  bool isConnected() => _coreBrowser.isConnected;

  @override
  Stream<void> get onDisconnected => _coreBrowser.stream<void>('disconnected');

  @override
  Future<void> close() => _coreBrowser.close();

  @override
  Future<String> version() => _coreBrowser.version();
}
