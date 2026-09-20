// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/playwright-core/src/server/har/harTracer.ts and
// packages/isomorphic/trace/versions/har.ts

import 'dart:async';
import 'dart:convert';

import 'package:playwright_isomorphic/playwright_isomorphic.dart';
import 'package:playwright_protocol/playwright_protocol.dart';

import '../core_browser.dart';
import '../core_page.dart';
import '../core_request.dart';
import '../core_response.dart';
import 'trace_events.dart';
import 'trace_utils.dart';

/// Upstream reports this when the engine does not say which HTTP version was
/// used; the viewer renders it verbatim.
const _fallbackHttpVersion = 'HTTP/1.1';

/// What a recorder does with the response bodies.
///
/// `omit` keeps only the metadata, `embed` puts the body inside the HAR
/// document itself (base64 for anything not textual) and `attach` writes it
/// next to the document as a file the entry points at by `_file`.
enum HarContentPolicy { omit, embed, attach }

/// How much of each request is recorded, and what happens to the bodies.
///
/// Upstream's `HarTracerOptions`, minus the flags only its API-request
/// context uses. [slimMode] is what its `mode: 'minimal'` sets: the fields a
/// HAR is replayed from are kept and everything that only a human reader
/// wants — cookies, timings, addresses, sizes, the page list — is dropped.
class HarTracerOptions {
  final HarContentPolicy content;

  /// Upstream's `mode: 'minimal'`.
  final bool slimMode;

  /// Scripts are excluded from the recorded bodies by default: including them
  /// makes a trace about ten times bigger for no gain in the DOM view. A
  /// standalone HAR turns this off, because there the script *is* the point.
  final bool omitScripts;

  /// Only requests whose URL matches are recorded. A [String] is the same
  /// glob `page.route` takes (upstream's dialect, see `urlMatch.dart`); a
  /// [RegExp] is matched with `hasMatch`. Null records every request.
  final Object? urlFilter;

  /// The context's `baseURL`, used to resolve a relative [urlFilter] glob.
  final String? baseURL;

  const HarTracerOptions({
    this.content = HarContentPolicy.attach,
    this.slimMode = false,
    this.omitScripts = true,
    this.urlFilter,
    this.baseURL,
  });

  bool get omitCookies => slimMode;
  bool get omitTiming => slimMode;
  bool get omitServerIp => slimMode;
  bool get omitSecurityDetails => slimMode;
  bool get omitSizes => slimMode;
  bool get omitPages => slimMode;
}

/// What the recorder does with the bodies and the finished entries.
abstract class HarTracerDelegate {
  /// A request started. The entry is still being filled in.
  void onEntryStarted(HarEntry entry);

  /// The entry is final and can be written to `trace.network`.
  void onEntryFinished(HarEntry entry);

  /// Stores a response body and returns the path it got inside the archive.
  String onContentBlob(String shortName, List<int> bytes);
}

/// One HAR entry, kept mutable while the request is in flight.
///
/// The HAR spec puts `-1` where a value is unknown, and so does this: the
/// three engines report very different subsets of the sizes and the timings,
/// and a zero would read as "measured, and it was nothing".
class HarEntry {
  String? pageref;
  String startedDateTime;
  double time = -1;
  final Map<String, dynamic> request;
  Map<String, dynamic> response;
  final Map<String, dynamic> timings;
  String? serverIPAddress;
  int? serverPort;
  String? frameref;
  double? monotonicTime;
  String? resourceType;
  Map<String, dynamic>? securityDetails;

  HarEntry._({
    required this.pageref,
    required this.startedDateTime,
    required this.request,
    required this.response,
    required this.timings,
    required this.frameref,
    required this.monotonicTime,
  });

  factory HarEntry.create({
    String? pageRef,
    required String method,
    required Uri url,
    String? frameref,
    int? wallTimeMs,
  }) {
    return HarEntry._(
      pageref: pageRef,
      startedDateTime: _isoOrNow(wallTimeMs),
      request: <String, dynamic>{
        'method': method,
        'url': url.toString(),
        'httpVersion': _fallbackHttpVersion,
        'cookies': <Map<String, dynamic>>[],
        'headers': <Map<String, dynamic>>[],
        'queryString': [
          for (final entry in url.queryParametersAll.entries)
            for (final value in entry.value)
              {'name': entry.key, 'value': value},
        ],
        'headersSize': -1,
        'bodySize': -1,
      },
      response: _emptyResponse(),
      timings: <String, dynamic>{'send': -1, 'wait': -1, 'receive': -1},
      frameref: frameref,
      monotonicTime: TraceClock.monotonicTime(),
    );
  }

