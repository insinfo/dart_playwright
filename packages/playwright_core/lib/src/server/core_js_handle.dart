/// Represents a JavaScript object in the page, decoupled from specific engines.
abstract class CoreJSHandle {
  /// The engine's id for the object this handle points at.
  ///
  /// Needed by the protocol commands that take a node rather than an
  /// expression, such as setting the files of an `<input type=file>`.
  String get objectId;

  /// Evaluate a function with this handle as an argument.
  Future<dynamic> evaluate(String expression);

  /// Get properties of the object.
  Future<Map<String, dynamic>> getProperties();

  /// Dispose the handle to release memory in the browser.
  Future<void> dispose();
}
