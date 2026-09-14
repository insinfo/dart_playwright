import 'dart:async';
import 'package:playwright_protocol/playwright_protocol.dart';
import 'core_clock.dart';
import 'core_page.dart';
import 'launch_options.dart';

/// Options applied to every page of a browser context.
/// Latitude, longitude and accuracy in metres.
typedef CoreGeolocation = ({double latitude, double longitude, double accuracy});

/// Basic-auth credentials, optionally scoped to one origin.
typedef CoreHttpCredentials = ({String username, String password, String? origin});

class CoreContextOptions {
  final ({int width, int height})? viewport;
  final String? userAgent;

  /// Whether downloads are written to disk. With this off the engines refuse
  /// them outright, which is upstream's `acceptDownloads: false`.
  final bool acceptDownloads;

  /// Where downloads land. Null means a temporary directory created for the
  /// browser, which is deleted when it closes.
  final String? downloadsPath;

  /// BCP 47 language tag, e.g. `pt-BR`. Drives `navigator.language`, the
  /// `Accept-Language` header and locale-dependent formatting.
  final String? locale;

  /// IANA time zone, e.g. `America/Sao_Paulo`. An unknown one is rejected by
  /// every engine, and the drivers surface that as a clear error.
  final String? timezoneId;

  /// `light`, `dark` or `no-preference`. Null leaves the engine's own.
  final String? colorScheme;

  /// `reduce` or `no-preference`.
  final String? reducedMotion;

  /// `active` or `none`.
  final String? forcedColors;

  /// Device pixel ratio for the pages of this context.
  final double? deviceScaleFactor;

  /// Emulates a mobile device: viewport meta tag handling and orientation.
  /// Requires a viewport.
  final bool isMobile;

  /// Emulates touch support, which is what makes `tap` land.
  final bool hasTouch;

  /// Cuts the pages off the network.
  final bool offline;

  /// Headers added to every request of this context.
  final Map<String, String>? extraHTTPHeaders;

  /// Credentials for HTTP basic auth challenges.
  final CoreHttpCredentials? httpCredentials;

  /// The position `navigator.geolocation` reports. Needs the `geolocation`
  /// permission to be granted as well.
  final CoreGeolocation? geolocation;

  /// Permissions granted to every origin of this context.
  final List<String>? permissions;

  /// A proxy for this context alone, overriding the browser's own. All three
  /// engines take one per context, so this is not a Chromium special case.
  final CoreProxySettings? proxy;

  const CoreContextOptions({
    this.viewport,
    this.userAgent,
    this.acceptDownloads = true,
    this.downloadsPath,
    this.locale,
    this.timezoneId,
    this.colorScheme,
    this.reducedMotion,
    this.forcedColors,
    this.deviceScaleFactor,
    this.isMobile = false,
    this.hasTouch = false,
    this.offline = false,
    this.extraHTTPHeaders,
    this.httpCredentials,
    this.geolocation,
    this.permissions,
    this.proxy,
  });

  /// Whether anything here needs emulation applied at all.
  bool get hasEmulation =>
      viewport != null ||
      userAgent != null ||
      locale != null ||
      timezoneId != null ||
      colorScheme != null ||
      reducedMotion != null ||
      forcedColors != null ||
      deviceScaleFactor != null ||
      isMobile ||
      hasTouch ||
      offline ||
      extraHTTPHeaders != null ||
      httpCredentials != null ||
      geolocation != null;
}

/// Maps Playwright's permission names onto what each engine calls them.
///
/// The three tables are very different sizes, and that is the engines'
/// doing, not an omission here: Chromium knows eighteen, WebKit six and
/// Firefox five. Asking for one an engine does not have throws, which is what
/// upstream does too — silently ignoring it would leave a test passing for
/// the wrong reason.
class CorePermissions {
  /// Chromium `Browser.grantPermissions`. One name can expand to several.
  static const chromium = <String, List<String>>{
    'geolocation': ['geolocation'],
    'midi': ['midi'],
    'midi-sysex': ['midiSysex'],
    'notifications': ['notifications'],
    'camera': ['videoCapture'],
    'microphone': ['audioCapture'],
    'background-sync': ['backgroundSync'],
    'ambient-light-sensor': ['sensors'],
    'accelerometer': ['sensors'],
    'gyroscope': ['sensors'],
    'magnetometer': ['sensors'],
    'clipboard-read': ['clipboardReadWrite'],
    'clipboard-write': ['clipboardSanitizedWrite'],
    'payment-handler': ['paymentHandler'],
    'storage-access': ['storageAccess'],
    'local-fonts': ['localFonts'],
    'screen-wake-lock': ['wakeLockScreen'],
  };

