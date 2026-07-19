import 'page.dart';

/// A locator represents a way to find elements on the page.
abstract class Locator {
  /// Click the element.
  Future<void> click();

  /// Fill an input field.
  Future<void> fill(String text);

  /// Get the text content of the element.
  Future<String> textContent();
}

class LocatorImpl implements Locator {
  final Page _page;
  final String _selector;

  LocatorImpl(this._page, this._selector);

  @override
  Future<void> click() async {
    // For this prototype v0.1, we evaluate JS directly.
    // In full implementation, this uses DOM.querySelector + Input.dispatchMouseEvent.
    final result = await _page.evaluate('''
      (() => {
        const el = document.querySelector('$_selector');
        if (!el) throw new Error('Element not found');
        el.click();
      })()
    ''');
    return result;
  }

  @override
  Future<void> fill(String text) async {
    await _page.evaluate('''
      (() => {
        const el = document.querySelector('$_selector');
        if (!el) throw new Error('Element not found');
        el.value = '$text';
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      })()
    ''');
  }

  @override
  Future<String> textContent() async {
    final result = await _page.evaluate('''
      (() => {
        const el = document.querySelector('$_selector');
        if (!el) throw new Error('Element not found');
        return el.textContent;
      })()
    ''');
    return result.toString();
  }
}
