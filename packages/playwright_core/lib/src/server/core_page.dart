import 'dart:async';
import 'dart:convert';
import 'package:playwright_protocol/playwright_protocol.dart';
import '../accessibility.dart';

abstract class CorePage extends EventEmitter {
  Future<void> goto(String url);
  Future<String> title();
  Future<dynamic> evaluate(String expression);
  Future<dynamic> evaluateHandle(String expression);
  Future<List<int>> screenshot({String? path});
  Future<AccessibilitySnapshot> accessibilitySnapshot();
  Future<void> route(String urlPattern, Function(dynamic) handler);

  /// Click [selector] using trusted protocol-level input events.
  Future<void> click(String selector);

  /// Fill [selector] with [text] using trusted protocol-level input events.
  Future<void> fill(String selector, String text);

  Future<void> close();
}

/// Shared helpers for protocol-based input.
///
/// Geometry and focus are resolved with injected JS (as upstream Playwright
/// does); the actual mouse/keyboard events are dispatched by each engine
/// through its native protocol so pages receive trusted events.
mixin CorePageInputHelpers {
  Future<dynamic> evaluate(String expression);

  /// Scrolls [selector] into view and returns the viewport coordinates of
  /// its center as `{x, y}`.
  Future<({double x, double y})> clickPointFor(String selector) async {
    final sel = jsonEncode(selector);
    final result = await evaluate('''
      () => {
        const el = document.querySelector($sel);
        if (!el) throw new Error('Element not found: ' + $sel);
        el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
        const rect = el.getBoundingClientRect();
        return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
      }
    ''');
    final map = result as Map;
    return (
      x: (map['x'] as num).toDouble(),
      y: (map['y'] as num).toDouble(),
    );
  }

  /// Focuses [selector] and selects its current contents, so that inserted
  /// text replaces the existing value (fill semantics).
  Future<void> focusAndSelect(String selector) async {
    final sel = jsonEncode(selector);
    await evaluate('''
      () => {
        const el = document.querySelector($sel);
        if (!el) throw new Error('Element not found: ' + $sel);
        el.focus();
        if (typeof el.select === 'function') {
          el.select();
        } else if (el.isContentEditable) {
          const range = document.createRange();
          range.selectNodeContents(el);
          const selection = window.getSelection();
          selection.removeAllRanges();
          selection.addRange(range);
        }
      }
    ''');
  }
}
