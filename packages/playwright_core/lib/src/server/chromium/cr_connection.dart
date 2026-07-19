import 'dart:async';
import 'package:playwright_protocol/playwright_protocol.dart';
import 'package:playwright_core/playwright_core.dart';

/// Represents a session to a specific CDP Target.
class CDPSession extends EventEmitter {
  final CRConnection connection;
  final String sessionId;
  final String targetType;
  
  bool _isClosed = false;

  CDPSession(this.connection, this.sessionId, this.targetType) {
    // Forward events from connection specific to this session
    connection.on('session-$sessionId', (ProtocolResponse event) {
      emit(event.method!, event.params);
    });
  }

  /// Send a CDP command to this session.
  Future<Map<String, dynamic>> send(String method, [Map<String, dynamic>? params]) {
    if (_isClosed) {
      throw TargetClosedException('Session closed. Cannot send command: $method');
    }
    return connection._sendMessage(method, params, sessionId);
  }

  void _onClosed() {
    _isClosed = true;
    emit('closed');
  }
}

/// The main CDP connection to the Chromium browser process.
class CRConnection extends EventEmitter {
  final ConnectionTransport _transport;
  final _callbacks = <int, Completer<Map<String, dynamic>>>{};
  final _sessions = <String, CDPSession>{};
  
  int _lastId = 0;
  bool _isClosed = false;

  CRConnection(this._transport) {
    _transport.onMessage.listen(_onMessage);
    _transport.onClose.listen(_onClose);
  }

  /// Create a new CDPSession.
  CDPSession createSession(String sessionId, String targetType) {
    final session = CDPSession(this, sessionId, targetType);
    _sessions[sessionId] = session;
    return session;
  }

  /// Get an existing session.
  CDPSession? getSession(String sessionId) => _sessions[sessionId];

  /// Send a CDP command to the browser root session.
  Future<Map<String, dynamic>> send(String method, [Map<String, dynamic>? params]) {
    return _sendMessage(method, params, null);
  }

  Future<Map<String, dynamic>> _sendMessage(String method, Map<String, dynamic>? params, String? sessionId) {
    if (_isClosed) {
      throw TargetClosedException('Connection closed. Cannot send command: $method');
    }

    final id = ++_lastId;
    final completer = Completer<Map<String, dynamic>>();
    _callbacks[id] = completer;

    final request = ProtocolRequest(
      id: id,
      method: method,
      params: params,
      sessionId: sessionId,
    );

    try {
      _transport.send(request);
    } catch (e) {
      _callbacks.remove(id);
      completer.completeError(e);
    }

    return completer.future;
  }

  void _onMessage(ProtocolResponse response) {
    if (response.id != null) {
      // It's a response to a command
      final completer = _callbacks.remove(response.id);
      if (completer != null) {
        if (response.error != null) {
          completer.completeError(ProtocolException(
            response.error!.message,
            code: response.error!.code,
            data: response.error!.data,
          ));
        } else {
          completer.complete(response.result ?? {});
        }
      }
    } else if (response.method != null) {
      // It's an event
      if (response.sessionId != null) {
        // Target-scoped event
        final session = _sessions[response.sessionId];
        if (session != null) {
          emit('session-${response.sessionId}', response);
        }
      } else {
        // Root browser event
        emit(response.method!, response.params);
      }
    }
  }

  void _onClose(String? reason) {
    if (_isClosed) return;
    _isClosed = true;

    for (final completer in _callbacks.values) {
      // ignore(): avoid unhandled async errors for abandoned senders.
      completer.future.ignore();
      completer.completeError(TargetClosedException(reason ?? 'Connection closed'));
    }
    _callbacks.clear();

    for (final session in _sessions.values) {
      session._onClosed();
    }
    _sessions.clear();

    emit('closed');
  }

  Future<void> close() async {
    await _transport.close();
  }
}
