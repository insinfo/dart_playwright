import 'package:playwright_protocol/playwright_protocol.dart';

import 'core_page.dart';

/// One frame that crossed a WebSocket.
///
/// [opcode] is the RFC 6455 opcode: `1` for a text frame and `2` for a binary
/// one. Upstream's client drops every other opcode before the event reaches
/// the API (`client/network.ts:778`), and so does this port, so only those two
/// ever appear here.
///
/// [data] is the payload exactly as the engine reported it: the text for a
/// text frame, base64 for a binary one.
class CoreWebSocketFrame {
  final int opcode;
  final String data;

  /// Milliseconds since the epoch, derived by each engine from its own clock
  /// baseline. It is `-1` when the engine gives no timestamp for the frame.
  final double wallTimeMs;

  const CoreWebSocketFrame({
    required this.opcode,
    required this.data,
    this.wallTimeMs = -1,
  });

  /// Whether this is a text frame (opcode 1) rather than a binary one.
  bool get isText => opcode == 1;
}

/// The handshake request of a WebSocket, as the engine reported it.
class CoreWebSocketRequest {
  final List<({String name, String value})> headers;
  const CoreWebSocketRequest({this.headers = const []});
}

/// The handshake response of a WebSocket, as the engine reported it.
class CoreWebSocketResponse {
  final int status;
  final String statusText;
  final List<({String name, String value})> headers;
  const CoreWebSocketResponse({
    required this.status,
    required this.statusText,
    this.headers = const [],
  });
}

/// A WebSocket opened by the page.
///
/// Port of `server/network.ts#WebSocket`. Events, using upstream's spellings:
/// `framesent` and `framereceived` carry a [CoreWebSocketFrame], `socketerror`
/// carries the error text, and `close` carries nothing. `request` and
/// `response` also exist on the server object upstream — they feed the HAR and
/// the trace, not the public API — and are kept here for the same reason.
class CoreWebSocket extends EventEmitter {
  /// The URL the page asked for, with any fragment removed.
  final String url;

  bool _notified = false;
  bool _isClosed = false;

  /// Milliseconds since the epoch at which the handshake request was sent, or
  /// null when the engine does not report it. Only Chromium and WebKit do.
  double? wallTimeMs;

  CoreWebSocket(String url) : url = stripFragmentFromUrl(url);

  /// Whether the socket has already reported `close`.
  bool get isClosed => _isClosed;

  /// Whether this is the first time the socket is about to be announced.
  ///
  /// Port of `markAsNotified`: Chromium can report `webSocketCreated` twice
  /// for one socket, so the `websocket` event has to be de-duplicated at the
  /// source rather than by whoever is listening.
  bool markAsNotified() {
    if (_notified) return false;
    _notified = true;
    return true;
  }

  void requestSent(List<({String name, String value})> headers) {
    emit('request', CoreWebSocketRequest(headers: headers));
  }

  void responseReceived(int status, String statusText,
      List<({String name, String value})> headers) {
    emit(
        'response',
        CoreWebSocketResponse(
            status: status, statusText: statusText, headers: headers));
  }

  void frameSent(int opcode, String data, double wallTimeMs) {
    emit('framesent',
        CoreWebSocketFrame(opcode: opcode, data: data, wallTimeMs: wallTimeMs));
  }

  void frameReceived(int opcode, String data, double wallTimeMs) {
    emit('framereceived',
        CoreWebSocketFrame(opcode: opcode, data: data, wallTimeMs: wallTimeMs));
  }

  void error(String errorMessage) {
    emit('socketerror', errorMessage);
  }

  void closed() {
    _isClosed = true;
    emit('close', this);
    disposeStreams();
  }
}

/// Removes the fragment from [url]. Port of `stripFragmentFromUrl`.
String stripFragmentFromUrl(String url) {
  final index = url.indexOf('#');
  return index == -1 ? url : url.substring(0, index);
}

/// Expands a protocol header object into the repeated-name array upstream
/// uses. Port of `isomorphic/headers.ts#headersObjectToArray`.
///
/// With a [separator], a value holding several lines becomes several entries,
/// which is how CDP (`\n`) and WebKit (`,`, but `\n` for `set-cookie`) report
/// a header that appeared more than once.
List<({String name, String value})> headersObjectToArray(dynamic headers,
    {String? separator, String? setCookieSeparator}) {
  if (headers is! Map) return const [];
  final result = <({String name, String value})>[];
  for (final entry in headers.entries) {
    final name = '${entry.key}';
    final value = entry.value;
    if (value == null) continue;
    if (separator != null) {
      final sep = name.toLowerCase() == 'set-cookie'
          ? (setCookieSeparator ?? separator)
          : separator;
      for (final part in '$value'.split(sep)) {
        result.add((name: name, value: part.trim()));
      }
    } else {
      result.add((name: name, value: '$value'));
    }
  }
  return result;
}

/// The WebSocket registry of a page.
///
/// Upstream keeps this on the frame manager (`server/frames.ts:431`); here it
/// sits on the page, which is the object that actually emits the event and the
/// one every engine driver already has in hand. The method names and the order
/// of operations are upstream's.
mixin CorePageWebSockets on EventEmitter, CorePageOwnership {
  /// Keyed by whatever request id the engine uses: CDP's `requestId` in
  /// Chromium and WebKit, `frameId---wsid` in Juggler.
  final Map<String, CoreWebSocket> _webSockets = <String, CoreWebSocket>{};

  /// Sockets currently open on this page, in creation order.
  List<CoreWebSocket> get webSockets => List.unmodifiable(_webSockets.values);

  /// Forgets every socket. Upstream does this when the main frame navigates,
  /// with the same "TODO: attribute sockets to frames" caveat.
  void clearWebSockets() => _webSockets.clear();

  void onWebSocketCreated(String requestId, String url) {
    _webSockets[requestId] = CoreWebSocket(url);
  }

  void onWebSocketRequest(String requestId,
      {required List<({String name, String value})> headers,
      double? wallTimeMs}) {
    final ws = _webSockets[requestId];
    if (ws == null) return;
    ws.wallTimeMs = wallTimeMs;
    if (ws.markAsNotified()) _announce(ws);
    ws.requestSent(headers);
  }

  void onWebSocketResponse(String requestId,
      {required int status,
      required String statusText,
      required List<({String name, String value})> headers}) {
    final ws = _webSockets[requestId];
    if (ws == null) return;
    ws.responseReceived(status, statusText, headers);
    // A handshake that was refused never opens, and upstream turns that into
    // a socket error instead of leaving the socket silent.
    if (status >= 400) ws.error('$statusText: $status');
  }

  void onWebSocketFrameSent(
      String requestId, int opcode, String data, double wallTimeMs) {
    _webSockets[requestId]?.frameSent(opcode, data, wallTimeMs);
  }

  void webSocketFrameReceived(
      String requestId, int opcode, String data, double wallTimeMs) {
    _webSockets[requestId]?.frameReceived(opcode, data, wallTimeMs);
  }

  void webSocketClosed(String requestId) {
    final ws = _webSockets[requestId];
    if (ws != null) {
      if (ws.markAsNotified()) _announce(ws);
      ws.closed();
    }
    _webSockets.remove(requestId);
  }

  void webSocketError(String requestId, String errorMessage) {
    final ws = _webSockets[requestId];
    if (ws == null) return;
    if (ws.markAsNotified()) _announce(ws);
    ws.error(errorMessage);
  }

  void _announce(CoreWebSocket ws) {
    emit('websocket', ws);
    browserContext?.emit('websocket', ws);
  }
}
