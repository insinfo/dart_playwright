import 'dart:async';
import 'dart:convert';
import 'package:playwright_protocol/playwright_protocol.dart';
import '../../transport/transport.dart';

/// A session scoped to a WebKit pageProxy.
///
/// WebKit's protocol has two layers:
/// - pageProxy-level messages carry a top-level `pageProxyId` on the wire.
/// - page (target) level messages are wrapped in `Target.sendMessageToTarget`
///   and responses/events come back via `Target.dispatchMessageFromTarget`.
/// What an execution context needs from a WebKit session: a way to send a
/// target-scoped command.
///
/// Two things answer it — [WkPageProxySession], which wraps the command in
/// `Target.sendMessageToTarget`, and [WkWorkerSession], which wraps it in
/// `Worker.sendMessageToWorker`. Upstream has a single `WKSession` taking the
/// raw send as a callback; the split here keeps both dispatch paths typed.
abstract class WkTargetSession extends EventEmitter {
  Future<Map<String, dynamic>> sendToTarget(String method,
      [Map<String, dynamic>? params]);
}

class WkPageProxySession extends WkTargetSession {
  final WkConnection connection;
  final String pageProxyId;

  String? targetId;
  bool targetIsPaused = false;
  final _targetCompleter = Completer<String>();

  bool _isClosed = false;
  bool get isClosed => _isClosed;

  WkPageProxySession(this.connection, this.pageProxyId);

  /// Completes with the targetId of the first page target in this proxy.
  Future<String> waitForTarget(
      {Duration timeout = const Duration(seconds: 30)}) {
    return _targetCompleter.future.timeout(timeout, onTimeout: () {
      throw PlaywrightException(
          'Timeout waiting for WebKit target in pageProxy $pageProxyId');
    });
  }

  /// Send a pageProxy-level command (carries `pageProxyId` on the wire).
  Future<Map<String, dynamic>> send(String method,
      [Map<String, dynamic>? params]) {
    if (_isClosed) throw PlaywrightException('Session closed');
    return connection.sendMessage(method, params, pageProxyId: pageProxyId);
  }

  /// Send a page-level command, wrapped in `Target.sendMessageToTarget`.
  @override
  Future<Map<String, dynamic>> sendToTarget(String method,
      [Map<String, dynamic>? params]) {
    if (_isClosed) throw PlaywrightException('Session closed');
    final tid = targetId;
    if (tid == null) {
      throw PlaywrightException('No target attached to pageProxy $pageProxyId');
    }
    final id = connection.nextId();
    final completer = connection.registerCallback(id);

    final inner = <String, dynamic>{
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    };

    send('Target.sendMessageToTarget', {
      'targetId': tid,
      'message': jsonEncode(inner),
    }).catchError((Object e) {
      // If the wrapper itself fails, fail the inner call too.
      final pending = connection.takeCallback(id);
      if (pending != null && !pending.isCompleted) {
        pending.completeError(e);
      }
      return <String, dynamic>{};
    });

    return completer.future;
  }

  /// Dispatches a pageProxy-scoped protocol message to this session.
  void dispatch(ProtocolResponse response) {
    final method = response.method;
    if (method == null) return;

    if (method == 'Target.targetCreated') {
      final targetInfo =
          response.params?['targetInfo'] as Map<String, dynamic>?;
      if (targetInfo != null && targetInfo['type'] == 'page') {
        targetId = targetInfo['targetId'] as String?;
        targetIsPaused = targetInfo['isPaused'] == true;
        if (!_targetCompleter.isCompleted && targetId != null) {
          _targetCompleter.complete(targetId);
        }
      }
      emit(method, response.params);
      return;
    }

    if (method == 'Target.dispatchMessageFromTarget') {
      final messageStr = response.params?['message'] as String?;
      if (messageStr == null) return;
      final inner = jsonDecode(messageStr) as Map<String, dynamic>;
      final innerId = inner['id'] as int?;
      if (innerId != null) {
        final completer = connection.takeCallback(innerId);
        if (completer != null && !completer.isCompleted) {
          final error = inner['error'];
          if (error != null) {
            completer.completeError(PlaywrightException(
                (error as Map<String, dynamic>)['message'] as String? ??
                    'Unknown protocol error'));
          } else {
            completer
                .complete((inner['result'] as Map<String, dynamic>?) ?? {});
          }
        }
      } else if (inner['method'] != null) {
        // Page-level event (e.g. Page.loadEventFired, Runtime.*).
        emit(inner['method'] as String, inner['params']);
      }
      return;
    }

    emit(method, response.params);
  }

  void onClosed() {
    if (_isClosed) return;
    _isClosed = true;
    emit('closed');
  }
}

