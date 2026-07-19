import 'package:playwright_core/src/server/chromium/cr_element_handle.dart';
import 'js_handle.dart';

/// Represents an in-page DOM element.
abstract class ElementHandle extends JSHandle {
  /// Gets the text content of the element.
  Future<String> textContent();

  /// Clicks the element.
  Future<void> click();

  /// Fills the element.
  Future<void> fill(String value);

  /// Focuses the element.
  Future<void> focus();
}

class ElementHandleImpl extends JSHandleImpl implements ElementHandle {
  final CrElementHandle _crElementHandle;

  ElementHandleImpl(this._crElementHandle) : super(_crElementHandle);

  @override
  Future<String> textContent() => _crElementHandle.textContent();

  @override
  Future<void> click() => _crElementHandle.click();

  @override
  Future<void> fill(String value) => _crElementHandle.fill(value);

  @override
  Future<void> focus() => _crElementHandle.focus();
}
