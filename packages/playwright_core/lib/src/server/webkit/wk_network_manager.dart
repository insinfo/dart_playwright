import 'dart:convert';
import 'package:playwright_protocol/playwright_protocol.dart';
import '../core_request.dart';
import '../core_response.dart';

/// A network request reported by the WebKit Network domain.
class WkRequest with CoreRequestState implements CoreRequest {
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
    final bytes = postDataBuffer;
    if (bytes == null) return null;
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return _request['postData'] as String?;
    }
  }

  @override
  List<int>? get postDataBuffer {
    final body = _request['postData'] as String?;
    if (body == null) return null;
    // WebKit reports request bodies base64-encoded.
    try {
      return base64Decode(body);
    } catch (_) {
      return utf8.encode(body);
    }
  }

  @override
  String get resourceType {
    final type = params['type'] as String?;
    // WebKit's Page.ResourceType spells a few of them differently.
    switch (type) {
      case 'Document':
        return 'document';
      case 'Stylesheet':
        return 'stylesheet';
      case 'Image':
        return 'image';
      case 'Font':
        return 'font';
      case 'Script':
        return 'script';
      case 'XHR':
        return 'xhr';
      case 'Fetch':
        return 'fetch';
      case 'Ping':
        return 'ping';
      case 'Beacon':
        return 'beacon';
      case 'WebSocket':
        return 'websocket';
      case 'EventSource':
        return 'eventsource';
      case 'Media':
        return 'media';
      default:
        return normalizeResourceType(type);
    }
  }

  @override
  bool get isNavigationRequest =>
      resourceType == 'document' && params['frameId'] != null;

  @override
  dynamic get frame => params['frameId'];
}

/// A network response reported by the WebKit Network domain.
class WkResponse with CoreResponseState implements CoreResponse {
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

  @override
  Future<String?> finished() => _request.finished();

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

  @override
  Map<String, String> get headers {
    final h = _response['headers'];
    if (h is! Map) return const <String, String>{};
    return h.map((key, value) => MapEntry('$key', '$value'));
  }
}

/// Tracks network requests and responses in WebKit.
///
/// Events arrive unwrapped on the pageProxy session; the Network domain
/// must be enabled on the page target for them to flow.
class WkNetworkManager extends EventEmitter {
  final dynamic session;
  final _requests = <String, WkRequest>{};

  /// The `responseReceived` payload per request id, kept because WebKit only
  /// reports the address and the certificate at `loadingFinished`, while the
  /// certificate subject came with the response.
  final _responsePayloads = <String, Map<String, dynamic>>{};

  WkNetworkManager(this.session) {
    session.on('Network.requestWillBeSent', _onRequestWillBeSent);
    session.on('Network.responseReceived', _onResponseReceived);
    session.on('Network.loadingFinished', _onLoadingFinished);
    session.on('Network.loadingFailed', _onLoadingFailed);
  }

  void _onRequestWillBeSent(Map<String, dynamic> params) {
    final requestId = params['requestId'] as String?;

    // Like Chromium, WebKit reuses the request id across a redirect and
    // announces the previous hop's response inline.
    WkRequest? previous;
    if (params['redirectResponse'] != null && requestId != null) {
      previous = _requests.remove(requestId);
      if (previous != null) {
        previous.response = WkResponse(session,
            {...params, 'response': params['redirectResponse']}, previous);
        emit('response', previous.response);
        previous.markFinished();
        emit('requestFinished', previous);
      }
    }

    final req = WkRequest(params);
    if (previous != null) req.linkRedirect(previous);
    if (requestId != null) _requests[requestId] = req;
    emit('request', req);
  }

  void _onResponseReceived(Map<String, dynamic> params) {
    final requestId = params['requestId'] as String?;
    final req = requestId != null ? _requests[requestId] : null;
    if (req == null) return;
    if (requestId != null) _responsePayloads[requestId] = params;
    final res = WkResponse(session, params, req);
    req.timing = _timingFrom(
        (params['response'] as Map<String, dynamic>?)?['timing'], params);
    req.response = res;
    emit('response', res);
  }

