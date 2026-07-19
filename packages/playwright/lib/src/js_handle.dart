import 'package:playwright_core/src/server/chromium/cr_js_handle.dart';

/// Represents an in-page JavaScript object.
abstract class JSHandle {
  /// Evaluates the expression using this handle as an argument.
  Future<dynamic> evaluate(String expression);

  /// Gets the properties of this object.
  Future<Map<String, dynamic>> getProperties();

  /// Releases the remote object in the browser.
  Future<void> dispose();
}

class JSHandleImpl implements JSHandle {
  final CrJSHandle _crHandle;

  JSHandleImpl(this._crHandle);

  @override
  Future<dynamic> evaluate(String expression) => _crHandle.evaluate(expression);

  @override
  Future<Map<String, dynamic>> getProperties() => _crHandle.getProperties();

  @override
  Future<void> dispose() => _crHandle.dispose();
}
