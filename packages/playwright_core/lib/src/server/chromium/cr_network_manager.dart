import 'dart:convert';
import 'package:playwright_protocol/playwright_protocol.dart';
import '../core_request.dart';
import '../core_response.dart';

class CrRequest with CoreRequestState implements CoreRequest {
  final Map<String, dynamic> params;
  CrRequest(this.params);

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
  String? get postData => _request['postData'] as String?;

  @override
  List<int>? get postDataBuffer {
    final data = postData;
    return data == null ? null : utf8.encode(data);
  }

  @override
  String get resourceType => normalizeResourceType(params['type'] as String?);

  @override
  bool get isNavigationRequest =>
      resourceType == 'document' && params['frameId'] != null;

  @override
  dynamic get frame => params['frameId'];
}

class CrResponse with CoreResponseState implements CoreResponse {
  final dynamic session;
  final Map<String, dynamic> params;
  final CrRequest _request;
  CrResponse(this.session, this.params, this._request);

  Map<String, dynamic> get _response =>
      params['response'] as Map<String, dynamic>? ?? const {};

  @override
  CoreRequest get request => _request;

  @override
  Future<List<int>> body() async {
    final result = await session.send('Network.getResponseBody', {
      'requestId': params['requestId'],
    });
    final data = result['body'] as String? ?? '';
    return result['base64Encoded'] == true
        ? base64Decode(data)
        : utf8.encode(data);
  }

  @override
  Future<String?> finished() => _request.finished();

  @override
  String get url => _response['url'] as String? ?? '';

  @override
  int get status => _response['status'] as int? ?? 200;

  @override
  String get statusText => _response['statusText'] as String? ?? '';

  @override
  bool get ok => status >= 200 && status < 300;

  @override
  Map<String, String> get headers {
    final h = _response['headers'];
    if (h is! Map) return const <String, String>{};
    return h.map((key, value) => MapEntry('$key', '$value'));
  }
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
    final requestId = params['requestId'] as String?;

    // A redirect reuses the same requestId: the hop that produced it is
    // finished here and the new hop is linked to it, which is what builds the
    // redirectedFrom/redirectedTo chain.
    CrRequest? previous;
    if (params['redirectResponse'] != null && requestId != null) {
      previous = _requests.remove(requestId);
      if (previous != null) {
        previous.response = CrResponse(
            session, {...params, 'response': params['redirectResponse']}, previous);
        emit('response', previous.response);
        previous.markFinished();
        emit('requestFinished', previous);
      }
    }

    final req = CrRequest(params);
    if (previous != null) req.linkRedirect(previous);
    if (requestId != null) _requests[requestId] = req;
    emit('request', req);
  }

  void _onResponseReceived(Map<String, dynamic> params) {
    final requestId = params['requestId'] as String?;
    final req = requestId != null ? _requests[requestId] : null;
    if (req == null) return;
    final res = CrResponse(session, params, req);
    final response = params['response'] as Map<String, dynamic>? ?? const {};

    final ip = response['remoteIPAddress'];
    final port = response['remotePort'];
    if (ip is String && port is num) {
      res.remoteAddr =
          CoreRemoteAddr(ipAddress: ip, port: port.toInt());
    }
    final security = response['securityDetails'];
    if (security is Map) {
      res.securityDetails = CoreSecurityDetails(
        protocol: security['protocol'] as String?,
        subjectName: security['subjectName'] as String?,
        issuer: security['issuer'] as String?,
        validFrom: (security['validFrom'] as num?)?.toDouble(),
        validTo: (security['validTo'] as num?)?.toDouble(),
      );
    }
    res.fromServiceWorker = response['fromServiceWorker'] == true;

    req.timing = _timingFrom(response, req);
    req.response = res;
    emit('response', res);
  }

  /// Ports `crNetworkManager.ts:385`. CDP reports phases in milliseconds
  /// relative to `requestTime`, which is a monotonic clock; the epoch start
  /// comes from the wall time on the requestWillBeSent event.
  CoreResourceTiming _timingFrom(
      Map<String, dynamic> response, CrRequest request) {
    final wallTime = (request.params['wallTime'] as num?)?.toDouble();
    final timestamp = (request.params['timestamp'] as num?)?.toDouble();
    final timing = response['timing'];
    if (timing is! Map || wallTime == null || timestamp == null) {
      return CoreResourceTiming(
          startTime: wallTime == null ? -1 : wallTime * 1000);
    }
    double at(String name) => (timing[name] as num?)?.toDouble() ?? -1;
    final requestTime = (timing['requestTime'] as num?)?.toDouble() ?? 0;
    return CoreResourceTiming(
      startTime: (requestTime - timestamp + wallTime) * 1000,
      domainLookupStart: at('dnsStart'),
      domainLookupEnd: at('dnsEnd'),
      connectStart: at('connectStart'),
      secureConnectionStart: at('sslStart'),
      connectEnd: at('connectEnd'),
      requestStart: at('sendStart'),
      responseStart: at('receiveHeadersEnd'),
    );
  }

  void _onLoadingFinished(Map<String, dynamic> params) {
    final requestId = params['requestId'] as String?;
    final req = requestId != null ? _requests.remove(requestId) : null;
    if (req == null) return;
    final transferSize = (params['encodedDataLength'] as num?)?.toInt() ?? -1;
    req.sizes = CoreResourceSizes(
      requestBodySize: req.postDataBuffer?.length ?? 0,
      responseBodySize: transferSize,
      transferSize: transferSize,
    );
    req.markFinished();
    emit('requestFinished', req);
  }

  void _onLoadingFailed(Map<String, dynamic> params) {
    final requestId = params['requestId'] as String?;
    final req = requestId != null ? _requests.remove(requestId) : null;
    if (req == null) return;
    req.markFinished(params['errorText'] as String? ??
        params['blockedReason'] as String? ??
        'net::ERR_FAILED');
    emit('requestFailed', req);
  }
}
