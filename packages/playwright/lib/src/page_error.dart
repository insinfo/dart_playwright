import 'package:playwright_core/src/server/core_events.dart' as core;

/// An exception that reached the top level of the page without being caught.
///
/// Delivered by [Page.onPageError] and by the context-wide
/// [BrowserContext.onPageError].
abstract class PageError {
  /// The error class name, e.g. `Error` or `TypeError`.
  ///
  /// Empty when the engine reports a message with no `Name: ` prefix.
  String get name;

  /// The error message, without the class name prefix.
  String get message;

  /// The stack trace as the engine reported it, normalized to the V8 shape
  /// (`    at fn (url:line:column)`), or an empty string when the engine sent
  /// no stack.
  String get stack;
}

class PageErrorImpl implements PageError {
  final core.CorePageError _error;

  PageErrorImpl(this._error);

  @override
  String get name => _error.name;

  @override
  String get message => _error.message;

  @override
  String get stack => _error.stack;

  @override
  String toString() => _error.formatted;
}
