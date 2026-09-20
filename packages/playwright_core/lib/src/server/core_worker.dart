import 'dart:async';

import 'package:playwright_protocol/playwright_protocol.dart';

import 'core_js_handle.dart';
import 'core_page.dart';

/// A Web Worker (or Shared/Service worker, where the engine reports one)
/// attached to a page.
///
/// Port of `server/page.ts#Worker`. The worker owns exactly one execution
/// context, which the engine driver hands over once the worker's session is
/// ready; every evaluation waits for it, so `worker.evaluate` right after the
/// `worker` event does not race the session setup.
class CoreWorker extends EventEmitter {
  /// The script URL the worker was created from.
  final String url;

  Completer<CoreExecutionContext> _contextCompleter =
      Completer<CoreExecutionContext>();
  bool _scriptLoaded = false;
  bool _isClosed = false;

  /// The context as it stands, or null before the engine announced one.
  /// Console messages coming from the worker need it to build handles.
  CoreExecutionContext? existingExecutionContext;

  CoreWorker(this.url);

  /// Whether the worker already reported `close`.
  bool get isClosed => _isClosed;

  /// Engine hook: the worker's execution context has appeared.
  void createExecutionContext(CoreExecutionContext context) {
    existingExecutionContext = context;
    if (_scriptLoaded && !_contextCompleter.isCompleted) {
      _contextCompleter.complete(context);
    }
  }

  /// Engine hook: the worker's script finished loading, which is what makes
  /// the context safe to evaluate in.
  void workerScriptLoaded() {
    _scriptLoaded = true;
    final context = existingExecutionContext;
    if (context != null && !_contextCompleter.isCompleted) {
      _contextCompleter.complete(context);
    }
  }

  /// Engine hook: the context went away without the worker closing (a
  /// navigation inside the worker, in practice). A later context replaces it.
  void destroyExecutionContext() {
    existingExecutionContext = null;
    _scriptLoaded = false;
    if (_contextCompleter.isCompleted) {
      _contextCompleter = Completer<CoreExecutionContext>();
    }
  }

  /// Engine hook: the worker terminated.
  void didClose() {
    if (_isClosed) return;
    _isClosed = true;
    existingExecutionContext = null;
    if (!_contextCompleter.isCompleted) {
      // Anything still waiting for the context has to fail, not hang.
      _contextCompleter.future.ignore();
      _contextCompleter
          .completeError(TargetClosedException('Worker was closed'));
    }
    emit('close', this);
    disposeStreams();
  }

  /// The worker's execution context, waiting for it when it has not arrived.
  Future<CoreExecutionContext> executionContext({Duration? timeout}) {
    if (_isClosed) {
      return Future.error(TargetClosedException('Worker was closed'));
    }
    final future = _contextCompleter.future;
    if (timeout == null) return future;
    return future.timeout(timeout,
        onTimeout: () => throw TimeoutException(
            'Timeout ${timeout.inMilliseconds}ms exceeded while waiting for '
            'the worker execution context',
            timeout: timeout));
  }

  /// Evaluates [expression] inside the worker, returning the value.
  Future<dynamic> evaluate(String expression) async {
    final context = await executionContext();
    return context.rawEvaluate(wrapEvaluationExpression(expression));
  }

  /// Evaluates [expression] inside the worker, returning a handle.
  Future<CoreJSHandle> evaluateHandle(String expression) async {
    final context = await executionContext();
    return context.rawEvaluateHandle(wrapEvaluationExpression(expression));
  }
}

/// The worker registry of a page.
///
/// Port of the `addWorker`/`removeWorker`/`clearWorkers` trio on
/// `server/page.ts`, keyed by whatever session or worker id the engine uses.
mixin CorePageWorkers on EventEmitter {
  final Map<String, CoreWorker> _workers = <String, CoreWorker>{};

  /// Workers currently attached to this page, in attach order.
  List<CoreWorker> get workers => List.unmodifiable(_workers.values);

  void addWorker(String workerId, CoreWorker worker) {
    _workers[workerId] = worker;
    emit('worker', worker);
  }

  void removeWorker(String workerId) {
    final worker = _workers.remove(workerId);
    worker?.didClose();
  }

  void clearWorkers() {
    for (final worker in _workers.values.toList()) {
      worker.didClose();
    }
    _workers.clear();
  }
}
