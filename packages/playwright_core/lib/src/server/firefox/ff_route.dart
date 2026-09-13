import 'dart:convert';
import '../core_route.dart';
import '../core_request.dart';

/// Implementation of network interception for Firefox (Juggler).
class FfRoute implements CoreRoute {
  final dynamic session;
  final String requestId;
  final String url;
  final String method;
  final Map<String, String> headers;
  late final CoreRequest _request;

  /// Called when the handler declines the route with [fallback].
  @override
  void Function()? onFallback;

  FfRoute(this.session, this.requestId, this.url,
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
    await session.send('Network.resumeInterceptedRequest', {
      'requestId': requestId,
      if (url != null) 'url': url,
      if (method != null) 'method': method,
      if (headers != null)
        'headers': headers.entries
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
    await session.send('Network.fulfillInterceptedRequest', {
      'requestId': requestId,
      'status': status,
      'statusText': 'OK',
      'headers': (headers ?? {})
          .entries
          .map((e) => {'name': e.key, 'value': e.value})
          .toList(),
      if (bodyBytes != null) 'base64body': base64Encode(bodyBytes),
    });
  }

  @override
  Future<void> abort([String errorCode = 'failed']) async {
    // Juggler takes the API spelling verbatim; upstream has no mapping table
    // for Firefox (ffNetworkManager.ts:272).
    await session.send('Network.abortInterceptedRequest', {
      'requestId': requestId,
      'errorCode': errorCode,
    });
  }
}
