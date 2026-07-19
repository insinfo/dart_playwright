/// A JavaScript dialog (alert / confirm / prompt / beforeunload).
///
/// The dialog blocks the page until [accept] or [dismiss] is called. If no
/// handler is registered on the page, engines auto-dismiss it so scripts do
/// not hang.
class Dialog {
  /// One of 'alert', 'confirm', 'prompt', 'beforeunload'.
  final String type;

  /// The message displayed in the dialog.
  final String message;

  /// The default value shown in a prompt dialog (empty otherwise).
  final String defaultValue;

  final Future<void> Function(bool accept, String? promptText) _handler;
  bool _handled = false;

  Dialog(this.type, this.message, this.defaultValue, this._handler);

  /// Accepts the dialog, optionally providing [promptText] for prompts.
  Future<void> accept([String? promptText]) async {
    if (_handled) return;
    _handled = true;
    await _handler(true, promptText ?? defaultValue);
  }

  /// Dismisses (cancels) the dialog.
  Future<void> dismiss() async {
    if (_handled) return;
    _handled = true;
    await _handler(false, null);
  }
}