  static Map<String, dynamic> _emptyResponse() => <String, dynamic>{
        'status': -1,
        'statusText': '',
        'httpVersion': _fallbackHttpVersion,
        'cookies': <Map<String, dynamic>>[],
        'headers': <Map<String, dynamic>>[],
        'content': <String, dynamic>{'size': -1, 'mimeType': 'x-unknown'},
        'headersSize': -1,
        'bodySize': -1,
        'redirectURL': '',
        '_transferSize': -1,
      };

  Map<String, dynamic> get content =>
      response['content'] as Map<String, dynamic>;

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      if (pageref != null) 'pageref': pageref,
      'startedDateTime': startedDateTime,
      'time': time,
      'request': request,
      'response': response,
      'cache': <String, dynamic>{},
      'timings': timings,
      if (serverIPAddress != null) 'serverIPAddress': serverIPAddress,
      if (frameref != null) '_frameref': frameref,
      if (monotonicTime != null) '_monotonicTime': monotonicTime,
      if (serverPort != null) '_serverPort': serverPort,
      if (securityDetails != null) '_securityDetails': securityDetails,
      if (resourceType != null) '_resourceType': resourceType,
    };
    return json;
  }

  /// Sums the phases the engine actually measured, exactly as upstream's
  /// `_computeHarEntryTotalTime` does.
  void computeTotalTime() {
    var total = 0.0;
    for (final key in const ['dns', 'connect', 'ssl', 'wait', 'receive']) {
      final value = (timings[key] as num?)?.toDouble() ?? -1;
      if (value > 0) total += value;
    }
    time = total;
  }

  static String _isoOrNow(int? wallTimeMs) {
    if (wallTimeMs == null || wallTimeMs <= 0) {
      return DateTime.now().toUtc().toIso8601String();
    }
    return DateTime.fromMillisecondsSinceEpoch(wallTimeMs, isUtc: true)
        .toIso8601String();
  }
}

/// Turns the context's network events into HAR entries.
///
/// Every handler here is called from `EventEmitter.emit`, which does not await
/// what a listener returns — so nothing here is `async`. The one thing that
/// genuinely needs the network (reading a response body) is started as a
/// future that can never fail and is parked in [_barriers]; [flush] is what
/// waits for them, and it is called from `stopChunk`, where an error has a
/// caller again.
class HarTracer {
  final CoreBrowserContext _context;
  final HarTracerDelegate _delegate;
  final HarTracerOptions options;

  /// How long a single response body may take before the recorder gives up on
  /// it. Upstream has no cap because it races the body against the page's
  /// scope; here a stuck body would hang `stopChunk` instead.
  static const bodyTimeout = Duration(seconds: 10);

  bool _started = false;
  final _entries = <CoreRequest, HarEntry>{};
  final _barriers = <Future<void>>{};
  final _listeners =
      <({EventEmitter target, String event, Function listener})>[];

  /// One `har.Page` per page of the context, in the order they opened. Empty
  /// while [HarTracerOptions.slimMode] is on.
  final _pageEntries = <CorePage, Map<String, dynamic>>{};

  /// The page each in-flight request belongs to.
  ///
  /// The engines report the *frame id* on a request, not the frame, so the
  /// only way back to a page is the page that reported it — which is why the
  /// listeners hang off each page and not off the context, even though the
  /// context re-emits the same events.
  final _requestPages = <CoreRequest, CorePage>{};

  HarTracer(this._context, this._delegate,
      {this.options = const HarTracerOptions()});

  bool get started => _started;

  void start() {
    if (_started) return;
    _started = true;
    _listen(_context, 'page', (dynamic page) => _onPage(page as CorePage));
    for (final page in _context.pages) {
      _onPage(page);
    }
  }

  void _onPage(CorePage page) {
    _pageEntryFor(page);
    _listen(page, 'request',
        (dynamic request) => _onRequest(page, request as CoreRequest));
    _listen(page, 'response',
        (dynamic response) => _onResponse(response as CoreResponse));
    _listen(page, 'requestFinished',
        (dynamic request) => _onRequestFinished(request as CoreRequest));
    _listen(page, 'requestFailed',
        (dynamic request) => _onRequestFailed(request as CoreRequest));
  }

