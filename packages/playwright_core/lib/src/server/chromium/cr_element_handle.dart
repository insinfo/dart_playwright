import 'cr_js_handle.dart';

/// Represents a DOM element in the page.
class CrElementHandle extends CrJSHandle {
  CrElementHandle(super.context, super.objectId);

  /// Get the text content of this element.
  Future<String> textContent() async {
    final result = await evaluate('''
      (el) => el.textContent
    ''');
    return result.toString();
  }

  /// Click this element.
  Future<void> click() async {
    // In a full implementation, this calculates bounding box and dispatches mouse events.
    // For this prototype, we simulate a click via JS.
    await evaluate('''
      (el) => el.click()
    ''');
  }

  /// Focus this element.
  Future<void> focus() async {
    await evaluate('''
      (el) => el.focus()
    ''');
  }

  /// Fill an input element.
  Future<void> fill(String value) async {
    // Basic implementation for prototype
    await evaluate('''
      (el) => {
        el.value = '$value';
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      }
    ''');
  }
}
