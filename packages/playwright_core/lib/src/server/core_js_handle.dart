/// Represents a JavaScript object in the page, decoupled from specific engines.
abstract class CoreJSHandle {
  /// Evaluate a function with this handle as an argument.
  Future<dynamic> evaluate(String expression);

  /// Get properties of the object.
  Future<Map<String, dynamic>> getProperties();

  /// Dispose the handle to release memory in the browser.
  Future<void> dispose();
}
