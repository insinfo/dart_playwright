import 'dart:convert';

/// Implementation of network interception for Firefox (Juggler).
class FfRoute {
  final dynamic session;
  final String requestId;
  final String url;

  FfRoute(this.session, this.requestId, this.url);

  Future<void> continue_() async {
    await session.send('Network.resumeInterceptedRequest', {
      'requestId': requestId,
    });
  }

  Future<void> fulfill({int status = 200, Map<String, String>? headers, List<int>? bodyBytes}) async {
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

  Future<void> abort([String errorCode = 'NS_ERROR_FAILURE']) async {
    await session.send('Network.abortInterceptedRequest', {
      'requestId': requestId,
      'errorCode': errorCode,
    });
  }
}
