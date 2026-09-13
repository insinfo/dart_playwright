import 'dart:async';
import 'package:playwright_protocol/playwright_protocol.dart';
import 'core_page.dart';

/// Maps frames to their main-world execution context, and lets callers wait
/// for a context that the engine has not announced yet.
///
/// Every engine reports context creation the same way (a protocol event
/// carrying a context id plus the frame it belongs to), so the bookkeeping is
/// shared; only the event shape is engine-specific.
class ContextRegistry {
  final _byFrame = <String, CoreExecutionContext>{};
  final _waiters = <String, List<Completer<CoreExecutionContext>>>{};

  /// Called when the engine announces a new main-world context for [frameId].
  void contextCreated(String frameId, CoreExecutionContext context) {
    _byFrame[frameId] = context;
    final waiters = _waiters.remove(frameId);
    if (waiters != null) {
      for (final waiter in waiters) {
        if (!waiter.isCompleted) waiter.complete(context);
      }
    }
  }

  /// Called when a context id is destroyed. Returns the frame it belonged to.
  String? contextDestroyed(Object contextId) {
    for (final entry in _byFrame.entries) {
      if (entry.value.contextId == contextId) {
        _byFrame.remove(entry.key);
        return entry.key;
      }
    }
    return null;
  }

  void frameDetached(String frameId) {
    _byFrame.remove(frameId);
  }

  void clear() {
    _byFrame.clear();
  }

  CoreExecutionContext? contextFor(String frameId) => _byFrame[frameId];

  /// The frame that owns [contextId], or null.
  ///
  /// Juggler identifies the file chooser's element only by its execution
  /// context, so the frame has to be found the other way round.
  String? frameIdFor(Object contextId) {
    for (final entry in _byFrame.entries) {
      if (entry.value.contextId == contextId) return entry.key;
    }
    return null;
  }

  /// Waits for [frameId]'s context.
  ///
  /// When [fallback] is given, a timeout resolves to it instead of throwing.
  /// Engines use that for the main frame, whose default context is usable
  /// without an explicit id even when the creation event never arrives.
  Future<CoreExecutionContext> waitFor(String frameId,
      {Duration timeout = const Duration(seconds: 10),
      CoreExecutionContext? fallback}) {
    final existing = _byFrame[frameId];
    if (existing != null) return Future.value(existing);
    final completer = Completer<CoreExecutionContext>();
    _waiters.putIfAbsent(frameId, () => []).add(completer);
    return completer.future.timeout(timeout, onTimeout: () {
      _waiters[frameId]?.remove(completer);
      if (fallback != null) return fallback;
      throw PlaywrightException(
          'Timed out waiting for the execution context of frame $frameId');
    });
  }
}