  /// Firefox `Browser.grantPermissions`. Juggler exposes only these five.
  static const firefox = <String, List<String>>{
    'geolocation': ['geo'],
    'persistent-storage': ['persistent-storage'],
    'push': ['push'],
    'notifications': ['desktop-notification'],
    'screen-wake-lock': ['screen-wake-lock'],
  };

  /// WebKit `Emulation.grantPermissions`, which is a pageProxy command.
  static const webkit = <String, List<String>>{
    'geolocation': ['geolocation'],
    'notifications': ['notifications'],
    'clipboard-read': ['clipboard-read'],
    'screen-wake-lock': ['screen-wake-lock'],
    'camera': ['camera'],
    'microphone': ['microphone'],
  };

  /// Translates [permissions] for [table], throwing on a name the engine
  /// does not know.
  static List<String> resolve(
      Map<String, List<String>> table, List<String> permissions) {
    final resolved = <String>[];
    for (final permission in permissions) {
      final mapped = table[permission];
      if (mapped == null) {
        throw ArgumentError.value(permission, 'permission',
            'This engine does not support that permission. It knows: '
                '${table.keys.join(', ')}');
      }
      resolved.addAll(mapped);
    }
    return resolved;
  }
}

/// Base interface for internal browser implementations.
abstract class CoreBrowser extends EventEmitter {
  /// Exposes the underlying connection for CDP/Juggler/WebKit operations.
  dynamic get connection;

  /// Returns the browser version.
  Future<String> version();

  /// Currently open browser contexts.
  List<CoreBrowserContext> get contexts;

  /// Whether the browser connection is still open.
  bool get isConnected;

  /// Creates an isolated browser context (cookies/storage separated).
  Future<CoreBrowserContext> createBrowserContext(
      {CoreContextOptions options = const CoreContextOptions()});

  /// Closes the browser.
  Future<void> close();
}

/// An isolated browser context owned by a [CoreBrowser].
///
/// Emits, mirroring upstream's `BrowserContext` events:
/// `page` ([CorePage]), `close`, `console` ([CoreConsoleMessage]),
/// `pageerror` ([CorePageError]), `dialog` ([Dialog]), and the network
/// events `request`/`response`/`requestFinished`/`requestFailed`.
abstract class CoreBrowserContext extends EventEmitter {
  /// Pages opened in this context.
  List<CorePage> get pages;

  /// Whether this context has been closed.
  bool get isClosed;

  /// Creates a new page inside this context.
  Future<CorePage> newPage();

  /// Returns all cookies in this context (optionally filtered by [urls]).
  Future<List<Map<String, dynamic>>> cookies([List<String>? urls]);

  /// Adds the given cookies to this context.
  Future<void> addCookies(List<Map<String, dynamic>> cookies);

  /// Removes all cookies from this context.
  Future<void> clearCookies();

  /// Captures cookies and per-origin localStorage as a portable snapshot:
  /// `{ 'cookies': [...], 'origins': [{ 'origin': ..., 'localStorage': [...] }] }`.
  Future<Map<String, dynamic>> storageState();

  /// Adds [source] to the scripts every new document of every page of this
  /// context runs before any of its own. See
  /// [CoreBrowserContextBindings.addInitScript].
  Future<CoreInitScript> addInitScript(String source);

  /// Exposes [name] as a function on every page of this context. See
  /// [CoreBrowserContextBindings.exposeBinding].
  Future<void> exposeBinding(String name, CoreBindingCallback callback,
      {bool noGlobal});

  /// Functions exposed on this context.
  Map<String, CoreBinding> get contextBindings;

  /// The engine this context belongs to: `chromium`, `firefox` or `webkit`.
  String get engineName;

