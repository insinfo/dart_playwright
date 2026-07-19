import 'dart:convert';
import 'wk_connection.dart';

/// Implementation of network interception for WebKit.
///
/// Requests paused by `Network.addInterception` arrive as
/// `Network.requestIntercepted` events and are answered with the
/// `Network.intercept*` family of commands on the page target.
class WkRoute {
  final WkPageProxySession session;
  final String requestId;
  final String url;

  WkRoute(this.session, this.requestId, this.url);

  Future<void> continue_() async {
    await session.sendToTarget('Network.interceptContinue', {
      'requestId': requestId,
      'stage': 'request',
    });
  }

  Future<void> fulfill({int status = 200, Map<String, String>? headers, List<int>? bodyBytes}) async {
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

  Future<void> abort([String errorCode = 'General']) async {
    await session.sendToTarget('Network.interceptRequestWithError', {
      'requestId': requestId,
      'errorType': errorCode,
    });
  }
}
