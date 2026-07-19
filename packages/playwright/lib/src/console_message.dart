/// Represents a console message from the page.
abstract class ConsoleMessage {
  /// The type of the message (log, warning, error, etc).
  String type();

  /// The text of the message.
  String text();
}

class ConsoleMessageImpl implements ConsoleMessage {
  final String _type;
  final String _text;

  ConsoleMessageImpl(this._type, this._text);

  @override
  String type() => _type;

  @override
  String text() => _text;
}
