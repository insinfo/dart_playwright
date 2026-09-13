import 'dart:async';

import 'package:playwright_protocol/playwright_protocol.dart';

/// A stream that aborts a wait, paired with the error it aborts with.
///
/// The error is built lazily so the message can describe the state at the
/// moment of failure, which is what upstream's `Waiter.rejectOnEvent` does
/// with its error factory.
typedef WaitAbort = ({Stream<void> stream, Object Function() error});

/// Waits for the first value of [source] accepted by [predicate].
///
/// The wait ends, in whichever order comes first:
/// - a matching value, which is returned;
/// - [timeout] elapsing, with a [TimeoutException] worded like upstream's;
/// - any stream in [abortOn] producing a value, with its error;
/// - [source] closing without a match, with a [TargetClosedException] — that
///   is how a page or context closing cancels every wait attached to it.
///
/// Every subscription and the timer are torn down on the way out, so an
/// abandoned wait leaves nothing behind.
Future<T> waitForStreamEvent<T>(
  String eventName,
  Stream<T> source, {
  bool Function(T value)? predicate,
  Duration? timeout,
  List<WaitAbort> abortOn = const [],
}) {
  final completer = Completer<T>();
  final subscriptions = <StreamSubscription<dynamic>>[];
  Timer? timer;

  void fail(Object error) {
    if (!completer.isCompleted) completer.completeError(error);
  }

  subscriptions.add(source.listen(
    (value) {
      if (predicate != null && !predicate(value)) return;
      if (!completer.isCompleted) completer.complete(value);
    },
    onError: fail,
    onDone: () => fail(TargetClosedException(
        'Target closed while waiting for event "$eventName"')),
  ));

  for (final abort in abortOn) {
    subscriptions.add(abort.stream.listen((_) => fail(abort.error()),
        onError: fail, onDone: () {}));
  }

  if (timeout != null) {
    timer = Timer(
        timeout,
        () => fail(TimeoutException(
            'Timeout ${timeout.inMilliseconds}ms exceeded while waiting for event "$eventName"',
            timeout: timeout)));
  }

  return completer.future.whenComplete(() {
    timer?.cancel();
    for (final subscription in subscriptions) {
      subscription.cancel();
    }
  });
}
