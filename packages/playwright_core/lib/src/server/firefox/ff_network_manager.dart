import 'dart:convert';
import 'package:playwright_protocol/playwright_protocol.dart';
import '../core_request.dart';
import '../core_response.dart';

/// A network request reported by Juggler.
class FfRequest implements CoreRequest {
  final Map<String, dynamic> params;
  FfRequest(this.params);

  @override
  String get url => params['url'] as String? ?? '';

  @override
  String get method => params['method'] as String? ?? '';

  @override
  Map<String, String> get headers {
    final list = params['headers'];
    if (list is! List) return const <String, String>{};
    return {
      for (final entry in list.cast<Map>())
        '${entry['name']}': '${entry['value']}',
    };
  }

  @override
  String? get postData {
    final body = params['postData'] as String?;
    if (body == null) return null;
    // Juggler reports request bodies base64-encoded.
    try {
      return utf8.decode(base64Decode(body));
    } catch (_) {
      return body;
    }
  }

  @override
  dynamic get frame => params['frameId'];
}

/// A network response reported by Juggler.
class FfResponse implements CoreResponse {
  final Map<String, dynamic> params;
  final FfRequest _request;
  FfResponse(this.params, this._request);

  @override
  CoreRequest get request => _request;

  @override
  String get url => _request.url;

  @override
  int get status => params['status'] as int? ?? 200;

  @override
  String get statusText => params['statusText'] as String? ?? '';

  @override
  bool get ok => status >= 200 && status < 300;
}

/// Tracks network requests and responses in Firefox (Juggler).
class FfNetworkManager extends EventEmitter {
  final dynamic session;
  final _requests = <String, FfRequest>{};

  FfNetworkManager(this.session) {
    session.on('Network.requestWillBeSent', _onRequestWillBeSent);
    session.on('Network.responseReceived', _onResponseReceived);
    session.on('Network.requestFinished', _onRequestFinished);
    session.on('Network.requestFailed', _onRequestFailed);
  }

  void _onRequestWillBeSent(Map<String, dynamic> params) {
    final req = FfRequest(params);
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
      emit('response', FfResponse(params, req));
    }
  }

  void _onRequestFinished(Map<String, dynamic> params) {
    final requestId = params['requestId'] as String?;
    final req = requestId != null ? _requests[requestId] : null;
    if (req != null) {
      emit('requestFinished', req);
    }
  }

  void _onRequestFailed(Map<String, dynamic> params) {
    final requestId = params['requestId'] as String?;
    final req = requestId != null ? _requests[requestId] : null;
    if (req != null) {
      emit('requestFailed', req);
    }
  }
}
