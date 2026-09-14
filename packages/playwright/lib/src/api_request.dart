import 'dart:convert';
import 'dart:io';

import 'package:playwright_protocol/playwright_protocol.dart';

import 'browser_context.dart';
import 'network.dart';

/// The response to an [APIRequestContext] call.
///
/// The body is read eagerly, so [body], [text] and [json] never touch the
/// network again and [dispose] is only there for API parity.
abstract class APIResponse {
  /// The final URL, after redirects.
  String url();

  /// HTTP status code.
  int status();

  /// HTTP status text.
  String statusText();

  /// Whether the status is in the 200-299 range.
  bool ok();

  /// Response headers, with lower-cased names. Repeated headers are joined
  /// with `, `, except `set-cookie`, which is joined with a newline.
  Map<String, String> headers();

  /// Response headers, one entry per value, preserving repeats.
  List<HeaderEntry> headersArray();

  /// The raw response body.
  List<int> body();

  /// The body decoded as UTF-8.
  String text();

  /// The body parsed as JSON.
  dynamic json();

  /// Releases the body. Kept for parity; the body is already in memory.
  Future<void> dispose();
}

class APIResponseImpl implements APIResponse {
  final String _url;
  final int _status;
  final String _statusText;
  final List<HeaderEntry> _headers;
  final List<int> _body;

  APIResponseImpl({
    required String url,
    required int status,
    required String statusText,
    required List<HeaderEntry> headers,
    required List<int> body,
  })  : _url = url,
        _status = status,
        _statusText = statusText,
        _headers = headers,
        _body = body;

  @override
  String url() => _url;

  @override
  int status() => _status;

  @override
  String statusText() => _statusText;

  @override
  bool ok() => _status >= 200 && _status < 300;

  @override
  Map<String, String> headers() {
    final grouped = <String, List<String>>{};
    for (final entry in _headers) {
      grouped.putIfAbsent(entry.name.toLowerCase(), () => []).add(entry.value);
    }
    return {
      for (final entry in grouped.entries)
        entry.key: entry.value.join(entry.key == 'set-cookie' ? '\n' : ', '),
    };
  }

  @override
  List<HeaderEntry> headersArray() => List.unmodifiable(_headers);

  @override
  List<int> body() => _body;

  @override
  String text() => utf8.decode(_body);

  @override
  dynamic json() => jsonDecode(text());

  @override
  Future<void> dispose() async {}

  @override
  String toString() => 'APIResponse($_status $_statusText $_url)';
}

/// Makes HTTP requests that behave like the browser's, without a page.
///
/// When it comes from [BrowserContext.request] it shares that context's
/// cookie jar in both directions: cookies stored in the context are sent, and
/// `Set-Cookie` on the response is written back, so a session established
/// here is visible to the pages and the other way round.
///
/// Not implemented yet: multipart form uploads, `storageState` import/export
/// on a standalone context, and client certificates.
abstract class APIRequestContext {
  /// Send a request with an arbitrary method.
  ///
  /// Exactly one body may be given: [data] (a String, a byte list, or any
  /// other value, which is JSON-encoded) or [form] (URL-encoded).
  /// [params] is appended to the query string.
  Future<APIResponse> fetch(
    String url, {
    String method = 'GET',
    Map<String, String>? headers,
    Object? data,
    Map<String, String>? form,
    Map<String, String>? params,
    Duration? timeout,
    int? maxRedirects,
    bool? ignoreHTTPSErrors,
  });

  Future<APIResponse> get(String url,
      {Map<String, String>? headers,
      Map<String, String>? params,
      Duration? timeout});

  Future<APIResponse> head(String url,
      {Map<String, String>? headers,
      Map<String, String>? params,
      Duration? timeout});

  Future<APIResponse> delete(String url,
      {Map<String, String>? headers,
      Object? data,
      Map<String, String>? params,
      Duration? timeout});

  Future<APIResponse> post(String url,
      {Map<String, String>? headers,
      Object? data,
      Map<String, String>? form,
      Map<String, String>? params,
      Duration? timeout});

  Future<APIResponse> put(String url,
      {Map<String, String>? headers,
      Object? data,
      Map<String, String>? form,
      Map<String, String>? params,
      Duration? timeout});

  Future<APIResponse> patch(String url,
      {Map<String, String>? headers,
      Object? data,
      Map<String, String>? form,
      Map<String, String>? params,
      Duration? timeout});

