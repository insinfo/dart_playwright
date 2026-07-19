import 'package:playwright_core/src/server/dialog.dart' as core;

/// Represents a JavaScript dialog (alert, confirm, prompt, beforeunload).
abstract class Dialog {
  /// The type of the dialog (alert, beforeunload, confirm, prompt).
  String get type;

  /// The message displayed in the dialog.
  String get message;

  /// The default value of the prompt, if any.
  String get defaultValue;

  /// Accept the dialog, optionally providing prompt text.
  Future<void> accept([String? promptText]);

  /// Dismiss the dialog.
  Future<void> dismiss();
}

class DialogImpl implements Dialog {
  final core.Dialog _dialog;

  DialogImpl(this._dialog);

  @override
  String get type => _dialog.type;

  @override
  String get message => _dialog.message;

  @override
  String get defaultValue => _dialog.defaultValue;

  @override
  Future<void> accept([String? promptText]) => _dialog.accept(promptText);

  @override
  Future<void> dismiss() => _dialog.dismiss();
}
