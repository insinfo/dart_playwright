import 'dart:async';
import 'dart:convert';
import 'package:playwright_protocol/playwright_protocol.dart';
import '../accessibility.dart';
import 'dialog.dart';
import 'keyboard.dart';
import 'core_js_handle.dart';
import 'core_route.dart';
import 'frames.dart';
export 'dialog.dart' show Dialog;
export 'keyboard.dart' show Keyboard;
export 'frames.dart' show CoreFrame, CoreFrameManager;

enum WaitUntilState {
  load,
  domcontentloaded,
  networkidle,
  commit,
}

abstract class CorePage extends EventEmitter {
  CoreFrame get mainFrame;
  List<CoreFrame> get frames;
  Future<void> goto(String url, {WaitUntilState? waitUntil});
  Future<void> waitForLoadState(
      {WaitUntilState state = WaitUntilState.load, Duration? timeout});
  Future<void> waitForNavigation(
      {WaitUntilState? waitUntil, Duration? timeout});
  Future<String> title();
  Future<dynamic> evaluate(String expression);
  Future<CoreJSHandle> evaluateHandle(String expression);
  Future<List<int>> screenshot({String? path});
  Future<AccessibilitySnapshot> accessibilitySnapshot();

  /// Intercept network requests.
  Future<void> route(String urlPattern, void Function(CoreRoute) handler);

  /// Click [selector] using trusted protocol-level input events.
  Future<void> click(String selector);

  /// Fill [selector] with [text] using trusted protocol-level input events.
  Future<void> fill(String selector, String text);

  /// The page's keyboard, dispatching trusted key events via the protocol.
  Keyboard get keyboard;

  /// Focuses [selector] then presses [key] (or a chord like 'Control+A').
  Future<void> press(String selector, String key);

  /// Focuses [selector] then types [text] character by character.
  Future<void> type(String selector, String text);

  /// Registers a handler invoked when a JavaScript dialog opens. Without a
  /// handler, dialogs are auto-dismissed.
  void onDialog(void Function(Dialog dialog) handler);

  Future<void> close();
}

/// Dialog dispatch shared by the engine pages.
mixin CorePageDialogs {
  void Function(Dialog dialog)? _dialogHandler;

  /// Registers the dialog handler (replaces any previous one).
  void onDialog(void Function(Dialog dialog) handler) {
    _dialogHandler = handler;
  }

  /// Routes an opened [dialog] to the handler, or auto-dismisses it.
  void dispatchDialog(Dialog dialog) {
    final handler = _dialogHandler;
    if (handler != null) {
      handler(dialog);
    } else {
      dialog.dismiss();
    }
  }
}

/// Shared helpers for protocol-based input.
///
/// Geometry and focus are resolved with injected JS (as upstream Playwright
/// does); the actual mouse/keyboard events are dispatched by each engine
/// through its native protocol so pages receive trusted events.
mixin CorePageInputHelpers {
  Future<dynamic> evaluate(String expression);

  /// The page keyboard; classes using this mixin must provide it.
  Keyboard get keyboard;

  /// Focuses [selector] then presses [key] (or a chord like 'Control+A').
  Future<void> press(String selector, String key) async {
    await focus(selector);
    await keyboard.press(key);
  }

  /// Focuses [selector] then types [text] character by character.
  Future<void> type(String selector, String text) async {
    await focus(selector);
    await keyboard.type(text);
  }

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

  /// Focuses [selector] without altering its selection.
  Future<void> focus(String selector) async {
    final sel = jsonEncode(selector);
    await evaluate('''
      () => {
        const el = document.querySelector($sel);
        if (!el) throw new Error('Element not found: ' + $sel);
        el.focus();
      }
    ''');
  }
}