  /// Closes the underlying HTTP client.
  Future<void> dispose();
}

class APIRequestContextImpl implements APIRequestContext {
  final String? _baseURL;
  final Map<String, String> _extraHTTPHeaders;
  final bool _ignoreHTTPSErrors;
  final Duration _defaultTimeout;

  /// The browser context to exchange cookies with, when there is one.
  final BrowserContext? _cookieOwner;

  HttpClient? _client;

  APIRequestContextImpl({
    String? baseURL,
    Map<String, String>? extraHTTPHeaders,
    bool ignoreHTTPSErrors = false,
    Duration timeout = const Duration(seconds: 30),
    BrowserContext? cookieOwner,
  })  : _baseURL = baseURL,
        _extraHTTPHeaders = extraHTTPHeaders ?? const {},
        _ignoreHTTPSErrors = ignoreHTTPSErrors,
        _defaultTimeout = timeout,
        _cookieOwner = cookieOwner;

  HttpClient get _httpClient {
    final existing = _client;
    if (existing != null) return existing;
    final created = HttpClient();
    if (_ignoreHTTPSErrors) {
      created.badCertificateCallback = (_, __, ___) => true;
    }
    // Cookies are managed against the browser context, not by the client, so
    // that both directions stay in sync.
    return _client = created;
  }

  Uri _resolve(String url, Map<String, String>? params) {
    final base = _baseURL;
    var uri = base == null ? Uri.parse(url) : Uri.parse(base).resolve(url);
    if (params != null && params.isNotEmpty) {
      uri = uri.replace(queryParameters: {
        ...uri.queryParameters,
        ...params,
      });
    }
    return uri;
  }

