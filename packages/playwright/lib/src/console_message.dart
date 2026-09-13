import 'package:playwright_core/src/server/core_events.dart' as core;

/// Where a console message was produced in the page.
typedef ConsoleMessageLocation = ({
  String url,
  int lineNumber,
  int columnNumber,
});

/// Represents a console message from the page.
abstract class ConsoleMessage {
  /// The type of the message.
  ///
  /// One of `log`, `debug`, `info`, `error`, `warning`, `dir`, `dirxml`,
  /// `table`, `trace`, `clear`, `startGroup`, `startGroupCollapsed`,
  /// `endGroup`, `assert`, `profile`, `profileEnd`, `count`, `timeEnd`.
  /// Chromium's `Log` domain can additionally report `verbose`.
  String type();

  /// The text of the message, as devtools would render it: the arguments of
  /// the `console.*` call joined by spaces.
  String text();

  /// The script URL and 0-based position the message came from.
  ConsoleMessageLocation location();
}

class ConsoleMessageImpl implements ConsoleMessage {
  final core.CoreConsoleMessage _message;

  ConsoleMessageImpl(this._message);

  @override
  String type() => _message.type;

  @override
  String text() => _message.text;

  @override
  ConsoleMessageLocation location() => (
        url: _message.location.url,
        lineNumber: _message.location.lineNumber,
        columnNumber: _message.location.columnNumber,
      );

  @override
  String toString() => _message.toString();
}
