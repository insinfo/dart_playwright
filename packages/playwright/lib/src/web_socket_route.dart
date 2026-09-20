import 'dart:convert';

import 'package:playwright_core/src/server/core_page.dart';

/// One message crossing a routed WebSocket.
///
/// [binary] is always the bytes; [text] is those bytes as UTF-8. [isText]
/// says which of the two the page (or the server) actually sent, because a
/// mocked socket has to hand the other side the same kind of payload it was
/// given.
class WebSocketMessage {
  final List<int> _binary;
  final bool isText;

  WebSocketMessage._(this._binary, this.isText);

  factory WebSocketMessage.fromCore(CoreWebSocketData data) =>
      WebSocketMessage._(data.bytes, !data.isBase64);

  List<int> binary() => _binary;

  String text() => utf8.decode(_binary, allowMalformed: true);
}

/// A WebSocket a `routeWebSocket` handler took over.
///
/// The object the handler receives is the page side: [send] reaches the page,
/// [onMessage] sees what the page sends, and [close] closes the page's
/// socket. [connectToServer] opens the real connection and returns its server
/// side, where all four are mirrored.
///
/// Without a handler on a side, whatever arrives there is forwarded to the
/// other one; installing a handler takes that over completely.
abstract class WebSocketRoute {
  /// The URL the page asked for.
  String url();

  /// The subprotocols the page asked for.
  List<String> protocols();

  /// Sends a text message to this side.
  void send(String message);

  /// Sends a binary message to this side.
  void sendBinary(List<int> message);

  /// Closes this side of the socket.
  Future<void> close({int? code, String? reason});

  /// Handles the messages arriving from this side.
  void onMessage(void Function(WebSocketMessage message) handler);

  /// Handles this side closing.
  void onClose(void Function(int? code, String? reason) handler);

  /// Connects to the real server and returns the server side of the route.
  ///
  /// Only valid on the page side, and only once.
  WebSocketRoute connectToServer();
}

/// What a `routeWebSocket` handler is.
typedef WebSocketRouteHandler = Future<void> Function(WebSocketRoute route);

class WebSocketRouteImpl implements WebSocketRoute {
  final CoreWebSocketRoute _coreRoute;

  WebSocketRouteImpl(this._coreRoute);

  @override
  String url() => _coreRoute.url;

  @override
  List<String> protocols() => _coreRoute.protocols;

  @override
  void send(String message) => _coreRoute.send(message);

  @override
  void sendBinary(List<int> message) => _coreRoute.sendBinary(message);

  @override
  Future<void> close({int? code, String? reason}) =>
      _coreRoute.close(code: code, reason: reason);

  @override
  void onMessage(void Function(WebSocketMessage message) handler) =>
      _coreRoute.onMessage((data) => handler(WebSocketMessage.fromCore(data)));

  @override
  void onClose(void Function(int? code, String? reason) handler) =>
      _coreRoute.onClose(handler);

  @override
  WebSocketRoute connectToServer() =>
      WebSocketRouteImpl(_coreRoute.connectToServer());
}
