import 'dart:convert';
import 'package:playwright_protocol/playwright_protocol.dart';
import '../core_request.dart';
import '../core_response.dart';

/// Maps Juggler's nsIContentPolicy cause strings onto the upstream resource
/// vocabulary. Ported from `ffNetworkManager.ts:185`; Firefox is the one
/// engine with no `type` field on the request event.
const _causeToResourceType = <String, String>{
  'TYPE_INVALID': 'other',
  'TYPE_OTHER': 'other',
  'TYPE_SCRIPT': 'script',
  'TYPE_IMAGE': 'image',
  'TYPE_STYLESHEET': 'stylesheet',
  'TYPE_OBJECT': 'other',
  'TYPE_DOCUMENT': 'document',
  'TYPE_SUBDOCUMENT': 'document',
  'TYPE_REFRESH': 'document',
  'TYPE_XBL': 'other',
  'TYPE_PING': 'ping',
  'TYPE_XMLHTTPREQUEST': 'xhr',
  'TYPE_OBJECT_SUBREQUEST': 'other',
  'TYPE_DTD': 'other',
  'TYPE_FONT': 'font',
  'TYPE_MEDIA': 'media',
  'TYPE_WEBSOCKET': 'websocket',
  'TYPE_CSP_REPORT': 'cspreport',
  'TYPE_XSLT': 'other',
  'TYPE_BEACON': 'beacon',
  'TYPE_FETCH': 'fetch',
  'TYPE_IMAGESET': 'image',
  'TYPE_WEB_MANIFEST': 'manifest',
};

const _internalCauseToResourceType = <String, String>{
  'TYPE_INTERNAL_EVENTSOURCE': 'eventsource',
};

/// A network request reported by Juggler.
class FfRequest with CoreRequestState implements CoreRequest {
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
    final bytes = postDataBuffer;
    if (bytes == null) return null;
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return params['postData'] as String?;
    }
  }

  @override
  List<int>? get postDataBuffer {
    final body = params['postData'] as String?;
    if (body == null) return null;
    // Juggler reports request bodies base64-encoded.
    try {
      return base64Decode(body);
    } catch (_) {
      return utf8.encode(body);
    }
  }

  @override
  String get resourceType {
    final internal = params['internalCause'] as String?;
    final mapped = _internalCauseToResourceType[internal] ??
        _causeToResourceType[params['cause'] as String?];
    return normalizeResourceType(mapped);
  }

  @override
  bool get isNavigationRequest =>
      resourceType == 'document' && params['frameId'] != null;

  @override
  dynamic get frame => params['frameId'];
}

/// A network response reported by Juggler.
class FfResponse with CoreResponseState implements CoreResponse {
  final dynamic session;
  final Map<String, dynamic> params;
  final FfRequest _request;
  FfResponse(this.session, this.params, this._request);

  @override
  CoreRequest get request => _request;

  @override
  Future<List<int>> body() async {
    final result = await session.send('Network.getResponseBody', {
      'requestId': params['requestId'],
    });
    return base64Decode(result['base64body'] as String? ?? '');
  }

  @override
  Future<String?> finished() => _request.finished();

  @override
  String get url => _request.url;

  @override
  int get status => params['status'] as int? ?? 200;

  @override
  String get statusText => params['statusText'] as String? ?? '';

  @override
  bool get ok => status >= 200 && status < 300;

  @override
  Map<String, String> get headers {
    final list = params['headers'];
    if (list is! List) return const <String, String>{};
    return {
      for (final entry in list.cast<Map>())
        '${entry['name']}': '${entry['value']}',
    };
  }
}

/// Juggler already reports headers as a `{name, value}` list, so there is
/// nothing to split here — unlike CDP and WebKit, which report an object.
List<({String name, String value})> _headersArray(dynamic headers) {
  if (headers is! List) return const [];
  return [
    for (final entry in headers)
      if (entry is Map) (name: '${entry['name']}', value: '${entry['value']}'),
  ];
}

/// Tracks network requests and responses in Firefox (Juggler).
class FfNetworkManager extends EventEmitter {
  final dynamic session;
  final _requests = <String, FfRequest>{};

  /// Ids of requests that already finished, oldest first. Juggler can report
  /// a redirect's new hop *after* finishing the old one, so a finished
  /// request has to stay reachable long enough to be linked; this bounds how
  /// long.
  final _completed = <String>[];

  /// Ids of the requests that are WebSocket handshakes.
  ///
  /// Juggler is the only engine that reports the handshake as an ordinary
  /// network request. Upstream filters it out here, "to align with Chromium
  /// and WebKit" (`ffNetworkManager.ts:71`), and forwards the pieces to the
  /// page instead — which is also the only way Firefox learns the handshake
  /// headers, since `Page.webSocketOpened` does not carry them.
  final _webSocketRequestIds = <String>{};

