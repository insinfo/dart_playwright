import 'package:playwright_core/src/server/core_page.dart';

import 'js_handle.dart';
import 'waiter.dart';

/// A Web Worker running in the page.
///
/// Obtained from [Page.workers], [Page.onWorker] or [Page.waitForWorker]. A
/// worker disappears from `page.workers` when it terminates and when its page
/// closes; both produce [onClose].
abstract class Worker {
  /// The script URL the worker was created from.
  String url();

  /// Whether the worker has terminated.
  bool isClosed();

  /// Evaluates [expression] inside the worker and returns the value.
  ///
  /// Waits for the worker's execution context, so this is safe to call the
  /// moment the `worker` event arrives.
  Future<dynamic> evaluate(String expression);

  /// Evaluates [expression] inside the worker and returns a handle to it.
  Future<JSHandle> evaluateHandle(String expression);

  /// Fires once, when the worker terminates.
  Stream<Worker> get onClose;

  /// Waits for the worker to terminate.
  Future<Worker> waitForClose({Duration? timeout});
}

class WorkerImpl implements Worker {
  final CoreWorker _coreWorker;

  WorkerImpl(this._coreWorker);

  /// The single wrapper per core worker, so `page.workers` and the `worker`
  /// event hand out the same object.
  factory WorkerImpl.forCore(CoreWorker core) =>
      _wrappers[core] ??= WorkerImpl(core);

  static final _wrappers = Expando<WorkerImpl>();

  @override
  String url() => _coreWorker.url;

  @override
  bool isClosed() => _coreWorker.isClosed;

  @override
  Future<dynamic> evaluate(String expression) =>
      _coreWorker.evaluate(expression);

  @override
  Future<JSHandle> evaluateHandle(String expression) async =>
      JSHandleImpl(await _coreWorker.evaluateHandle(expression));

  @override
  Stream<Worker> get onClose =>
      _coreWorker.stream<CoreWorker>('close').map((_) => this);

  @override
  Future<Worker> waitForClose({Duration? timeout}) =>
      waitForStreamEvent('close', onClose, timeout: timeout);
}