  void _listen(
      EventEmitter target, String event, void Function(dynamic) listener) {
    target.on(event, listener);
    _listeners.add((target: target, event: event, listener: listener));
  }

  /// The `har.Page` of [page], created on first use.
  ///
  /// A HAR entry's `pageref` has to name a page of the `pages` array, so the
  /// entry and the page are created from the same place. In slim mode there
  /// is no array and no `pageref`.
  Map<String, dynamic>? _pageEntryFor(CorePage page) {
    if (options.omitPages) return null;
    final existing = _pageEntries[page];
    if (existing != null) return existing;
    final startedAt = DateTime.now().toUtc();
    final entry = <String, dynamic>{
      'startedDateTime': startedAt.toIso8601String(),
      'id': page.guid,
      'title': '',
      'pageTimings': options.omitTiming
          ? <String, dynamic>{}
          : <String, dynamic>{'onContentLoad': -1, 'onLoad': -1},
    };
    _pageEntries[page] = entry;
    if (options.omitTiming) return entry;
    // Upstream keeps the absolute instants while recording and turns them
    // into offsets when it builds the log; the same two-step, because the
    // page's own start is the origin and it is already known here.
    void timing(String key) {
      final timings = entry['pageTimings'] as Map<String, dynamic>;
      if ((timings[key] as num) >= 0) return;
      timings[key] =
          DateTime.now().toUtc().difference(startedAt).inMilliseconds;
    }

    _listen(page, 'load', (dynamic _) => timing('onLoad'));
    _listen(page, 'domcontentloaded', (dynamic _) => timing('onContentLoad'));
    return entry;
  }

  /// Whether [url] passes [HarTracerOptions.urlFilter].
  bool _shouldInclude(String url) =>
      urlMatches(options.baseURL, url, options.urlFilter);

  /// The `log` envelope of a HAR document, with an empty `entries`.
  ///
  /// [browserVersion] is passed in rather than read here because the engines
  /// answer it over the protocol, and this class never awaits.
  Map<String, dynamic> logHeader({String browserVersion = ''}) => {
        'version': '1.2',
        'creator': {
          'name': 'Playwright',
          'version': kPlaywrightDartVersion,
        },
        'browser': {
          'name': _context.browser.name,
          'version': browserVersion,
        },
        if (_pageEntries.isNotEmpty) 'pages': _pageEntries.values.toList(),
        'entries': <Map<String, dynamic>>[],
      };

  void stop() {
    if (!_started) return;
    _started = false;
    for (final entry in _listeners) {
      entry.target.off(entry.event, entry.listener);
    }
    _listeners.clear();
  }

  /// Drops the page list, so a tracer restarted on the same context does not
  /// carry the previous run's pages into the new document.
  void clearPages() => _pageEntries.clear();

  /// Waits for the response bodies still in flight. Never throws: each barrier
  /// swallowed its own failure when it was created.
  Future<void> flush() async {
    while (_barriers.isNotEmpty) {
      final pending = List<Future<void>>.from(_barriers);
      _barriers.clear();
      await Future.wait(pending);
    }
  }

  /// Entries whose request never finished, so `stopChunk` can still write them.
  List<HarEntry> pendingEntries() => _entries.values.toList();

  void _onRequest(CorePage page, CoreRequest request) {
    final url = Uri.tryParse(request.url);
    if (url == null) return;
    if (!_shouldInclude(request.url)) return;
    _requestPages[request] = page;
    final pageEntry = _pageEntryFor(page);
    final entry = HarEntry.create(
      method: request.method,
      url: url,
      frameref: _frameGuid(page, request),
      pageRef: pageEntry?['id'] as String?,
      wallTimeMs: request.timing.startTime > 0
          ? request.timing.startTime.round()
          : null,
    );
    entry.resourceType = request.resourceType;
    _recordRequestHeaders(entry, request.headers);
    final postData = request.postData;
    if (postData != null) {
      final contentType = _headerValue(request.headers, 'content-type') ??
          'application/octet-stream';
      entry.request['postData'] = <String, dynamic>{
        'mimeType': contentType,
        'params': <Map<String, dynamic>>[],
        'text': postData,
      };
      entry.request['bodySize'] = utf8.encode(postData).length;
    }
    final redirectedFrom = request.redirectedFrom;
    if (redirectedFrom != null) {
      final fromEntry = _entries[redirectedFrom];
      if (fromEntry != null) {
        (fromEntry.response)['redirectURL'] = request.url;
      }
    }
    _entries[request] = entry;
    if (_started) _delegate.onEntryStarted(entry);
  }

