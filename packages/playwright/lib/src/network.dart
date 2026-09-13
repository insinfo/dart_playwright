import 'dart:convert';

import 'package:playwright_core/playwright_core.dart';
import 'frame.dart';

/// One header, as it appeared on the wire.
typedef HeaderEntry = ({String name, String value});

/// Network timings for a request, in milliseconds.
///
/// `startTime` is milliseconds since the epoch; the rest are relative to it,
/// and `-1` means the engine does not measure that phase. Firefox and WebKit
/// report less than Chromium here, and `-1` says so rather than inventing a
/// number.
typedef ResourceTiming = ({
  double startTime,
  double domainLookupStart,
  double domainLookupEnd,
  double connectStart,
  double secureConnectionStart,
  double connectEnd,
  double requestStart,
  double responseStart,
});

/// Byte counts for a request/response pair, with `-1` for what the engine
/// does not report: Firefox has no header sizes, WebKit has no transfer size.
typedef ResourceSizes = ({
  int requestBodySize,
  int requestHeadersSize,
  int responseBodySize,
  int responseHeadersSize,
  int transferSize,
});

/// The TLS certificate a secure response was served with. WebKit does not
/// report the issuer.
typedef SecurityDetails = ({
  String? protocol,
  String? subjectName,
  String? issuer,
  double? validFrom,
  double? validTo,
});

/// The address a response came from.
typedef RemoteAddr = ({String ipAddress, int port});

List<HeaderEntry> _toHeadersArray(Map<String, String> headers) =>
    headers.entries.map((e) => (name: e.key, value: e.value)).toList();

Map<String, String> _lowerCased(Map<String, String> headers) => {
      for (final entry in headers.entries) entry.key.toLowerCase(): entry.value,
    };

/// Represents a network request made by a page.
abstract class Request {
  /// URL of the request.
  String url();

  /// HTTP method of the request (GET, POST, etc).
  String method();

  /// Headers as the engine first reported them.
  ///
  /// Prefer [allHeaders]: these are the provisional headers, taken before the
  /// network stack added its own, and upstream deprecates them for that
  /// reason.
  Map<String, String> headers();

  /// All headers actually sent, with lower-cased names.
  ///
  /// Falls back to [headers] on engines that do not report the raw set
  /// (Firefox never does).
  Future<Map<String, String>> allHeaders();

  /// All headers actually sent, keeping the original casing and order.
  Future<List<HeaderEntry>> headersArray();

  /// The value of one header, matched case-insensitively, or null.
  Future<String?> headerValue(String name);

  /// Request body for POST-like requests, when the protocol reports it.
  String? postData();

  /// The raw request body bytes, when the protocol reports them.
  List<int>? postDataBuffer();

  /// The request body parsed as JSON, or null when there is no body.
  ///
  /// Throws if the body is not valid JSON.
  dynamic postDataJSON();

  /// The resource type: `document`, `stylesheet`, `image`, `media`, `font`,
  /// `script`, `texttrack`, `xhr`, `fetch`, `eventsource`, `websocket`,
  /// `manifest`, `beacon`, `ping`, `cspreport` or `other`.
  String resourceType();

  /// Whether this request is driving a frame navigation.
  bool isNavigationRequest();

  /// The error text when the request failed, or null when it did not.
  String? failure();

  /// The response, once one arrived, or null for a failed request.
  Future<Response?> response();

  /// The request that redirected to this one, or null.
  Request? redirectedFrom();

  /// The request this one redirected to, or null.
  Request? redirectedTo();

  /// Network timings for this request.
  ResourceTiming timing();

  /// Byte counts, meaningful once the request finished.
  Future<ResourceSizes> sizes();

  /// The frame that initiated this request.
  Frame frame();
}

class RequestImpl implements Request {
  final CoreRequest _coreRequest;

  RequestImpl(this._coreRequest);

  @override
  String url() => _coreRequest.url;

  @override
  String method() => _coreRequest.method;

  @override
  Map<String, String> headers() => _coreRequest.headers;

  @override
  Future<Map<String, String>> allHeaders() async =>
      _lowerCased(_coreRequest.rawHeaders ?? _coreRequest.headers);

  @override
  Future<List<HeaderEntry>> headersArray() async =>
      _toHeadersArray(_coreRequest.rawHeaders ?? _coreRequest.headers);

  @override
  Future<String?> headerValue(String name) async =>
      (await allHeaders())[name.toLowerCase()];

  @override
  String? postData() => _coreRequest.postData;

  @override
  List<int>? postDataBuffer() => _coreRequest.postDataBuffer;

  @override
  dynamic postDataJSON() {
    final data = _coreRequest.postData;
    if (data == null || data.isEmpty) return null;
    return jsonDecode(data);
  }

  @override
  String resourceType() => _coreRequest.resourceType;

  @override
  bool isNavigationRequest() => _coreRequest.isNavigationRequest;

  @override
  String? failure() => _coreRequest.failure;

  @override
  Future<Response?> response() async {
    final response = _coreRequest.response;
    return response == null ? null : ResponseImpl(response);
  }

  @override
  Request? redirectedFrom() {
    final previous = _coreRequest.redirectedFrom;
    return previous == null ? null : RequestImpl(previous);
  }

