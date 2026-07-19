import 'dart:convert';

/// Represents a route interception.
abstract class Route {
  /// Continue the request.
  Future<void> continue_();

  /// Fulfill the request with the given response.
  Future<void> fulfill({int status = 200, Map<String, String>? headers, String? body, List<int>? bodyBytes});

  /// Abort the request.
  Future<void> abort([String errorCode = 'failed']);
}

class RouteImpl implements Route {
  /// Engine-specific route object (CrRoute, FfRoute or WkRoute); all expose
  /// the same continue_/fulfill/abort shape.
  final dynamic _route;

  RouteImpl(this._route);

  @override
  Future<void> continue_() => _route.continue_();

  @override
  Future<void> fulfill({int status = 200, Map<String, String>? headers, String? body, List<int>? bodyBytes}) {
    List<int>? finalBytes = bodyBytes;
    if (body != null && finalBytes == null) {
      finalBytes = utf8.encode(body);
    }
    return _route.fulfill(status: status, headers: headers, bodyBytes: finalBytes);
  }

  @override
  Future<void> abort([String errorCode = 'failed']) => _route.abort(errorCode);
}
