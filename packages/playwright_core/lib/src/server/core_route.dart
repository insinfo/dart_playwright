import 'core_request.dart';

/// Represents a route interception in the core engine.
abstract class CoreRoute {
  CoreRequest get request;

  /// Continue the request.
  Future<void> continue_();

  /// Fulfill the request with the given response.
  Future<void> fulfill({
    int status = 200,
    Map<String, String>? headers,
    List<int>? bodyBytes,
  });

  /// Abort the request.
  Future<void> abort([String errorCode = 'failed']);
}
