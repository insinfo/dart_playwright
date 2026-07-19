import 'dart:async';
import 'package:playwright_protocol/playwright_protocol.dart';

/// Abstract interface for protocol transport (WebSocket or Pipe).
///
/// This handles sending and receiving raw JSON-RPC messages to and from
/// the browser process.
abstract class ConnectionTransport {
  /// Send a protocol request to the browser.
  void send(ProtocolRequest message);

  /// Close the transport connection.
  Future<void> close();

  /// Stream of incoming responses and events from the browser.
  Stream<ProtocolResponse> get onMessage;

  /// Stream that emits when the transport is closed.
  /// The payload may contain a reason string (optional).
  Stream<String?> get onClose;
}
