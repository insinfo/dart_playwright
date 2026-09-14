// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/playwright-core/src/server/har/harTracer.ts and
// packages/isomorphic/trace/versions/har.ts

import 'dart:async';
import 'dart:convert';

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

  /// Scripts are excluded from the snapshot resources by default: including
  /// them makes a trace about ten times bigger for no gain in the DOM view.
  bool omitScripts;

  /// How long a single response body may take before the recorder gives up on
  /// it. Upstream has no cap because it races the body against the page's
  /// scope; here a stuck body would hang `stopChunk` instead.
  static const bodyTimeout = Duration(seconds: 10);

  bool _started = false;
  final _entries = <CoreRequest, HarEntry>{};
  final _barriers = <Future<void>>{};
  final _listeners =
      <({EventEmitter target, String event, Function listener})>[];

  /// The page each in-flight request belongs to.
  ///
  /// The engines report the *frame id* on a request, not the frame, so the
  /// only way back to a page is the page that reported it — which is why the
  /// listeners hang off each page and not off the context, even though the
  /// context re-emits the same events.
  final _requestPages = <CoreRequest, CorePage>{};

  HarTracer(this._context, this._delegate, {this.omitScripts = true});

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

  void stop() {
    if (!_started) return;
    _started = false;
    for (final entry in _listeners) {
      entry.target.off(entry.event, entry.listener);
    }
    _listeners.clear();
  }

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
    _requestPages[request] = page;
    final entry = HarEntry.create(
      method: request.method,
      url: url,
      frameref: _frameGuid(page, request),
      pageRef: page.guid,
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
    entry.timings['dns'] =
        phase(timing.domainLookupEnd, timing.domainLookupStart);
    entry.timings['connect'] = phase(timing.connectEnd, timing.connectStart);
    entry.timings['ssl'] =
        phase(timing.connectEnd, timing.secureConnectionStart);
    entry.timings['send'] = 0;
    entry.timings['wait'] = phase(timing.responseStart, timing.requestStart);
    entry.timings['receive'] = -1;
    entry.computeTotalTime();

    final remote = response.remoteAddr;
    if (remote != null) {
      entry.serverIPAddress = remote.ipAddress;
      entry.serverPort = remote.port;
    }
    final security = response.securityDetails;
    if (security != null) {
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

    final sizes = request.sizes;
    entry.response['bodySize'] = sizes.responseBodySize;
    entry.response['headersSize'] = sizes.responseHeadersSize;
    entry.response['_transferSize'] = sizes.transferSize;
    entry.request['headersSize'] = sizes.requestHeadersSize;

    if (omitScripts && request.resourceType == 'script') {
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
    content['size'] = bytes.length;
    if (bytes.isEmpty) return;
    final mimeType = content['mimeType'] as String? ?? 'x-unknown';
    final shortName = '${sha1Hex(bytes)}.${extensionForMimeType(mimeType)}';
    if (_started) content['_file'] = _delegate.onContentBlob(shortName, bytes);
  }

  void _recordRequestHeaders(HarEntry entry, Map<String, String> headers) {
    final cookies = <Map<String, dynamic>>[];
    for (final header in headers.entries) {
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
