import 'dart:convert';
import 'page.dart';

/// A locator represents a way to find elements on the page.
abstract class Locator {
  /// Click the element.
  Future<void> click();

  /// Double-click the element.
  Future<void> dblclick();

  /// Hover over the element.
  Future<void> hover();

  /// Fill an input field.
  Future<void> fill(String text);

  /// Clear the input field.
  Future<void> clear();

  /// Focus the element.
  Future<void> focus();

  /// Remove focus from the element.
  Future<void> blur();

  /// Focus the element then press [key] (or a chord like 'Control+A').
  Future<void> press(String key);

  /// Focus the element then type [text] character by character, firing
  /// real keyboard events for each character.
  Future<void> pressSequentially(String text);

  /// Get the text content of the element.
  Future<String> textContent();

  /// Get the rendered inner text of the element.
  Future<String> innerText();

  /// Get the inner HTML of the element.
  Future<String> innerHTML();

  /// Get the current value of an input/textarea/select element.
  Future<String> inputValue();

  /// Get an attribute value, or null if absent.
  Future<String?> getAttribute(String name);

  /// Number of elements matching the selector.
  Future<int> count();

  /// Whether the first matching element is visible.
  Future<bool> isVisible();

  /// Whether the element is hidden (not visible or absent).
  Future<bool> isHidden();

  /// Whether the first matching element is enabled (not disabled).
  Future<bool> isEnabled();

  /// Whether the element is disabled.
  Future<bool> isDisabled();

  /// Whether the element accepts text editing.
  Future<bool> isEditable();

  /// Whether a checkbox/radio element is checked.
  Future<bool> isChecked();

  /// Check a checkbox/radio element.
  Future<void> check();

  /// Uncheck a checkbox element.
  Future<void> uncheck();

  /// Select option(s) in a <select> element by value.
  Future<void> selectOption(String value);

  /// Wait until the selector matches an element, or throw on timeout.
  Future<void> waitFor({Duration timeout = const Duration(seconds: 30)});
}

class LocatorImpl implements Locator {
  final Page _page;
  final String _selector;

  LocatorImpl(this._page, this._selector);

  /// The selector as a safely-escaped JS string literal.
  String get _sel => jsonEncode(_selector);

  /// Runs [body] with `el` bound to the first matching element.
  Future<dynamic> _withElement(String body) {
    return _page.evaluate('''
      () => {
        const el = document.querySelector($_sel);
        if (!el) throw new Error('Element not found: ' + $_sel);
        $body
      }
    ''');
  }

  @override
  Future<void> click() => _page.click(_selector);

  @override
  Future<void> dblclick() => _page.dblclick(_selector);

  @override
  Future<void> hover() => _page.hover(_selector);

  @override
  Future<void> fill(String text) => _page.fill(_selector, text);

  @override
  Future<void> clear() => _page.fill(_selector, '');

  @override
  Future<void> focus() => _withElement('el.focus();');

  @override
  Future<void> blur() => _withElement('el.blur();');

  @override
  Future<void> press(String key) => _page.press(_selector, key);

  @override
  Future<void> pressSequentially(String text) => _page.type(_selector, text);

  @override
  Future<String> textContent() async {
    final result = await _withElement('return el.textContent;');
    return result.toString();
  }

  @override
  Future<String> innerText() async {
    final result = await _withElement('return el.innerText;');
    return result.toString();
  }

  @override
  Future<String> innerHTML() async {
    final result = await _withElement('return el.innerHTML;');
    return result.toString();
  }

  @override
  Future<String> inputValue() async {
    final result = await _withElement('return el.value;');
    return result.toString();
  }

  @override
  Future<String?> getAttribute(String name) async {
    final jsName = jsonEncode(name);
    final result = await _withElement('return el.getAttribute($jsName);');
    return result as String?;
  }

  @override
  Future<int> count() async {
    final result =
        await _page.evaluate('() => document.querySelectorAll($_sel).length');
    return (result as num).toInt();
  }

  @override
  Future<bool> isVisible() async {
    final result = await _page.evaluate('''
      () => {
        const el = document.querySelector($_sel);
        if (!el) return false;
        const style = window.getComputedStyle(el);
        if (style.visibility === 'hidden' || style.display === 'none') return false;
        const rect = el.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0;
      }
    ''');
    return result == true;
  }

  @override
  Future<bool> isHidden() async => !await isVisible();

  @override
  Future<bool> isEnabled() async {
    final result = await _withElement('return !el.disabled;');
    return result == true;
  }

  @override
  Future<bool> isDisabled() async => !await isEnabled();

  @override
  Future<bool> isEditable() async {
    final result = await _withElement('''
        if (el.isContentEditable) return true;
        const editableTags = ['INPUT', 'TEXTAREA', 'SELECT'];
        if (!editableTags.includes(el.tagName)) return false;
        return !el.disabled && !el.readOnly;
    ''');
    return result == true;
  }

  @override
  Future<bool> isChecked() async {
    final result = await _withElement('return !!el.checked;');
    return result == true;
  }

  @override
  Future<void> check() async {
    if (!await isChecked()) await click();
  }

  @override
  Future<void> uncheck() async {
    if (await isChecked()) await click();
  }

  @override
  Future<void> selectOption(String value) async {
    final jsValue = jsonEncode(value);
    await _withElement('''
        el.value = $jsValue;
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
    ''');
  }

  @override
  Future<void> waitFor({Duration timeout = const Duration(seconds: 30)}) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final found =
          await _page.evaluate('() => document.querySelector($_sel) !== null');
      if (found == true) return;
      if (DateTime.now().isAfter(deadline)) {
        throw Exception(
            'Timeout ${timeout.inMilliseconds}ms waiting for selector $_selector');
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }
}
