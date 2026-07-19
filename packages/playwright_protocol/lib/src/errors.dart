/// Base exception for all Playwright errors.
class PlaywrightException implements Exception {
  final String message;
  final String? stack;

  PlaywrightException(this.message, {this.stack});

  @override
  String toString() => 'PlaywrightException: $message';
}

/// Exception thrown when a protocol command fails.
class ProtocolException extends PlaywrightException {
  final int? code;
  final dynamic data;

  ProtocolException(
    super.message, {
    this.code,
    this.data,
    super.stack,
  });

  @override
  String toString() => 'ProtocolException: $message (code: $code)';
}

/// Exception thrown when an operation times out.
class TimeoutException extends PlaywrightException {
  final Duration? timeout;

  TimeoutException(super.message, {this.timeout, super.stack});

  @override
  String toString() =>
      'TimeoutException: $message${timeout != null ? ' (after $timeout)' : ''}';
}

/// Exception thrown when a navigation fails.
class NavigationException extends PlaywrightException {
  final String? url;

  NavigationException(super.message, {this.url, super.stack});

  @override
  String toString() =>
      'NavigationException: $message${url != null ? ' (url: $url)' : ''}';
}

/// Exception thrown when a target (browser, context, page) is closed.
class TargetClosedException extends PlaywrightException {
  TargetClosedException([String? message])
      : super(message ?? 'Target has been closed');
}

/// Exception thrown when an operation is aborted (e.g., via signal).
class AbortException extends PlaywrightException {
  final Object? cause;

  AbortException([String? message, this.cause])
      : super(message ?? 'Operation was aborted');
}

/// Exception thrown when an element is not actionable
/// (not visible, not enabled, detached, etc.).
class ActionabilityException extends PlaywrightException {
  ActionabilityException(super.message);
}

/// Exception thrown when a selector matches no elements or too many elements.
class SelectorException extends PlaywrightException {
  SelectorException(super.message);
}
