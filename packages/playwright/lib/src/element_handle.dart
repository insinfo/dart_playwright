import 'dart:convert';

import 'package:playwright_core/src/server/core_element_handle.dart';

import 'frame.dart';
import 'js_handle.dart';
import 'locator.dart';

/// Represents an in-page DOM element.
///
/// Upstream recommends [Locator] over handles: a handle points at one element
/// and goes stale when the DOM changes, while a locator re-resolves on every
/// use. The handle API exists because upstream has it and because some
/// operations (frame ownership, for one) are naturally expressed on a node.
abstract class ElementHandle extends JSHandle {
  /// Gets the text content of the element.
  Future<String> textContent();

  /// The rendered inner text.
  Future<String> innerText();

  /// The inner HTML.
  Future<String> innerHTML();

  /// The value of an input/textarea/select.
  Future<String> inputValue();

  /// An attribute value, or null when absent.
  Future<String?> getAttribute(String name);

  /// Clicks the element.
  Future<void> click();

  /// Fills the element.
  Future<void> fill(String value);

  /// Focuses the element.
  Future<void> focus();

  /// Scrolls the element into view if needed.
  Future<void> scrollIntoViewIfNeeded();

  /// The element's box in its own frame's viewport, or null when not rendered.
  Future<BoundingBox?> boundingBox();

  Future<bool> isVisible();
  Future<bool> isHidden();
  Future<bool> isEnabled();
  Future<bool> isDisabled();
  Future<bool> isEditable();
  Future<bool> isChecked();

  /// The frame this element owns, when it is an `iframe`/`frame`.
  Future<Frame?> contentFrame();

  /// The frame this element belongs to, when known.
  Frame? ownerFrame();
}

class ElementHandleImpl extends JSHandleImpl implements ElementHandle {
  final CoreElementHandle _coreElementHandle;
  final FrameImpl? _frame;

  ElementHandleImpl(this._coreElementHandle, {FrameImpl? frame})
      : _frame = frame,
        super(_coreElementHandle);

  @override
  Future<String> textContent() => _coreElementHandle.textContent();

  @override
  Future<String> innerText() async =>
      (await evaluate('(el) => el.innerText'))?.toString() ?? '';

  @override
  Future<String> innerHTML() async =>
      (await evaluate('(el) => el.innerHTML'))?.toString() ?? '';

  @override
  Future<String> inputValue() async =>
      (await evaluate('(el) => el.value'))?.toString() ?? '';

  @override
  Future<String?> getAttribute(String name) async {
    final result =
        await evaluate('(el) => el.getAttribute(${jsonEncode(name)})');
    return result as String?;
  }

  @override
  Future<void> click() => _coreElementHandle.click();

  @override
  Future<void> fill(String value) => _coreElementHandle.fill(value);

  @override
  Future<void> focus() => _coreElementHandle.focus();

  @override
  Future<void> scrollIntoViewIfNeeded() async {
    await evaluate(
        "(el) => el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' })");
  }

  @override
  Future<BoundingBox?> boundingBox() async {
    final result = await evaluate('''
      (el) => {
        const rect = el.getBoundingClientRect();
        return { x: rect.x, y: rect.y, width: rect.width, height: rect.height };
      }
    ''');
    if (result is! Map) return null;
    return BoundingBox(
      (result['x'] as num).toDouble(),
      (result['y'] as num).toDouble(),
      (result['width'] as num).toDouble(),
      (result['height'] as num).toDouble(),
    );
  }

  @override
  Future<bool> isVisible() async =>
      await evaluate('(el) => window.__pwDart.elementState(el, "visible").matches') ==
      true;

  @override
  Future<bool> isHidden() async => !await isVisible();

  @override
  Future<bool> isEnabled() async =>
      await evaluate('(el) => window.__pwDart.elementState(el, "enabled").matches') ==
      true;

  @override
  Future<bool> isDisabled() async => !await isEnabled();

  @override
  Future<bool> isEditable() async =>
      await evaluate('''
        (el) => {
          try {
            return window.__pwDart.elementState(el, "editable").matches;
          } catch (e) {
            return false;
          }
        }
      ''') ==
      true;

  @override
  Future<bool> isChecked() async =>
      await evaluate('(el) => window.__pwDart.elementState(el, "checked").matches') ==
      true;

  @override
  Future<Frame?> contentFrame() async {
    final frame = _frame;
    if (frame == null) return null;
    final child =
        await frame.coreFrame.page.contentFrame(_coreElementHandle);
    if (child == null) return null;
    return FrameImpl(child, frame.page());
  }

  @override
  Frame? ownerFrame() => _frame;
}
