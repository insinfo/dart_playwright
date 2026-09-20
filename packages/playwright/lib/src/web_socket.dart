import 'dart:convert';

import 'package:playwright_core/src/server/core_page.dart';
import 'package:playwright_protocol/playwright_protocol.dart';

import 'waiter.dart';

/// One frame that crossed a [WebSocket].
///
/// The engines report a text frame as text and a binary frame as base64, and
/// both shapes are kept: [binary] is always the bytes, [text] is those bytes
/// decoded as UTF-8. This is the shape the .NET binding exposes, and the one
/// a language without a string/Buffer union can offer honestly.
class WebSocketFrame {
  final List<int> _binary;

  /// Whether the frame was a text frame (opcode 1) rather than binary.
  final bool isText;

  WebSocketFrame._(this._binary, this.isText);

  /// Builds a frame from what the engine reported.
  factory WebSocketFrame.fromCore(CoreWebSocketFrame frame) {
    return WebSocketFrame._(
      frame.isText ? utf8.encode(frame.data) : base64Decode(frame.data),
      frame.isText,
    );
  }

  /// The payload as bytes.
  List<int> binary() => _binary;

  /// The payload decoded as UTF-8. Meaningless for a binary frame that does
  /// not happen to hold UTF-8, which is why [isText] exists.
  String text() => utf8.decode(_binary, allowMalformed: true);
}

/// A WebSocket the page opened.
///
/// Obtained from `page.onWebSocket` or `page.waitForWebSocket`. The socket is
/// observed, never driven: to take one over, route it with
/// `page.routeWebSocket`.
abstract class WebSocket {
  /// The URL the page asked for, without a fragment.
  String url();

  /// Whether the socket has closed.
  bool isClosed();

  /// Frames the page sent.
  Stream<WebSocketFrame> get onFrameSent;

  /// Frames the page received.
  Stream<WebSocketFrame> get onFrameReceived;

  /// Socket errors, as the engine words them, so the text differs by engine.
  ///
  /// Chromium and WebKit have a frame-level error event; the Juggler does
  /// not, and reports only the `error` field of `Page.webSocketClosed`. On
  /// top of that, a handshake answered with 400 or worse is turned into
  /// `"<statusText>: <status>"` — which Chromium never reaches, because it
  /// does not report the refused handshake response at all.
  Stream<String> get onSocketError;

  /// Fires once, when the socket closes.
  Stream<WebSocket> get onClose;

  /// Waits for the next frame the page sends.
  ///
  /// Fails when the socket errors or closes first, as upstream's
  /// `webSocket.waitForEvent` does.
  Future<WebSocketFrame> waitForFrameSent(
      {bool Function(WebSocketFrame frame)? predicate, Duration? timeout});

  /// Waits for the next frame the page receives. See [waitForFrameSent].
  Future<WebSocketFrame> waitForFrameReceived(
      {bool Function(WebSocketFrame frame)? predicate, Duration? timeout});

  /// Waits for the socket to close.
  Future<WebSocket> waitForClose({Duration? timeout});
}

class WebSocketImpl implements WebSocket {
  final CoreWebSocket _coreWebSocket;

  WebSocketImpl(this._coreWebSocket);

  /// The single wrapper per core socket, so `waitForWebSocket` and
  /// `onWebSocket` hand out the same object and its streams agree.
  factory WebSocketImpl.forCore(CoreWebSocket core) =>
      _wrappers[core] ??= WebSocketImpl(core);

  static final _wrappers = Expando<WebSocketImpl>();

  @override
  String url() => _coreWebSocket.url;

  @override
  bool isClosed() => _coreWebSocket.isClosed;

  @override
  Stream<WebSocketFrame> get onFrameSent => _coreWebSocket
      .stream<CoreWebSocketFrame>('framesent')
      .map(WebSocketFrame.fromCore);

  @override
  Stream<WebSocketFrame> get onFrameReceived => _coreWebSocket
      .stream<CoreWebSocketFrame>('framereceived')
      .map(WebSocketFrame.fromCore);

  @override
  Stream<String> get onSocketError =>
      _coreWebSocket.stream<String>('socketerror');

  @override
  Stream<WebSocket> get onClose =>
      _coreWebSocket.stream<CoreWebSocket>('close').map((_) => this);

  /// The aborts every frame wait carries: an error or a close ends the wait
  /// with that reason instead of letting it run to the timeout.
  List<WaitAbort> _frameAborts() => [
        (
          stream: onSocketError,
          error: () => PlaywrightException('Socket error'),
        ),
        (
          stream: onClose,
          error: () => PlaywrightException('Socket closed'),
        ),
      ];

  @override
  Future<WebSocketFrame> waitForFrameSent(
          {bool Function(WebSocketFrame frame)? predicate,
          Duration? timeout}) =>
      waitForStreamEvent(
        'framesent',
        onFrameSent,
        predicate: predicate,
        timeout: timeout,
        abortOn: _frameAborts(),
      );

  @override
  Future<WebSocketFrame> waitForFrameReceived(
          {bool Function(WebSocketFrame frame)? predicate,
          Duration? timeout}) =>
      waitForStreamEvent(
        'framereceived',
        onFrameReceived,
        predicate: predicate,
        timeout: timeout,
        abortOn: _frameAborts(),
      );

  @override
  Future<WebSocket> waitForClose({Duration? timeout}) => waitForStreamEvent(
        'close',
        onClose,
        timeout: timeout,
      );
}
