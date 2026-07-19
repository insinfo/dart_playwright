import 'dart:async';
import 'package:playwright_protocol/playwright_protocol.dart';
import '../../transport/transport.dart';

class FfSession extends EventEmitter {
  final FfConnection connection;
  final String sessionId;
  final String targetType;
  
  bool _isClosed = false;

  FfSession(this.connection, this.sessionId, [this.targetType = 'page']) {
    connection.on('session-$sessionId', (ProtocolResponse event) {
      emit(event.method!, event.params);
    });
  }

  Future<Map<String, dynamic>> send(String method, [Map<String, dynamic>? params]) {
    if (_isClosed) throw PlaywrightException('Session closed');
    return connection._sendMessage(method, params, sessionId);
  }

  void _onClosed() {
    _isClosed = true;
    emit('closed');
  }
}

class FfConnection extends EventEmitter {
  final ConnectionTransport transport;
  final _callbacks = <int, Completer<Map<String, dynamic>>>{};
  final _sessions = <String, FfSession>{};
  
  int _lastId = 0;
  bool _isClosed = false;
  late final FfSession rootSession;

  FfConnection(this.transport) {
    rootSession = FfSession(this, '', 'browser');
    transport.onMessage.listen(_onMessage);
    transport.onClose.listen(_onClose);
  }

  FfSession createSession(String sessionId, [String targetType = 'page']) {
    final session = FfSession(this, sessionId, targetType);
    _sessions[sessionId] = session;
    return session;
  }

  Future<Map<String, dynamic>> send(String method, [Map<String, dynamic>? params]) {
    return _sendMessage(method, params, null);
  }

  Future<Map<String, dynamic>> _sendMessage(String method, Map<String, dynamic>? params, String? sessionId) {
    if (_isClosed) throw PlaywrightException('Connection closed');
    final id = ++_lastId;
    final completer = Completer<Map<String, dynamic>>();
    _callbacks[id] = completer;
    transport.send(ProtocolRequest(id: id, method: method, params: params, sessionId: sessionId));
    return completer.future;
  }

  void _onMessage(ProtocolResponse response) {
    if (response.id != null) {
      final completer = _callbacks.remove(response.id);
      if (completer != null) {
        if (response.error != null) {
          completer.completeError(PlaywrightException(response.error!.message));
        } else {
          completer.complete(response.result ?? {});
        }
      }
    } else if (response.method != null) {
      if (response.sessionId != null) {
        emit('session-${response.sessionId}', response);
      } else {
        emit(response.method!, response.params);
      }
    }
  }

  void _onClose(String? reason) {
    if (_isClosed) return;
    _isClosed = true;
    for (final completer in _callbacks.values) completer.completeError(PlaywrightException(reason ?? 'Closed'));
    _callbacks.clear();
    for (final session in _sessions.values) session._onClosed();
    _sessions.clear();
    emit('closed');
  }
}
