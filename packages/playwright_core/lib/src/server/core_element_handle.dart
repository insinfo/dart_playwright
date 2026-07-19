import 'core_js_handle.dart';

/// Represents a DOM element in the page, decoupled from specific engines.
abstract class CoreElementHandle extends CoreJSHandle {
  /// Get the text content of this element.
  Future<String> textContent();

  /// Click this element.
  Future<void> click();

  /// Focus this element.
  Future<void> focus();

  /// Fill an input element.
  Future<void> fill(String value);
}
