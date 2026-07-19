import 'package:playwright_protocol/playwright_protocol.dart';
import '../core_request.dart';
import '../core_response.dart';

class CrRequest implements CoreRequest {
  final Map<String, dynamic> params;
  CrRequest(this.params);

  @override
  String get url => params['request']?['url'] ?? '';

  @override
  String get method => params['request']?['method'] ?? '';

  @override
  Map<String, String> get headers {
    final h = params['request']?['headers'] as Map?;
    return h?.cast<String, String>() ?? {};
  }

  @override
  String? get postData => params['request']?['postData'] as String?;

  @override
  dynamic get frame => params['frameId'];
}

class CrResponse implements CoreResponse {
  final Map<String, dynamic> params;
  final CrRequest _request;
  CrResponse(this.params, this._request);

  @override
  CoreRequest get request => _request;

  @override
  String get url => params['response']?['url'] ?? '';

  @override
  int get status => params['response']?['status'] ?? 200;

  @override
  String get statusText => params['response']?['statusText'] ?? '';

  @override
  bool get ok => status >= 200 && status < 300;
}

/// Tracks network requests and responses in Chromium.
class CrNetworkManager extends EventEmitter {
  final dynamic session;
  final _requests = <String, CrRequest>{};

  CrNetworkManager(this.session) {
    session.on('Network.requestWillBeSent', _onRequestWillBeSent);
    session.on('Network.responseReceived', _onResponseReceived);
    session.on('Network.loadingFinished', _onLoadingFinished);
    session.on('Network.loadingFailed', _onLoadingFailed);
  }

  void _onRequestWillBeSent(Map<String, dynamic> params) {
    final req = CrRequest(params);
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
      final res = CrResponse(params, req);
      emit('response', res);
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