  void _onResponse(CoreResponse response) {
    final entry = _entries[response.request];
    if (entry == null) return;
    entry.response = HarEntry._emptyResponse();
    entry.response['status'] = response.status;
    entry.response['statusText'] = response.statusText;

    final timing = response.request.timing;
    if (timing.startTime > 0) {
      entry.startedDateTime = HarEntry._isoOrNow(timing.startTime.round());
    }
    double phase(double end, double start) =>
        end != -1 && start != -1 ? _roundish(end - start) : -1;
    if (!options.omitTiming) {
      entry.timings['dns'] =
          phase(timing.domainLookupEnd, timing.domainLookupStart);
      entry.timings['connect'] = phase(timing.connectEnd, timing.connectStart);
      entry.timings['ssl'] =
          phase(timing.connectEnd, timing.secureConnectionStart);
      entry.timings['send'] = 0;
      entry.timings['wait'] = phase(timing.responseStart, timing.requestStart);
      entry.timings['receive'] = -1;
      entry.computeTotalTime();
    }

    final remote = response.remoteAddr;
    if (remote != null && !options.omitServerIp) {
      entry.serverIPAddress = remote.ipAddress;
      entry.serverPort = remote.port;
    }
    final security = response.securityDetails;
    if (security != null && !options.omitSecurityDetails) {
      entry.securityDetails = <String, dynamic>{
        if (security.protocol != null) 'protocol': security.protocol,
        if (security.subjectName != null) 'subjectName': security.subjectName,
        if (security.issuer != null) 'issuer': security.issuer,
        if (security.validFrom != null) 'validFrom': security.validFrom,
        if (security.validTo != null) 'validTo': security.validTo,
      };
    }
    _recordRequestHeaders(
        entry, response.request.rawHeaders ?? response.request.headers);
    _recordResponseHeaders(entry, response.rawHeaders ?? response.headers);
  }

  void _onRequestFinished(CoreRequest request) {
    final entry = _entries[request];
    if (entry == null) return;
    final response = request.response;
    if (response == null) {
      _finish(request, entry);
      return;
    }

    if (!options.omitSizes) {
      final sizes = request.sizes;
      entry.response['bodySize'] = sizes.responseBodySize;
      entry.response['headersSize'] = sizes.responseHeadersSize;
      entry.response['_transferSize'] = sizes.transferSize;
      entry.request['headersSize'] = sizes.requestHeadersSize;
    } else {
      entry.response.remove('_transferSize');
    }

    if (options.content == HarContentPolicy.omit ||
        (options.omitScripts && request.resourceType == 'script')) {
      _finish(request, entry);
      return;
    }

    // A body is a protocol round trip, and this is an event handler: park a
    // future that cannot fail and let `flush` wait for it.
    final barrier = response
        .body()
        .then<List<int>?>((bytes) => bytes)
        .catchError((Object _) => null)
        .timeout(bodyTimeout, onTimeout: () => null)
        .then((bytes) {
      if (bytes != null) _storeResponseContent(entry, bytes);
      _finish(request, entry);
    });
    _barriers.add(barrier);
    barrier.whenComplete(() => _barriers.remove(barrier));
  }

  void _onRequestFailed(CoreRequest request) {
    final entry = _entries[request];
    if (entry == null) return;
    final failure = request.failure;
    if (failure != null) entry.response['_failureText'] = failure;
    final started = entry.monotonicTime;
    if (started != null && entry.time == -1) {
      entry.time = TraceClock.monotonicTime() - started;
    }
    _finish(request, entry);
  }

  void _finish(CoreRequest request, HarEntry entry) {
    _entries.remove(request);
    _requestPages.remove(request);
    if (_started) _delegate.onEntryFinished(entry);
  }

  /// The engines put their own frame id on a request; the trace wants the
  /// stable guid of the frame object. A request whose frame is already gone
  /// (a navigation that replaced it) gets none, which is what upstream does
  /// too.
  static String? _frameGuid(CorePage page, CoreRequest request) {
    final frameId = request.frame;
    if (frameId is! String) return null;
    for (final frame in page.frames) {
      if (frame.id == frameId) return frame.guid;
    }
    return null;
  }