  FfNetworkManager(this.session) {
    session.on('Network.requestWillBeSent', _onRequestWillBeSent);
    session.on('Network.responseReceived', _onResponseReceived);
    session.on('Network.requestFinished', _onRequestFinished);
    session.on('Network.requestFailed', _onRequestFailed);
  }

  void _onRequestWillBeSent(Map<String, dynamic> params) {
    final requestIdRaw = params['requestId'] as String?;
    if (params['cause'] == 'TYPE_WEBSOCKET' && requestIdRaw != null) {
      _webSocketRequestIds.add(requestIdRaw);
      emit('webSocketRequestWillBeSent', (
        requestId: requestIdRaw,
        url: params['url'] as String? ?? '',
        headers: _headersArray(params['headers']),
      ));
      return;
    }
    final req = FfRequest(params);
    // Juggler names the previous hop explicitly, under a different requestId.
    final redirectedFrom = params['redirectedFrom'] as String?;
    if (redirectedFrom != null) {
      final previous = _requests.remove(redirectedFrom);
      if (previous != null) req.linkRedirect(previous);
    }
    final requestId = params['requestId'] as String?;
    if (requestId != null) _requests[requestId] = req;
    emit('request', req);
  }

  void _onResponseReceived(Map<String, dynamic> params) {
    final requestId = params['requestId'] as String?;
    final req = requestId != null ? _requests[requestId] : null;
    if (req == null) {
      if (requestId != null && _webSocketRequestIds.contains(requestId)) {
        emit('webSocketResponseReceived', (
          requestId: requestId,
          status: (params['status'] as num?)?.toInt() ?? 0,
          statusText: params['statusText'] as String? ?? '',
          headers: _headersArray(params['headers']),
        ));
      }
      return;
    }
    final res = FfResponse(session, params, req);

    final ip = params['remoteIPAddress'];
    final port = params['remotePort'];
    if (ip is String && port is num) {
      res.remoteAddr = CoreRemoteAddr(ipAddress: ip, port: port.toInt());
    }
    final security = params['securityDetails'];
    if (security is Map) {
      res.securityDetails = CoreSecurityDetails(
        protocol: security['protocol'] as String?,
        subjectName: security['subjectName'] as String?,
        issuer: security['issuer'] as String?,
        validFrom: (security['validFrom'] as num?)?.toDouble(),
        validTo: (security['validTo'] as num?)?.toDouble(),
      );
    }

    req.timing = _timingFrom(params['timing']);
    req.response = res;
    emit('response', res);
  }

  /// Juggler reports absolute microseconds; upstream converts to milliseconds
  /// and makes every phase relative to the start (`ffNetworkManager.ts:102`).
  CoreResourceTiming _timingFrom(dynamic timing) {
    if (timing is! Map) return const CoreResourceTiming();
    final start = (timing['startTime'] as num?)?.toDouble() ?? 0;
    double relative(String name) {
      final value = (timing[name] as num?)?.toDouble();
      if (value == null || value == 0) return -1;
      return (value - start) / 1000;
    }

    return CoreResourceTiming(
      startTime: start / 1000,
      domainLookupStart: relative('domainLookupStart'),
      domainLookupEnd: relative('domainLookupEnd'),
      connectStart: relative('connectStart'),
      secureConnectionStart: relative('secureConnectionStart'),
      connectEnd: relative('connectEnd'),
      requestStart: relative('requestStart'),
      responseStart: relative('responseStart'),
    );
  }

  void _retire(String requestId) {
    _completed.add(requestId);
    while (_completed.length > 100) {
      _requests.remove(_completed.removeAt(0));
    }
  }

  void _onRequestFinished(Map<String, dynamic> params) {
    final requestId = params['requestId'] as String?;
    final req = requestId != null ? _requests[requestId] : null;
    if (req == null) {
      if (requestId != null && _webSocketRequestIds.remove(requestId)) {
        emit('webSocketRequestFinished', (requestId: requestId));
      }
      return;
    }
    if (requestId != null) _retire(requestId);
    req.sizes = CoreResourceSizes(
      requestBodySize: req.postDataBuffer?.length ?? 0,
      responseBodySize: (params['encodedBodySize'] as num?)?.toInt() ?? -1,
      transferSize: (params['transferSize'] as num?)?.toInt() ?? -1,
      // Firefox reports no header sizes at all.
    );
    req.markFinished();
    emit('requestFinished', req);
  }

  void _onRequestFailed(Map<String, dynamic> params) {
    final requestId = params['requestId'] as String?;
    final req = requestId != null ? _requests[requestId] : null;
    if (requestId != null) _retire(requestId);
    if (req == null) return;
    req.markFinished(params['errorCode'] as String? ?? 'NS_ERROR_FAILURE');
    emit('requestFailed', req);
  }
}
