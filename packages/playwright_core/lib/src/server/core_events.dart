/// Payloads for the page-level events that are not requests, responses or
/// frames: console messages, uncaught page errors and renderer crashes.
///
/// These are engine-neutral value objects. Each engine driver normalizes its
/// own protocol event into one of them, so the public API layer never has to
/// know which browser produced it.
library;

/// Where a console message or an error was produced in the page.
class CoreSourceLocation {
  /// URL of the script (or document) the message came from. Empty when the
  /// engine does not report one.
  final String url;

  /// 0-based line number, as upstream reports it.
  final int lineNumber;

  /// 0-based column number, as upstream reports it.
  final int columnNumber;

  const CoreSourceLocation({
    this.url = '',
    this.lineNumber = 0,
    this.columnNumber = 0,
  });

  @override
  String toString() => '$url:$lineNumber:$columnNumber';
}

/// A `console.*` call made by the page.
class CoreConsoleMessage {
  /// One of `log`, `debug`, `info`, `error`, `warning`, `dir`, `dirxml`,
  /// `table`, `trace`, `clear`, `startGroup`, `startGroupCollapsed`,
  /// `endGroup`, `assert`, `profile`, `profileEnd`, `count`, `timeEnd`.
  ///
  /// The engine-specific spellings are normalized to this list, which is the
  /// one upstream documents for `ConsoleMessage.type()`.
  final String type;

  /// The message as the browser devtools would render it.
  final String text;

  /// Where the message was produced.
  final CoreSourceLocation location;

  /// The worker that logged it, or null for a message from the page.
  ///
  /// Upstream channels a worker's console through the page, tagging the
  /// message with the worker (`page.addConsoleMessage(worker, ...)`), so
  /// `page.on('console')` sees both and `message.worker()` tells them
  /// apart. This is the same tag; it is an [Object] because the worker
  /// type lives in a library this one cannot import without a cycle.
  final Object? worker;

  const CoreConsoleMessage({
    required this.type,
    required this.text,
    this.location = const CoreSourceLocation(),
    this.worker,
  });

  @override
  String toString() => '[$type] $text';
}

/// An exception that reached the top level of the page without being caught.
class CorePageError {
  /// The error class name, e.g. `Error` or `TypeError`. Empty when the engine
  /// does not separate it from the message.
  final String name;

  /// The error message, without the class name prefix.
  final String message;

  /// The stack trace as reported by the engine, or an empty string.
  final String stack;

  const CorePageError({
    this.name = '',
    required this.message,
    this.stack = '',
  });

  /// The one-line form `Name: message`, matching what upstream hands to
  /// `page.on('pageerror')` listeners.
  String get formatted => name.isEmpty ? message : '$name: $message';

  @override
  String toString() => formatted;
}
