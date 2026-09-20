import 'dart:async';
import 'dart:convert';
import 'package:playwright_protocol/playwright_protocol.dart';
import '../../transport/transport.dart';

/// What an execution context needs from a Juggler session.
///
/// There are two flavours: [FfSession], which rides the connection's own
/// session routing, and [FfWorkerSession], whose messages are tunnelled
/// through `Page.sendMessageToWorker`. Upstream has one class for both,
/// because its `FFSession` takes the raw send as a callback; here the two
/// dispatch paths are different enough that a shared supertype is clearer.
abstract class FfProtocolSession extends EventEmitter {
  Future<Map<String, dynamic>> send(String method,
      [Map<String, dynamic>? params]);
}

class FfSession extends FfProtocolSession {
  final FfConnection connection;
  final String sessionId;
  final String targetType;

  bool _isClosed = false;

  FfSession(this.connection, this.sessionId, [this.targetType = 'page']) {
    connection.on('session-$sessionId', (ProtocolResponse event) {
      emit(event.method!, event.params);
    });
  }

  @override
  Future<Map<String, dynamic>> send(String method,
      [Map<String, dynamic>? params]) {
    if (_isClosed) throw PlaywrightException('Session closed');
    return connection._sendMessage(method, params, sessionId);
  }

  void _onClosed() {
    _isClosed = true;
    emit('closed');
  }
}

/// A session with a Juggler worker.
///
/// Juggler has no session id for a worker: every message is a JSON string
/// carried by `Page.sendMessageToWorker` on the owning page session, and the
/// replies and events come back the same way in
/// `Page.dispatchMessageFromWorker`. Ids are minted here rather than by the
/// connection, because they only have to be unique within this tunnel.
class FfWorkerSession extends FfProtocolSession {
  final FfSession pageSession;
  final String frameId;
  final String workerId;

  final _callbacks = <int, Completer<Map<String, dynamic>>>{};
  int _lastId = 0;
  bool _isClosed = false;

  FfWorkerSession(this.pageSession, this.frameId, this.workerId);

  @override
  Future<Map<String, dynamic>> send(String method,
      [Map<String, dynamic>? params]) {
    if (_isClosed) throw PlaywrightException('Worker session closed');
    final id = ++_lastId;
    final completer = Completer<Map<String, dynamic>>();
    _callbacks[id] = completer;
    pageSession.send('Page.sendMessageToWorker', {
      'frameId': frameId,
      'workerId': workerId,
      'message': jsonEncode({
        'id': id,
        'method': method,
        if (params != null) 'params': params,
      }),
    }).catchError((Object error) {
      // The tunnel itself failed, so the inner call can never be answered.
      final pending = _callbacks.remove(id);
      if (pending != null && !pending.isCompleted) {
        pending.completeError(error);
      }
      return <String, dynamic>{};
    });
    return completer.future;
  }

  /// Feeds one message that arrived in `Page.dispatchMessageFromWorker`.
  void dispatchMessage(Map<String, dynamic> message) {
    final id = message['id'] as int?;
    if (id != null) {
      final completer = _callbacks.remove(id);
      if (completer == null || completer.isCompleted) return;
      final error = message['error'];
      if (error is Map) {
        completer.completeError(
            PlaywrightException(error['message'] as String? ?? 'Worker error'));
      } else {
        completer.complete((message['result'] as Map<String, dynamic>?) ?? {});
      }
      return;
    }
    final method = message['method'] as String?;
    if (method != null) emit(method, message['params']);
  }

  void dispose() {
    if (_isClosed) return;
    _isClosed = true;
    for (final completer in _callbacks.values) {
      if (completer.isCompleted) continue;
      completer.future.ignore();
      completer.completeError(PlaywrightException('Worker session closed'));
    }
    _callbacks.clear();
    emit('closed');
    disposeStreams();
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

  /// Tears down the session for [sessionId] after Juggler detached its target.
  ///
  /// Sessions used to live until the whole connection went down, so a closed
  /// page never told anyone it had closed.
  void closeSession(String sessionId) {
    _sessions.remove(sessionId)?._onClosed();
  }

  Future<Map<String, dynamic>> send(String method,
      [Map<String, dynamic>? params]) {
    return _sendMessage(method, params, null);
  }

  Future<Map<String, dynamic>> _sendMessage(
      String method, Map<String, dynamic>? params, String? sessionId) {
    if (_isClosed) throw PlaywrightException('Connection closed');
    final id = ++_lastId;
    final completer = Completer<Map<String, dynamic>>();
    _callbacks[id] = completer;
    transport.send(ProtocolRequest(
        id: id, method: method, params: params, sessionId: sessionId));
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
      if (response.sessionId != null && response.sessionId!.isNotEmpty) {
        emit('session-${response.sessionId}', response);
      } else {
        rootSession.emit(response.method!, response.params);
        emit(response.method!, response.params);
      }
    }
  }

  void _onClose(String? reason) {
    if (_isClosed) return;
    _isClosed = true;
    for (final completer in _callbacks.values) {
      // ignore(): senders that already gave up must not surface this as an
      // unhandled async error in whatever zone created the callback.
      completer.future.ignore();
      completer.completeError(PlaywrightException(reason ?? 'Closed'));
    }
    _callbacks.clear();
    for (final session in _sessions.values) session._onClosed();
    emit('closed');
  }

  Future<void> close() async {
    await transport.close();
  }
}