  /// Deterministic time for every page of this context.
  CoreClock get clock;

  /// Disposes this context and every page that belongs to it.
  Future<void> close();
}

/// Shared cookie/storageState plumbing for the engine contexts.
///
/// Each engine supplies raw cookie access; localStorage is gathered by
/// evaluating in the pages this context has opened.
mixin BrowserContextStorage on EventEmitter {
  /// Pages opened by this context, used to snapshot localStorage per origin.
  final List<CorePage> trackedPages = [];

  List<CorePage> get pages => List.unmodifiable(trackedPages);

  /// Page-level events the context re-emits, exactly the set upstream
  /// forwards from `Page` to `BrowserContext`.
  static const forwardedPageEvents = <String>[
    'console',
    'pageerror',
    'request',
    'response',
    'requestFinished',
    'requestFailed',
  ];

  /// Adopts [page]: records it, forwards its events, and announces it.
  ///
  /// Every page reaches the context through here — the ones created by
  /// [CoreBrowserContext.newPage] and the ones the page itself opened with
  /// `window.open` — so `context.pages` and the `page` event never disagree.
  /// [opener], when given, is the page that opened [page]; it also gets a
  /// `popup` event, which is what `page.waitForPopup` waits on.
  void registerPage(CorePage page, {CorePage? opener}) {
    if (trackedPages.contains(page)) return;
    page.browserContext = this as CoreBrowserContext;
    page.opener = opener;
    trackedPages.add(page);

    for (final event in forwardedPageEvents) {
      page.on(event, (dynamic payload) => emit(event, payload));
    }
    page.once('close', ([dynamic _]) => trackedPages.remove(page));

    // The opener sees the popup first: upstream resolves `waitForPopup`
    // before the context's `page` event listeners run.
    if (opener != null) opener.emit('popup', page);
    emit('page', page);
  }

  /// Downloads in flight or finished, by engine id.
  final downloads = <String, CoreDownload>{};

  /// Announces a download, on the page that started it and on the context.
  ///
  /// A download the engine reports without a page (a `target=_blank` that
  /// turns out to be a file, for instance) still reaches the context, which
  /// is where upstream puts it too.
  void registerDownload(CoreDownload download, {CorePage? page}) {
    downloads[download.uuid] = download;
    page?.emit('download', download);
    emit('download', download);
  }

  /// Announces the context's own closure and releases its streams.
  void notifyClosed() {
    emit('close', true);
    (this as EventEmitter).disposeStreams();
  }

  Future<List<Map<String, dynamic>>> cookies([List<String>? urls]);

  Future<Map<String, dynamic>> collectStorageState() async {
    final cookieList = await cookies();
    final origins = <Map<String, dynamic>>[];
    final seen = <String>{};

    for (final page in trackedPages) {
      try {
        final result = await page.evaluate('''
          () => {
            const origin = window.location.origin;
            if (!origin || origin === 'null') return null;
            const items = [];
            for (let i = 0; i < localStorage.length; i++) {
              const name = localStorage.key(i);
              items.push({ name, value: localStorage.getItem(name) });
            }
            return { origin, localStorage: items };
          }
        ''');
        if (result is Map && result['origin'] != null) {
          final origin = result['origin'] as String;
          if (seen.add(origin) && (result['localStorage'] as List).isNotEmpty) {
            origins.add({
              'origin': origin,
              'localStorage': result['localStorage'],
            });
          }
        }
      } catch (_) {
        // Page may have been closed; skip it.
      }
    }

    return {'cookies': cookieList, 'origins': origins};
  }

  /// Transforms 'url' into 'domain', 'path', and 'secure' fields as required by the engines.
  List<Map<String, dynamic>> rewriteCookies(
      List<Map<String, dynamic>> cookies) {
    return cookies.map((c) {
      final copy = Map<String, dynamic>.from(c);
      if (copy['url'] != null) {
        final uri = Uri.parse(copy['url'] as String);
        copy['domain'] = uri.host;
        copy['path'] = uri.path.substring(0, uri.path.lastIndexOf('/') + 1);
        copy['secure'] = uri.scheme == 'https';
        copy.remove('url');
      }
      return copy;
    }).toList();
  }
}