  void _storeResponseContent(HarEntry entry, List<int> bytes) {
    final content = entry.content;
    if (!options.omitSizes) content['size'] = bytes.length;
    if (bytes.isEmpty) return;
    final mimeType = content['mimeType'] as String? ?? 'x-unknown';
    if (options.content == HarContentPolicy.embed) {
      // A font served with a textual content type is a real thing browsers
      // cope with and this must not: decoding it as text would corrupt it.
      // Upstream carves out the same exception.
      if (_isTextualMimeType(mimeType) && entry.resourceType != 'font') {
        try {
          content['text'] = utf8.decode(bytes);
          return;
        } catch (_) {
          // Mislabelled as text but not valid UTF-8; fall through to base64.
        }
      }
      content['text'] = base64Encode(bytes);
      content['encoding'] = 'base64';
      return;
    }
    if (options.content != HarContentPolicy.attach) return;
    final shortName = '${sha1Hex(bytes)}.${extensionForMimeType(mimeType)}';
    if (_started) content['_file'] = _delegate.onContentBlob(shortName, bytes);
  }

  /// Whether a body of this type reads back as text. Upstream's
  /// `isTextualMimeType`.
  static bool _isTextualMimeType(String mimeType) {
    final type = mimeType.split(';').first.trim().toLowerCase();
    if (type.startsWith('text/')) return true;
    return const {
      'application/javascript',
      'application/x-javascript',
      'application/json',
      'application/xml',
      'application/x-www-form-urlencoded',
      'image/svg+xml',
    }.contains(type);
  }

  void _recordRequestHeaders(HarEntry entry, Map<String, String> headers) {
    final cookies = <Map<String, dynamic>>[];
    for (final header in headers.entries) {
      if (options.omitCookies) break;
      if (header.key.toLowerCase() != 'cookie') continue;
      for (final pair in header.value.split(';')) {
        cookies.add(_parseCookie(pair));
      }
    }
    entry.request['cookies'] = cookies;
    entry.request['headers'] = _headerList(headers);
  }

  void _recordResponseHeaders(HarEntry entry, Map<String, String> headers) {
    final cookies = <Map<String, dynamic>>[];
    for (final header in headers.entries) {
      if (options.omitCookies) break;
      if (header.key.toLowerCase() != 'set-cookie') continue;
      // Engines that fold repeated `Set-Cookie` headers into one value
      // separate them by newline; splitting keeps each cookie its own row.
      for (final value in header.value.split('\n')) {
        cookies.add(_parseCookie(value));
      }
    }
    entry.response['cookies'] = cookies;
    entry.response['headers'] = _headerList(headers);
    final contentType = _headerValue(headers, 'content-type');
    if (contentType != null) entry.content['mimeType'] = contentType;
    final location = _headerValue(headers, 'location');
    if (location != null) entry.response['redirectURL'] = location;
  }

  static List<Map<String, dynamic>> _headerList(Map<String, String> headers) =>
      [
        for (final header in headers.entries)
          {'name': header.key, 'value': header.value},
      ];

  static String? _headerValue(Map<String, String> headers, String name) {
    for (final header in headers.entries) {
      if (header.key.toLowerCase() == name) return header.value;
    }
    return null;
  }

  static Map<String, dynamic> _parseCookie(String raw) {
    final cookie = <String, dynamic>{'name': '', 'value': ''};
    var first = true;
    for (final pair in raw.split(RegExp(r'; *'))) {
      final index = pair.indexOf('=');
      final name = index != -1 ? pair.substring(0, index).trim() : pair.trim();
      final value = index != -1 ? pair.substring(index + 1).trim() : '';
      if (first) {
        first = false;
        cookie['name'] = name;
        cookie['value'] = value;
        continue;
      }
      switch (name.toLowerCase()) {
        case 'domain':
          cookie['domain'] = value;
        case 'expires':
          final parsed = DateTime.tryParse(value);
          if (parsed != null) {
            cookie['expires'] = parsed.toUtc().toIso8601String();
          }
        case 'httponly':
          cookie['httpOnly'] = true;
        case 'secure':
          cookie['secure'] = true;
        case 'path':
          cookie['path'] = value;
        case 'samesite':
          cookie['sameSite'] = value;
      }
    }
    return cookie;
  }

  /// Upstream rounds sub-millisecond timings to three decimals so the HAR does
  /// not carry float noise.
  static double _roundish(double value) =>
      (value * 1000).roundToDouble() / 1000;
}