  @override
  Request? redirectedTo() {
    final next = _coreRequest.redirectedTo;
    return next == null ? null : RequestImpl(next);
  }

  @override
  ResourceTiming timing() {
    final timing = _coreRequest.timing;
    return (
      startTime: timing.startTime,
      domainLookupStart: timing.domainLookupStart,
      domainLookupEnd: timing.domainLookupEnd,
      connectStart: timing.connectStart,
      secureConnectionStart: timing.secureConnectionStart,
      connectEnd: timing.connectEnd,
      requestStart: timing.requestStart,
      responseStart: timing.responseStart,
    );
  }

  @override
  Future<ResourceSizes> sizes() async {
    // Sizes are only complete once the request ended, so wait for it rather
    // than answering with the zeroes the engine has so far.
    await _coreRequest.finished();
    final sizes = _coreRequest.sizes;
    return (
      requestBodySize: sizes.requestBodySize,
      requestHeadersSize: sizes.requestHeadersSize,
      responseBodySize: sizes.responseBodySize,
      responseHeadersSize: sizes.responseHeadersSize,
      transferSize: sizes.transferSize,
    );
  }

  @override
  Frame frame() {
    // TODO: Implement properly when CoreFrame is decoupled
    throw UnimplementedError('Request.frame is not fully decoupled yet');
  }
}

/// Represents a network response received by a page.
abstract class Response {
  /// The corresponding request.
  Request request();

  /// URL of the response.
  String url();

  /// HTTP status code (e.g. 200).
  int status();

  /// Status text (e.g. "OK").
  String statusText();

  /// Whether the response was successful (status 200-299).
  bool ok();

  /// Headers as the engine first reported them.
  ///
  /// Prefer [allHeaders]; see [Request.headers] for why.
  Map<String, String> headers();

  /// All response headers, with lower-cased names.
  Future<Map<String, String>> allHeaders();

  /// All response headers, keeping the original casing and order.
  Future<List<HeaderEntry>> headersArray();

  /// The value of one header, matched case-insensitively, or null.
  ///
  /// Multiple values for the same name are joined with `, `, except
  /// `set-cookie`, which is joined with a newline, as upstream does.
  Future<String?> headerValue(String name);

  /// Every value for one header name.
  Future<List<String>> headerValues(String name);

  /// The address the response came from, or null when the engine does not
  /// report it.
  Future<RemoteAddr?> serverAddr();

  /// The TLS details of a secure response, or null for plain HTTP and on
  /// engines that do not report them.
  Future<SecurityDetails?> securityDetails();

  /// Whether a service worker produced this response.
  bool fromServiceWorker();

  /// Completes when the request behind this response finished, yielding the
  /// failure text on failure and null on success.
  Future<String?> finished();

  /// The raw response body bytes.
  Future<List<int>> body();

  /// The response body decoded as UTF-8 text.
  Future<String> text();

  /// The response body parsed as JSON.
  Future<dynamic> json();
}

class ResponseImpl implements Response {
  final CoreResponse _coreResponse;
  late final Request _request;

  ResponseImpl(this._coreResponse) {
    _request = RequestImpl(_coreResponse.request);
  }

  @override
  Request request() => _request;

  @override
  String url() => _coreResponse.url;

  @override
  int status() => _coreResponse.status;

  @override
  String statusText() => _coreResponse.statusText;

  @override
  bool ok() => _coreResponse.ok;

  @override
  Map<String, String> headers() => _coreResponse.headers;

  @override
  Future<Map<String, String>> allHeaders() async =>
      _lowerCased(_coreResponse.rawHeaders ?? _coreResponse.headers);

  @override
  Future<List<HeaderEntry>> headersArray() async =>
      _toHeadersArray(_coreResponse.rawHeaders ?? _coreResponse.headers);

  @override
  Future<String?> headerValue(String name) async {
    final values = await headerValues(name);
    if (values.isEmpty) return null;
    return values.join(name.toLowerCase() == 'set-cookie' ? '\n' : ', ');
  }

  @override
  Future<List<String>> headerValues(String name) async {
    final wanted = name.toLowerCase();
    return [
      for (final entry in await headersArray())
        if (entry.name.toLowerCase() == wanted) entry.value,
    ];
  }

  @override
  Future<RemoteAddr?> serverAddr() async {
    final addr = _coreResponse.remoteAddr;
    return addr == null ? null : (ipAddress: addr.ipAddress, port: addr.port);
  }

  @override
  Future<SecurityDetails?> securityDetails() async {
    final details = _coreResponse.securityDetails;
    if (details == null) return null;
    return (
      protocol: details.protocol,
      subjectName: details.subjectName,
      issuer: details.issuer,
      validFrom: details.validFrom,
      validTo: details.validTo,
    );
  }

  @override
  bool fromServiceWorker() => _coreResponse.fromServiceWorker;

  @override
  Future<String?> finished() => _coreResponse.finished();

  @override
  Future<List<int>> body() => _coreResponse.body();

  @override
  Future<String> text() async => utf8.decode(await body());

  @override
  Future<dynamic> json() async => jsonDecode(await text());
}
