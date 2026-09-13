import 'dart:async';

import 'core_response.dart';

/// The resource types upstream documents for `Request.resourceType()`.
///
/// Every engine reports its own vocabulary; the drivers normalize onto this
/// list, falling back to `other` for anything they do not recognize.
const kResourceTypes = <String>[
  'document',
  'stylesheet',
  'image',
  'media',
  'font',
  'script',
  'texttrack',
  'xhr',
  'fetch',
  'eventsource',
  'websocket',
  'manifest',
  'beacon',
  'ping',
  'cspreport',
  'other',
];

/// Network timings for one request.
///
/// [startTime] is milliseconds since the epoch; every other field is
/// milliseconds relative to [startTime], or `-1` when the engine does not
/// report it. Matching upstream, the engines that cannot measure a phase say
/// `-1` rather than pretending it was instantaneous.
class CoreResourceTiming {
  final double startTime;
  final double domainLookupStart;
  final double domainLookupEnd;
  final double connectStart;
  final double secureConnectionStart;
  final double connectEnd;
  final double requestStart;
  final double responseStart;

  const CoreResourceTiming({
    this.startTime = -1,
    this.domainLookupStart = -1,
    this.domainLookupEnd = -1,
    this.connectStart = -1,
    this.secureConnectionStart = -1,
    this.connectEnd = -1,
    this.requestStart = -1,
    this.responseStart = -1,
  });
}

/// Byte counts for one request/response pair.
///
/// A field is `-1` when the engine does not report it: Firefox has no header
/// sizes at all and WebKit has no transfer size, and saying `-1` is more
/// honest than saying `0`.
class CoreResourceSizes {
  final int requestBodySize;
  final int requestHeadersSize;
  final int responseBodySize;
  final int responseHeadersSize;
  final int transferSize;

  const CoreResourceSizes({
    this.requestBodySize = 0,
    this.requestHeadersSize = -1,
    this.responseBodySize = -1,
    this.responseHeadersSize = -1,
    this.transferSize = -1,
  });
}

/// The TLS certificate a secure response was served with.
class CoreSecurityDetails {
  final String? protocol;
  final String? subjectName;
  final String? issuer;
  final double? validFrom;
  final double? validTo;

  const CoreSecurityDetails({
    this.protocol,
    this.subjectName,
    this.issuer,
    this.validFrom,
    this.validTo,
  });
}

/// The address a response was actually served from.
class CoreRemoteAddr {
  final String ipAddress;
  final int port;

  const CoreRemoteAddr({required this.ipAddress, required this.port});
}

/// Represents a network request in the core engine.
abstract class CoreRequest {
  String get url;
  String get method;

  /// Headers as the engine first reported them, before the network stack had
  /// its say. [rawHeaders] carries what actually went on the wire, when the
  /// engine can tell.
  Map<String, String> get headers;

  /// The headers actually sent, or null when the engine does not report them
  /// separately (Firefox never does), in which case [headers] is the best
  /// answer available.
  Map<String, String>? get rawHeaders;

  /// Request body for POST-like requests, when the protocol reports it.
  String? get postData;

  /// The raw request body bytes, when the protocol reports them.
  List<int>? get postDataBuffer;

  /// One of [kResourceTypes].
  String get resourceType;

  /// Whether this request is driving a frame navigation.
  bool get isNavigationRequest;

  dynamic
      get frame; // Frame is not fully decoupled yet, so dynamic or CoreFrame later

  /// The error text when the request failed, or null while it has not.
  String? get failure;

  /// The response, once one arrived.
  CoreResponse? get response;

  /// The request that redirected to this one, if any.
  CoreRequest? get redirectedFrom;

  /// The request this one redirected to, if any.
  CoreRequest? get redirectedTo;

  /// Network timings, available once the response headers arrived.
  CoreResourceTiming get timing;

  /// Byte counts, available once the request finished.
  CoreResourceSizes get sizes;

  /// Completes when the request finished, successfully or not, yielding the
  /// failure text on failure and null on success.
  Future<String?> finished();
}

/// The parts of a request the engine fills in as later events arrive.
///
/// A request object is created when the engine announces it and then keeps
/// being written to: the response, the failure, the redirect chain and the
/// sizes are all known later. Keeping them here means every engine gets the
/// same lifecycle without repeating the fields.
mixin CoreRequestState {
  final Completer<String?> _finished = Completer<String?>();

  /// When this object was built, used as the start time on engines that do
  /// not report one. Juggler only sends a timing block for some requests, and
  /// "when the driver first saw it" is a more useful answer than -1.
  final DateTime observedAt = DateTime.now();

  String? failure;
  CoreResponse? response;
  CoreRequest? redirectedFrom;
  CoreRequest? redirectedTo;
  Map<String, String>? rawHeaders;
  CoreResourceTiming _timing = const CoreResourceTiming();

  CoreResourceTiming get timing => _timing.startTime >= 0
      ? _timing
      : CoreResourceTiming(
          startTime: observedAt.millisecondsSinceEpoch.toDouble(),
          domainLookupStart: _timing.domainLookupStart,
          domainLookupEnd: _timing.domainLookupEnd,
          connectStart: _timing.connectStart,
          secureConnectionStart: _timing.secureConnectionStart,
          connectEnd: _timing.connectEnd,
          requestStart: _timing.requestStart,
          responseStart: _timing.responseStart,
        );

  set timing(CoreResourceTiming value) => _timing = value;
  CoreResourceSizes sizes = const CoreResourceSizes();

  /// Completes when the request finished, successfully or not.
  Future<String?> finished() => _finished.future;

  /// Records the end of the request. [failureText] is null on success.
  ///
  /// Called at most once per request; a redirect ends the hop that produced
  /// it, and the next hop is a request of its own.
  void markFinished([String? failureText]) {
    if (failureText != null) failure = failureText;
    if (!_finished.isCompleted) _finished.complete(failureText);
  }

  /// Links this request to the one it redirected from, in both directions.
  void linkRedirect(CoreRequest previous) {
    redirectedFrom = previous;
    final state = previous;
    if (state is CoreRequestState) {
      (state as CoreRequestState).redirectedTo = this as CoreRequest;
    }
  }
}

/// Normalizes an engine's resource type onto [kResourceTypes].
String normalizeResourceType(String? raw) {
  if (raw == null || raw.isEmpty) return 'other';
  final lower = raw.toLowerCase();
  if (kResourceTypes.contains(lower)) return lower;
  switch (lower) {
    case 'stylesheet':
    case 'css':
      return 'stylesheet';
    case 'xhr':
    case 'xmlhttprequest':
      return 'xhr';
    case 'textrack':
      return 'texttrack';
    // Chromium's Prefetch / SignedExchange / Preflight / FedCM and WebKit's
    // Ping all land here, as they do upstream.
    default:
      return 'other';
  }
}

class BasicCoreRequest with CoreRequestState implements CoreRequest {
  @override
  final String url;

  @override
  final String method;

  @override
  final Map<String, String> headers;

  @override
  final String? postData;

  @override
  final List<int>? postDataBuffer;

  @override
  final String resourceType;

  @override
  final bool isNavigationRequest;

  @override
  final dynamic frame;

  BasicCoreRequest({
    required this.url,
    this.method = 'GET',
    Map<String, String>? headers,
    this.postData,
    this.postDataBuffer,
    this.resourceType = 'other',
    this.isNavigationRequest = false,
    this.frame,
  }) : headers = headers ?? const <String, String>{};
}
