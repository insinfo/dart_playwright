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
  Future<void> fulfill({int status = 200, Map<String, String>? headers, String? body, List<int>? bodyBytes});

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
  Future<void> fulfill({int status = 200, Map<String, String>? headers, String? body, List<int>? bodyBytes}) {
    List<int>? finalBytes = bodyBytes;
    if (body != null && finalBytes == null) {
      finalBytes = utf8.encode(body);
    }
    return _coreRoute.fulfill(status: status, headers: headers, bodyBytes: finalBytes);
  }

  @override
  Future<void> abort([String errorCode = 'failed']) => _coreRoute.abort(errorCode);
}