/// A session with a WebKit worker.
///
/// The worker has no target of its own: commands go out as a JSON string in
/// `Worker.sendMessageToWorker` on the page session, and replies and events
/// come back in `Worker.dispatchMessageFromWorker`. Ids are minted inside the
/// tunnel, so they cannot collide with the connection's.
class WkWorkerSession extends WkTargetSession {
  final WkPageProxySession pageSession;
  final String workerId;

  final _callbacks = <int, Completer<Map<String, dynamic>>>{};
  int _lastId = 0;
  bool _isClosed = false;

  WkWorkerSession(this.pageSession, this.workerId);

  @override
  Future<Map<String, dynamic>> sendToTarget(String method,
      [Map<String, dynamic>? params]) {
    if (_isClosed) throw PlaywrightException('Worker session closed');
    final id = ++_lastId;
    final completer = Completer<Map<String, dynamic>>();
    _callbacks[id] = completer;
    pageSession.sendToTarget('Worker.sendMessageToWorker', {
      'workerId': workerId,
      'message': jsonEncode({
        'id': id,
        'method': method,
        if (params != null) 'params': params,
      }),
    }).catchError((Object error) {
      final pending = _callbacks.remove(id);
      if (pending != null && !pending.isCompleted) {
        pending.completeError(error);
      }
      return <String, dynamic>{};
    });
    return completer.future;
  }

  /// Feeds one message that arrived in `Worker.dispatchMessageFromWorker`.
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

class WkConnection extends EventEmitter {
  final ConnectionTransport transport;
  final _callbacks = <int, Completer<Map<String, dynamic>>>{};
  final _pageProxySessions = <String, WkPageProxySession>{};

  int _lastId = 0;
  bool _isClosed = false;

  WkConnection(this.transport) {
    transport.onMessage.listen(_onMessage);
    transport.onClose.listen(_onClose);
  }

  int nextId() => ++_lastId;

  Completer<Map<String, dynamic>> registerCallback(int id) {
    final completer = Completer<Map<String, dynamic>>();
    _callbacks[id] = completer;
    return completer;
  }

  Completer<Map<String, dynamic>>? takeCallback(int id) =>
      _callbacks.remove(id);

  WkPageProxySession pageProxySession(String pageProxyId) {
    return _pageProxySessions.putIfAbsent(
        pageProxyId, () => WkPageProxySession(this, pageProxyId));
  }

  void removePageProxySession(String pageProxyId) {
    _pageProxySessions.remove(pageProxyId)?.onClosed();
  }

  /// Send a browser-level (or pageProxy-level) command.
  Future<Map<String, dynamic>> send(String method,
      [Map<String, dynamic>? params]) {
    return sendMessage(method, params);
  }

  Future<Map<String, dynamic>> sendMessage(
      String method, Map<String, dynamic>? params,
      {String? pageProxyId}) {
    if (_isClosed) throw PlaywrightException('Connection closed');
    final id = nextId();
    final completer = registerCallback(id);

    transport.send(ProtocolRequest(
      id: id,
      method: method,
      params: params,
      pageProxyId: pageProxyId,
    ));

    return completer.future;
  }

  void _onMessage(ProtocolResponse response) {
    if (response.id != null) {
      final completer = _callbacks.remove(response.id);
      if (completer != null && !completer.isCompleted) {
        if (response.error != null) {
          completer.completeError(PlaywrightException(response.error!.message));
        } else {
          completer.complete(response.result ?? {});
        }
      }
      return;
    }

    if (response.method == null) return;

    final pageProxyId = response.pageProxyId;
    if (pageProxyId != null) {
      // pageProxy-scoped message; sessions are created eagerly so events
      // arriving right after Playwright.pageProxyCreated are not lost.
      pageProxySession(pageProxyId).dispatch(response);
      return;
    }

    if (response.method == 'Playwright.pageProxyCreated') {
      final id = response.params?['pageProxyId'] as String?;
      if (id != null) pageProxySession(id);
    } else if (response.method == 'Playwright.pageProxyDestroyed') {
      final id = response.params?['pageProxyId'] as String?;
      if (id != null) removePageProxySession(id);
    }

    emit(response.method!, response.params);
  }

  void _onClose(String? reason) {
    if (_isClosed) return;
    _isClosed = true;
    for (final completer in _callbacks.values) {
      if (!completer.isCompleted) {
        // ignore(): avoid unhandled async errors for abandoned senders.
        completer.future.ignore();
        completer.completeError(PlaywrightException(reason ?? 'Closed'));
      }
    }
    _callbacks.clear();
    for (final session in _pageProxySessions.values) {
      session.onClosed();
    }
    _pageProxySessions.clear();
    emit('closed');
  }
}
