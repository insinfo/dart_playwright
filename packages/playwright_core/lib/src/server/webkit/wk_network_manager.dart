import 'dart:convert';
import 'package:playwright_protocol/playwright_protocol.dart';
import '../core_request.dart';
import '../core_response.dart';

/// A network request reported by the WebKit Network domain.
class WkRequest implements CoreRequest {
  final Map<String, dynamic> params;
  WkRequest(this.params);

  Map<String, dynamic> get _request =>
      params['request'] as Map<String, dynamic>? ?? const {};

  @override
  String get url => _request['url'] as String? ?? '';

  @override
  String get method => _request['method'] as String? ?? '';

  @override
  Map<String, String> get headers {
    final h = _request['headers'];
    if (h is! Map) return const <String, String>{};
    return h.map((key, value) => MapEntry('$key', '$value'));
  }

  @override
  String? get postData {
    final body = _request['postData'] as String?;
    if (body == null) return null;
    // WebKit reports request bodies base64-encoded.
    try {
      return utf8.decode(base64Decode(body));
    } catch (_) {
      return body;
    }
  }

  @override
  dynamic get frame => params['frameId'];
}

/// A network response reported by the WebKit Network domain.
class WkResponse implements CoreResponse {
  final dynamic session;
  final Map<String, dynamic> params;
  final WkRequest _request;
  WkResponse(this.session, this.params, this._request);

  @override
  Future<List<int>> body() async {
    final result = await session.sendToTarget('Network.getResponseBody', {
      'requestId': params['requestId'],
    });
    final data = result['body'] as String? ?? '';
    return result['base64Encoded'] == true
        ? base64Decode(data)
        : utf8.encode(data);
  }

  Map<String, dynamic> get _response =>
      params['response'] as Map<String, dynamic>? ?? const {};

  @override
  CoreRequest get request => _request;

  @override
  String get url => _response['url'] as String? ?? _request.url;

  @override
  int get status => _response['status'] as int? ?? 200;

  @override
  String get statusText => _response['statusText'] as String? ?? '';

  @override
  bool get ok => status >= 200 && status < 300;
}

/// Tracks network requests and responses in WebKit.
///
/// Events arrive unwrapped on the pageProxy session; the Network domain
/// must be enabled on the page target for them to flow.
class WkNetworkManager extends EventEmitter {
  final dynamic session;
  final _requests = <String, WkRequest>{};

  WkNetworkManager(this.session) {
    session.on('Network.requestWillBeSent', _onRequestWillBeSent);
    session.on('Network.responseReceived', _onResponseReceived);
    session.on('Network.loadingFinished', _onLoadingFinished);
    session.on('Network.loadingFailed', _onLoadingFailed);
  }

  void _onRequestWillBeSent(Map<String, dynamic> params) {
    final req = WkRequest(params);
    final requestId = params['requestId'] as String?;
    if (requestId != null) {
      _requests[requestId] = req;
    }
    emit('request', req);
  }

  void _onResponseReceived(Map<String, dynamic> params) {
    final requestId = params['requestId'] as String?;
    final req = requestId != null ? _requests[requestId] : null;
    if (req != null) {
      emit('response', WkResponse(session, params, req));
    }
  }

  void _onLoadingFinished(Map<String, dynamic> params) {
    final requestId = params['requestId'] as String?;
    final req = requestId != null ? _requests[requestId] : null;
    if (req != null) {
      emit('requestFinished', req);
    }
  }

  void _onLoadingFailed(Map<String, dynamic> params) {
    final requestId = params['requestId'] as String?;
    final req = requestId != null ? _requests[requestId] : null;
    if (req != null) {
      emit('requestFailed', req);
    }
  }
}