  /// WebKit's ResourceTiming is already relative to the fetch start, but it
  /// says `-1000` for "not measured" (upstream calls this out in
  /// `wkInterceptableRequest.ts:161`), and the epoch start comes from the
  /// request event's wall time rather than the timing block.
  CoreResourceTiming _timingFrom(dynamic timing, Map<String, dynamic> params) {
    final wallTime = (params['walltime'] as num?)?.toDouble();
    final startTime = wallTime == null ? -1.0 : wallTime * 1000;
    if (timing is! Map) return CoreResourceTiming(startTime: startTime);
    double at(String name) {
      final value = (timing[name] as num?)?.toDouble();
      if (value == null || value <= 0) return -1;
      return value;
    }

    return CoreResourceTiming(
      startTime: startTime,
      domainLookupStart: at('domainLookupStart'),
      domainLookupEnd: at('domainLookupEnd'),
      connectStart: at('connectStart'),
      secureConnectionStart: at('secureConnectionStart'),
      connectEnd: at('connectEnd'),
      requestStart: at('requestStart'),
      responseStart: at('responseStart'),
    );
  }

  void _onLoadingFinished(Map<String, dynamic> params) {
    final requestId = params['requestId'] as String?;
    final req = requestId != null ? _requests.remove(requestId) : null;
    final responsePayload =
        requestId != null ? _responsePayloads.remove(requestId) : null;
    if (req == null) return;

    final metrics = params['metrics'];
    if (metrics is Map) {
      req.sizes = CoreResourceSizes(
        requestBodySize: req.postDataBuffer?.length ?? 0,
        responseBodySize:
            (metrics['responseBodyBytesReceived'] as num?)?.toInt() ?? -1,
        responseHeadersSize:
            (metrics['responseHeaderBytesReceived'] as num?)?.toInt() ?? -1,
        // WebKit reports no transfer size.
      );
      final response = req.response;
      if (response is WkResponse) {
        final remote = metrics['remoteAddress'] as String?;
        final parsed = _parseRemoteAddress(remote);
        if (parsed != null) response.remoteAddr = parsed;
        final connection = metrics['securityConnection'];
        final certificate = ((responsePayload?['response']
            as Map<String, dynamic>?)?['security'] as Map?)?['certificate'];
        if (connection is Map || certificate is Map) {
          response.securityDetails = CoreSecurityDetails(
            protocol:
                connection is Map ? connection['protocol'] as String? : null,
            subjectName:
                certificate is Map ? certificate['subject'] as String? : null,
            // WebKit does not report the certificate issuer.
            validFrom: certificate is Map
                ? (certificate['validFrom'] as num?)?.toDouble()
                : null,
            validTo: certificate is Map
                ? (certificate['validUntil'] as num?)?.toDouble()
                : null,
          );
        }
      }
    }
    req.markFinished();
    emit('requestFinished', req);
  }

  /// `host:port`, with IPv6 hosts in brackets.
  CoreRemoteAddr? _parseRemoteAddress(String? address) {
    if (address == null || address.isEmpty) return null;
    final separator = address.lastIndexOf(':');
    if (separator == -1) return null;
    final port = int.tryParse(address.substring(separator + 1));
    if (port == null) return null;
    var host = address.substring(0, separator);
    if (host.startsWith('[') && host.endsWith(']')) {
      host = host.substring(1, host.length - 1);
    }
    return CoreRemoteAddr(ipAddress: host, port: port);
  }

  void _onLoadingFailed(Map<String, dynamic> params) {
    final requestId = params['requestId'] as String?;
    final req = requestId != null ? _requests.remove(requestId) : null;
    if (requestId != null) _responsePayloads.remove(requestId);
    if (req == null) return;
    req.markFinished(params['errorText'] as String? ?? 'Failed');
    emit('requestFailed', req);
  }
}
