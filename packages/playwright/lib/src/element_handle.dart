import 'package:playwright_core/src/server/core_element_handle.dart';
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
  final CoreElementHandle _coreElementHandle;

  ElementHandleImpl(this._coreElementHandle) : super(_coreElementHandle);

  @override
  Future<String> textContent() => _coreElementHandle.textContent();

  @override
  Future<void> click() => _coreElementHandle.click();

  @override
  Future<void> fill(String value) => _coreElementHandle.fill(value);

  @override
  Future<void> focus() => _coreElementHandle.focus();
}
