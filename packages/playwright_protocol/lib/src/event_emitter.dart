import 'dart:async';

/// A synchronous event emitter compatible with the Playwright protocol.
///
/// Unlike Dart's built-in Stream (which is async by default), this emitter
/// dispatches events synchronously to all listeners, matching the behavior
/// of Node.js EventEmitter used in the original Playwright.
///
/// This is critical for protocol correctness — events must be processed
/// in order without yielding to the event loop between them.
class EventEmitter {
  final _listeners = <String, List<Function>>{};
  final _onceListeners = <String, List<Function>>{};
  /// Set maximum number of listeners per event. 0 = unlimited.
  void setMaxListeners(int n) {
    // Currently unimplemented logic for max listeners
  }

  /// Add a listener for [event].
  void on(String event, Function listener) {
    _listeners.putIfAbsent(event, () => []).add(listener);
  }

  /// Add a listener that will be called at most once for [event].
  void once(String event, Function listener) {
    _onceListeners.putIfAbsent(event, () => []).add(listener);
  }

  /// Remove a specific [listener] for [event].
  void off(String event, Function listener) {
    _listeners[event]?.remove(listener);
    _onceListeners[event]?.remove(listener);
  }

  /// Add listener (alias for [on]).
  void addListener(String event, Function listener) => on(event, listener);

  /// Remove listener (alias for [off]).
  void removeListener(String event, Function listener) => off(event, listener);

  /// Remove all listeners for [event], or all events if null.
  void removeAllListeners([String? event]) {
    if (event != null) {
      _listeners.remove(event);
      _onceListeners.remove(event);
    } else {
      _listeners.clear();
      _onceListeners.clear();
    }
  }

  /// Get the number of listeners for [event].
  int listenerCount(String event) {
    return (_listeners[event]?.length ?? 0) +
        (_onceListeners[event]?.length ?? 0);
  }

  /// Emit an [event] with optional [args].
  /// Returns true if there were any listeners.
  bool emit(String event, [dynamic arg1, dynamic arg2, dynamic arg3]) {
    final hasListeners =
        (_listeners[event]?.isNotEmpty ?? false) ||
        (_onceListeners[event]?.isNotEmpty ?? false);

    // Call regular listeners
    final regular = _listeners[event];
    if (regular != null) {
      for (final listener in List.of(regular)) {
        _callListener(listener, arg1, arg2, arg3);
      }
    }

    // Call once listeners (and remove them)
    final once = _onceListeners[event];
    if (once != null && once.isNotEmpty) {
      final toCall = List.of(once);
      once.clear();
      for (final listener in toCall) {
        _callListener(listener, arg1, arg2, arg3);
      }
    }

    return hasListeners;
  }

  void _callListener(
      Function listener, dynamic arg1, dynamic arg2, dynamic arg3) {
    if (arg3 != null) {
      listener(arg1, arg2, arg3);
    } else if (arg2 != null) {
      listener(arg1, arg2);
    } else if (arg1 != null) {
      listener(arg1);
    } else {
      listener();
    }
  }

  /// Wait for the next occurrence of [event].
  /// Returns a Future that completes with the event argument.
  Future<T> waitForEvent<T>(String event, {Duration? timeout}) {
    final completer = Completer<T>();

    void listener([dynamic arg]) {
      if (!completer.isCompleted) {
        completer.complete(arg as T?);
      }
    }

    once(event, listener);

    if (timeout != null) {
      return completer.future.timeout(timeout, onTimeout: () {
        off(event, listener);
        throw TimeoutError('Timeout waiting for event "$event"');
      });
    }

    return completer.future;
  }

  /// Create a broadcast Stream for [event].
  ///
  /// This bridges the EventEmitter pattern to Dart's Stream pattern,
  /// allowing idiomatic Dart usage:
  /// ```dart
  /// emitter.stream('load').listen((_) => print('loaded'));
  /// ```
  Stream<T> stream<T>(String event) {
    final controller = StreamController<T>.broadcast(
      onCancel: () {
        // Could clean up listener here if needed
      },
    );

    on(event, (dynamic arg) {
      if (!controller.isClosed) {
        controller.add(arg as T);
      }
    });

    return controller.stream;
  }
}

/// Timeout error used by EventEmitter.waitForEvent.
class TimeoutError extends Error {
  final String message;
  TimeoutError(this.message);

  @override
  String toString() => 'TimeoutError: $message';
}
