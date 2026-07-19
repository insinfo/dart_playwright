import 'dart:convert';
import 'package:playwright_core/src/server/chromium/cr_route.dart';

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
  final CrRoute _crRoute;
  
  RouteImpl(this._crRoute);

  @override
  Future<void> continue_() => _crRoute.continue_();

  @override
  Future<void> fulfill({int status = 200, Map<String, String>? headers, String? body, List<int>? bodyBytes}) {
    List<int>? finalBytes = bodyBytes;
    if (body != null && finalBytes == null) {
      finalBytes = utf8.encode(body);
    }
    return _crRoute.fulfill(status: status, headers: headers, bodyBytes: finalBytes);
  }

  @override
  Future<void> abort([String errorCode = 'failed']) => _crRoute.abort(errorCode);
}
