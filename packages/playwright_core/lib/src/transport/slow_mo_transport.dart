import 'dart:async';

import 'package:playwright_protocol/playwright_protocol.dart';

import 'transport.dart';

/// Wraps a transport so every command leaves after a pause, which is what
/// `slowMo` is for: watching a headed run at human speed.
///
/// Sends stay in order. `send` is synchronous and the protocol relies on the
/// order commands reach the browser, so the delay is applied by chaining each
/// message onto the previous one's future rather than by an independent timer
/// per message.
class SlowMoTransport implements ConnectionTransport {
  SlowMoTransport(this._inner, this.delay);

  final ConnectionTransport _inner;
  final Duration delay;

  Future<void> _queue = Future.value();
  bool _closed = false;

  @override
  Stream<ProtocolResponse> get onMessage => _inner.onMessage;

  @override
  Stream<String?> get onClose => _inner.onClose;

  @override
  void send(ProtocolRequest message) {
    _queue = _queue.then((_) async {
      await Future<void>.delayed(delay);
      if (_closed) return;
      _inner.send(message);
    });
    // Nobody awaits this chain; a send that fails after the transport died
    // must not surface as an unhandled async error.
    _queue = _queue.catchError((Object _) {});
  }

  @override
  Future<void> close() async {
    _closed = true;
    await _inner.close();
  }
}