  @override
  Future<APIResponse> fetch(
    String url, {
    String method = 'GET',
    Map<String, String>? headers,
    Object? data,
    Map<String, String>? form,
    Map<String, String>? params,
    Duration? timeout,
    int? maxRedirects,
    bool? ignoreHTTPSErrors,
  }) async {
    if (data != null && form != null) {
      throw ArgumentError('Pass data or form, not both');
    }
    final uri = _resolve(url, params);

    List<int>? payload;
    String? contentType;
    if (form != null) {
      payload = utf8.encode(form.entries
          .map((e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
          .join('&'));
      contentType = 'application/x-www-form-urlencoded';
    } else if (data != null) {
      if (data is String) {
        payload = utf8.encode(data);
        contentType = 'text/plain';
      } else if (data is List<int>) {
        payload = data;
        contentType = 'application/octet-stream';
      } else {
        payload = utf8.encode(jsonEncode(data));
        contentType = 'application/json';
      }
    }

    final request = await _httpClient.openUrl(method, uri);
    request.followRedirects = maxRedirects != 0;
    if (maxRedirects != null && maxRedirects > 0) {
      request.maxRedirects = maxRedirects;
    }

    final merged = <String, String>{..._extraHTTPHeaders, ...?headers};
    var hasContentType = false;
    for (final entry in merged.entries) {
      if (entry.key.toLowerCase() == 'content-type') hasContentType = true;
      request.headers.set(entry.key, entry.value);
    }
    if (payload != null && !hasContentType && contentType != null) {
      request.headers.set(HttpHeaders.contentTypeHeader, contentType);
    }

    final cookieHeader = await _cookieHeaderFor(uri);
    if (cookieHeader != null) {
      request.headers.set(HttpHeaders.cookieHeader, cookieHeader);
    }

    if (payload != null) request.add(payload);

    final response = await request.close().timeout(timeout ?? _defaultTimeout,
        onTimeout: () {
      request.abort();
      throw TimeoutException('API request to $uri timed out',
          timeout: timeout ?? _defaultTimeout);
    });

    final headerEntries = <HeaderEntry>[];
    response.headers.forEach((name, values) {
      for (final value in values) {
        headerEntries.add((name: name, value: value));
      }
    });

    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
    }

    await _storeCookies(uri, response.cookies);

    return APIResponseImpl(
      url: uri.toString(),
      status: response.statusCode,
      statusText: response.reasonPhrase,
      headers: headerEntries,
      body: bytes,
    );
  }

  /// The `Cookie` header for [uri], taken from the browser context so an API
  /// call sees the same session the pages do.
  Future<String?> _cookieHeaderFor(Uri uri) async {
    final owner = _cookieOwner;
    if (owner == null) return null;
    final cookies = await owner.cookies();
    final matching = <String>[];
    for (final cookie in cookies) {
      // Only a *leading* dot is the wildcard marker; replaceFirst('.', '')
      // would turn 127.0.0.1 into 1270.0.1.
      var domain = cookie['domain'] as String? ?? '';
      if (domain.startsWith('.')) domain = domain.substring(1);
      if (domain.isNotEmpty &&
          uri.host != domain &&
          !uri.host.endsWith('.$domain')) {
        continue;
      }
      final path = cookie['path'] as String? ?? '/';
      if (!uri.path.startsWith(path)) continue;
      if (cookie['secure'] == true && uri.scheme != 'https') continue;
      matching.add('${cookie['name']}=${cookie['value']}');
    }
    return matching.isEmpty ? null : matching.join('; ');
  }

  /// Writes `Set-Cookie` back into the browser context.
  Future<void> _storeCookies(Uri uri, List<Cookie> cookies) async {
    final owner = _cookieOwner;
    if (owner == null || cookies.isEmpty) return;
    await owner.addCookies([
      for (final cookie in cookies)
        {
          'name': cookie.name,
          'value': cookie.value,
          'domain': cookie.domain ?? uri.host,
          'path': cookie.path ?? '/',
          if (cookie.expires != null)
            'expires': cookie.expires!.millisecondsSinceEpoch / 1000,
          'httpOnly': cookie.httpOnly,
          'secure': cookie.secure,
        },
    ]);
  }

  @override
  Future<APIResponse> get(String url,
          {Map<String, String>? headers,
          Map<String, String>? params,
          Duration? timeout}) =>
      fetch(url,
          method: 'GET', headers: headers, params: params, timeout: timeout);

  @override
  Future<APIResponse> head(String url,
          {Map<String, String>? headers,
          Map<String, String>? params,
          Duration? timeout}) =>
      fetch(url,
          method: 'HEAD', headers: headers, params: params, timeout: timeout);

  @override
  Future<APIResponse> delete(String url,
          {Map<String, String>? headers,
          Object? data,
          Map<String, String>? params,
          Duration? timeout}) =>
      fetch(url,
          method: 'DELETE',
          headers: headers,
          data: data,
          params: params,
          timeout: timeout);

  @override
  Future<APIResponse> post(String url,
          {Map<String, String>? headers,
          Object? data,
          Map<String, String>? form,
          Map<String, String>? params,
          Duration? timeout}) =>
      fetch(url,
          method: 'POST',
          headers: headers,
          data: data,
          form: form,
          params: params,
          timeout: timeout);

  @override
  Future<APIResponse> put(String url,
          {Map<String, String>? headers,
          Object? data,
          Map<String, String>? form,
          Map<String, String>? params,
          Duration? timeout}) =>
      fetch(url,
          method: 'PUT',
          headers: headers,
          data: data,
          form: form,
          params: params,
          timeout: timeout);

  @override
  Future<APIResponse> patch(String url,
          {Map<String, String>? headers,
          Object? data,
          Map<String, String>? form,
          Map<String, String>? params,
          Duration? timeout}) =>
      fetch(url,
          method: 'PATCH',
          headers: headers,
          data: data,
          form: form,
          params: params,
          timeout: timeout);

  @override
  Future<void> dispose() async {
    _client?.close(force: true);
    _client = null;
  }
}

/// Creates standalone [APIRequestContext]s, reached as `playwright.request`.
class APIRequest {
  const APIRequest();

  /// A request context that shares nothing with a browser.
  ///
  /// [baseURL] is resolved against every relative URL,
  /// [extraHTTPHeaders] go on every request, and [ignoreHTTPSErrors] accepts
  /// self-signed certificates.
  Future<APIRequestContext> newContext({
    String? baseURL,
    Map<String, String>? extraHTTPHeaders,
    bool ignoreHTTPSErrors = false,
    Duration timeout = const Duration(seconds: 30),
  }) async =>
      APIRequestContextImpl(
        baseURL: baseURL,
        extraHTTPHeaders: extraHTTPHeaders,
        ignoreHTTPSErrors: ignoreHTTPSErrors,
        timeout: timeout,
      );
}
