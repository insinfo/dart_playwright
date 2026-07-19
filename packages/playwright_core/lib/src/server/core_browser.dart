import 'dart:async';
import 'package:playwright_protocol/playwright_protocol.dart';
import 'core_page.dart';

/// Options applied to every page of a browser context.
class CoreContextOptions {
  final ({int width, int height})? viewport;
  final String? userAgent;

  const CoreContextOptions({this.viewport, this.userAgent});
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
abstract class CoreBrowserContext {
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

  /// Disposes this context and every page that belongs to it.
  Future<void> close();
}

/// Shared cookie/storageState plumbing for the engine contexts.
///
/// Each engine supplies raw cookie access; localStorage is gathered by
/// evaluating in the pages this context has opened.
mixin BrowserContextStorage {
  /// Pages opened by this context, used to snapshot localStorage per origin.
  final List<CorePage> trackedPages = [];

  List<CorePage> get pages => List.unmodifiable(trackedPages);

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
