import 'dart:convert';
import '../core_route.dart';
import '../core_request.dart';
import 'wk_connection.dart';

/// Implementation of network interception for WebKit.
///
/// Requests paused by `Network.addInterception` arrive as
/// `Network.requestIntercepted` events and are answered with the
/// `Network.intercept*` family of commands on the page target.
class WkRoute implements CoreRoute {
  final WkPageProxySession session;
  final String requestId;
  final String url;
  final String method;
  final Map<String, String> headers;
  late final CoreRequest _request;

  /// Called when the handler declines the route with [fallback].
  @override
  void Function()? onFallback;

  WkRoute(this.session, this.requestId, this.url,
      {this.method = 'GET',
      this.headers = const <String, String>{},
      String? postData,
      String resourceType = 'other',
      bool isNavigationRequest = false,
      dynamic frame}) {
    _request = BasicCoreRequest(
        url: url,
        method: method,
        headers: headers,
        postData: postData,
        postDataBuffer: postData == null ? null : utf8.encode(postData),
        resourceType: resourceType,
        isNavigationRequest: isNavigationRequest,
        frame: frame);
  }

  @override
  CoreRequest get request => _request;

  @override
  Future<void> fallback() async {
    final next = onFallback;
    onFallback = null;
    if (next != null) next();
  }

  @override
  Future<void> continue_({
    String? url,
    String? method,
    Map<String, String>? headers,
    List<int>? postData,
  }) async {
    // Without overrides, the cheap resume; with them, WebKit needs the whole
    // request restated. Note the headers are a plain object here, unlike
    // Chromium and Firefox, which take an array.
    if (url == null && method == null && headers == null && postData == null) {
      await session.sendToTarget('Network.interceptContinue', {
        'requestId': requestId,
        'stage': 'request',
      });
      return;
    }
    await session.sendToTarget('Network.interceptWithRequest', {
      'requestId': requestId,
      if (url != null) 'url': url,
      if (method != null) 'method': method,
      if (headers != null) 'headers': headers,
      if (postData != null) 'postData': base64Encode(postData),
    });
  }

  @override
  Future<void> fulfill(
      {int status = 200,
      Map<String, String>? headers,
      List<int>? bodyBytes}) async {
    await session.sendToTarget('Network.interceptRequestWithResponse', {
      'requestId': requestId,
      'status': status,
      'statusText': 'OK',
      'mimeType': headers?['Content-Type'] ?? 'text/html',
      'headers': headers ?? <String, String>{},
      'base64Encoded': true,
      'content': base64Encode(bodyBytes ?? const <int>[]),
    });
  }

  @override
  Future<void> abort([String errorCode = 'failed']) async {
    await session.sendToTarget('Network.interceptRequestWithError', {
      'requestId': requestId,
      'errorType': RouteErrorCodes.resolve(RouteErrorCodes.webkit, errorCode),
    });
  }
}
