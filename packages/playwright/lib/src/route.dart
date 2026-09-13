import 'dart:convert';
import 'package:playwright_core/playwright_core.dart';
import 'network.dart';

/// Represents a route interception.
abstract class Route {
  /// The request being intercepted.
  Request request();

  /// Continue the request, optionally rewriting it on the way out.
  ///
  /// [headers] replaces the request headers wholesale; a name given here
  /// wins over the one the request carried, and the casing is preserved.
  /// Changing the URL to a different protocol is rejected by the engines.
  Future<void> continue_({
    String? url,
    String? method,
    Map<String, String>? headers,
    String? postData,
    List<int>? postDataBytes,
  });

  /// Decline this route, so the next matching handler receives it.
  ///
  /// Handlers run newest first; when the last one falls back, the request
  /// continues untouched. This is the one method here that touches no
  /// protocol at all.
  Future<void> fallback();

  /// Fulfill the request with the given response.
  ///
  /// [json] serializes the value and defaults the content type to
  /// application/json; [contentType] sets the Content-Type header.
  Future<void> fulfill(
      {int status = 200,
      Map<String, String>? headers,
      String? body,
      List<int>? bodyBytes,
      String? contentType,
      Object? json});

  /// Abort the request.
  ///
  /// [errorCode] is one of `aborted`, `accessdenied`, `addressunreachable`,
  /// `blockedbyclient`, `blockedbyresponse`, `connectionaborted`,
  /// `connectionclosed`, `connectionfailed`, `connectionrefused`,
  /// `connectionreset`, `internetdisconnected`, `namenotresolved`,
  /// `timedout` or `failed`. Each engine maps it onto what it understands;
  /// WebKit only distinguishes four outcomes, so most codes collapse there.
  Future<void> abort([String errorCode = 'failed']);
}

class RouteImpl implements Route {
  final CoreRoute _coreRoute;
  late final Request _request;

  RouteImpl(this._coreRoute) {
    _request = RequestImpl(_coreRoute.request);
  }

  @override
  Request request() => _request;

  @override
  Future<void> continue_({
    String? url,
    String? method,
    Map<String, String>? headers,
    String? postData,
    List<int>? postDataBytes,
  }) {
    assert(postData == null || postDataBytes == null,
        'pass postData or postDataBytes, not both');
    return _coreRoute.continue_(
      url: url,
      method: method,
      headers: headers,
      postData: postDataBytes ??
          (postData == null ? null : utf8.encode(postData)),
    );
  }

  @override
  Future<void> fallback() => _coreRoute.fallback();

  @override
  Future<void> fulfill(
      {int status = 200,
      Map<String, String>? headers,
      String? body,
      List<int>? bodyBytes,
      String? contentType,
      Object? json}) {
    var finalContentType = contentType;
    var finalBody = body;
    if (json != null) {
      assert(finalBody == null && bodyBytes == null,
          'json cannot be combined with body or bodyBytes');
      finalBody = jsonEncode(json);
      finalContentType ??= 'application/json';
    }
    List<int>? finalBytes = bodyBytes;
    if (finalBody != null && finalBytes == null) {
      finalBytes = utf8.encode(finalBody);
    }
    Map<String, String>? finalHeaders = headers;
    if (finalContentType != null) {
      finalHeaders = {...?headers, 'Content-Type': finalContentType};
    }
    return _coreRoute.fulfill(
        status: status, headers: finalHeaders, bodyBytes: finalBytes);
  }

  @override
  Future<void> abort([String errorCode = 'failed']) => _coreRoute.abort(errorCode);
}
