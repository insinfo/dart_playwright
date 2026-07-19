/// Represents a JavaScript dialog (alert, confirm, prompt, beforeunload).
abstract class Dialog {
  /// The type of the dialog (alert, beforeunload, confirm, prompt).
  String type();

  /// The message displayed in the dialog.
  String message();

  /// The default value of the prompt, if any.
  String defaultValue();

  /// Accept the dialog.
  Future<void> accept([String? promptText]);

  /// Dismiss the dialog.
  Future<void> dismiss();
}

class DialogImpl implements Dialog {
  final String _type;
  final String _message;
  final String _defaultValue;
  final Future<void> Function([String? promptText]) _onAccept;
  final Future<void> Function() _onDismiss;

  DialogImpl(this._type, this._message, this._defaultValue, this._onAccept, this._onDismiss);

  @override
  String type() => _type;

  @override
  String message() => _message;

  @override
  String defaultValue() => _defaultValue;

  @override
  Future<void> accept([String? promptText]) => _onAccept(promptText);

  @override
  Future<void> dismiss() => _onDismiss();
}
