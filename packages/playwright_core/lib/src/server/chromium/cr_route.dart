import 'dart:convert';
import '../core_route.dart';
import '../core_request.dart';

/// Implementation of network interception for Chromium.
class CrRoute implements CoreRoute {
  final dynamic session;
  final String fetchRequestId;
  final String url;
  final String method;
  final Map<String, String> headers;
  late final CoreRequest _request;

  /// Called when the handler declines the route with [fallback], so the page
  /// can hand it to the next matching handler.
  @override
  void Function()? onFallback;

  CrRoute(this.session, this.fetchRequestId, this.url,
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
    await session.send('Fetch.continueRequest', {
      'requestId': fetchRequestId,
      if (url != null) 'url': url,
      if (method != null) 'method': method,
      // CDP takes an array of {name, value}. `cookie` is stripped because
      // Chromium rejects it here (upstream does the same, crNetworkManager
      // .ts:727).
      if (headers != null)
        'headers': headers.entries
            .where((e) => e.key.toLowerCase() != 'cookie')
            .map((e) => {'name': e.key, 'value': e.value})
            .toList(),
      if (postData != null) 'postData': base64Encode(postData),
    });
  }

  @override
  Future<void> fulfill(
      {int status = 200,
      Map<String, String>? headers,
      List<int>? bodyBytes}) async {
    final params = <String, dynamic>{
      'requestId': fetchRequestId,
      'responseCode': status,
    };
    if (headers != null) {
      params['responseHeaders'] = headers.entries
          .map((e) => {'name': e.key, 'value': e.value})
          .toList();
    }
    if (bodyBytes != null) {
      params['body'] = base64Encode(bodyBytes);
    }
    await session.send('Fetch.fulfillRequest', params);
  }

  @override
  Future<void> abort([String errorCode = 'failed']) async {
    await session.send('Fetch.failRequest', {
      'requestId': fetchRequestId,
      'errorReason':
          RouteErrorCodes.resolve(RouteErrorCodes.chromium, errorCode),
    });
  }
}
