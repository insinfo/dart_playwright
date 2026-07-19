import 'dart:convert';

/// Implementation of network interception for Chromium.
class CrRoute {
  final dynamic session;
  final String fetchRequestId;
  final String url;
  
  CrRoute(this.session, this.fetchRequestId, this.url);
  
  Future<void> continue_() async {
    await session.send('Fetch.continueRequest', {
      'requestId': fetchRequestId,
    });
  }
  
  Future<void> fulfill({int status = 200, Map<String, String>? headers, List<int>? bodyBytes}) async {
    final params = <String, dynamic>{
      'requestId': fetchRequestId,
      'responseCode': status,
    };
    if (headers != null) {
      params['responseHeaders'] = headers.entries.map((e) => {'name': e.key, 'value': e.value}).toList();
    }
    if (bodyBytes != null) {
      params['body'] = base64Encode(bodyBytes);
    }
    await session.send('Fetch.fulfillRequest', params);
  }
  
  Future<void> abort([String errorCode = 'Failed']) async {
    await session.send('Fetch.failRequest', {
      'requestId': fetchRequestId,
      'errorReason': errorCode,
    });
  }
}
