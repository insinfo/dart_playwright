import 'dart:convert';
import 'package:playwright_core/playwright_core.dart';
import 'network.dart';

/// Represents a route interception.
abstract class Route {
  /// The request being intercepted.
  Request request();

  /// Continue the request.
  Future<void> continue_();

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
  Future<void> continue_() => _coreRoute.continue_();

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
