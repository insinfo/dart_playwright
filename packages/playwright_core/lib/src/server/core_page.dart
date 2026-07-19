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
  Future<void> goto(String url, {WaitUntilState? waitUntil, Duration? timeout});

  /// Reloads the page and waits for the navigation to reach [waitUntil].
  Future<void> reload({WaitUntilState? waitUntil});

  /// Navigates back in history. Returns false when there is no entry.
  Future<bool> goBack({WaitUntilState? waitUntil});

  /// Navigates forward in history. Returns false when there is no entry.
  Future<bool> goForward({WaitUntilState? waitUntil});

  /// Replaces the document content and waits for it to reach [waitUntil].
  Future<void> setContent(String html,
      {WaitUntilState? waitUntil, Duration? timeout});

  /// Polls [expression] until it evaluates to a truthy value and returns it.
  Future<dynamic> waitForFunction(String expression,
      {Duration? timeout, Duration? polling});
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

  /// Remove a route handler; disables interception when none remain.
  Future<void> unroute(String urlPattern);

  /// Click [selector] using trusted protocol-level input events.
  ///
  /// [button] is 'left', 'middle' or 'right'. [position] is an offset from
  /// the element's top-left corner (defaults to its center). [delay] is
  /// held between press and release.
  Future<void> click(String selector,
      {String button = 'left',
      int clickCount = 1,
      Duration? delay,
      ({double x, double y})? position});

  /// Double-click [selector] using trusted protocol-level input events.
  Future<void> dblclick(String selector,
      {String button = 'left',
      Duration? delay,
      ({double x, double y})? position});

  /// Hover over [selector] using a trusted protocol-level mouse move.
  Future<void> hover(String selector, {({double x, double y})? position});

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

/// Re-emits the engine network manager's events on the page, where the
/// public API streams (onRequest/onResponse/...) listen.
void forwardNetworkEvents(EventEmitter networkManager, EventEmitter page) {
  for (final event in const [
    'request',
    'response',
    'requestFinished',
    'requestFailed'
  ]) {
    networkManager.on(event, (dynamic payload) => page.emit(event, payload));
  }
}

/// Content and script-polling helpers shared by the engine pages.
///
/// Both are built purely on [evaluate], so every engine gets them for free.
mixin CorePageContentHelpers {
  Future<dynamic> evaluate(String expression);

  /// Polls [expression] until it evaluates to a truthy value and returns it.
  Future<dynamic> waitForFunction(String expression,
      {Duration? timeout, Duration? polling}) async {
    final effectiveTimeout = timeout ?? const Duration(seconds: 30);
    final interval = polling ?? const Duration(milliseconds: 100);
    final deadline = DateTime.now().add(effectiveTimeout);
    while (true) {
      final value = await evaluate(expression);
      final isTruthy =
          value != null && value != false && value != 0 && value != '';
      if (isTruthy) return value;
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('waitForFunction: condition not met',
            timeout: effectiveTimeout);
      }
      await Future.delayed(interval);
    }
  }

  /// Replaces the document content and waits for it to reach [waitUntil].
  Future<void> setContent(String html,
      {WaitUntilState? waitUntil, Duration? timeout}) async {
    final encoded = jsonEncode(html);
    await evaluate('''
      () => {
        document.open();
        document.write($encoded);
        document.close();
      }
    ''');
    final state = waitUntil ?? WaitUntilState.load;
    if (state == WaitUntilState.commit) return;
    final condition = state == WaitUntilState.domcontentloaded
        ? "document.readyState !== 'loading'"
        : "document.readyState === 'complete'";
    await waitForFunction('() => $condition', timeout: timeout);
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

  /// Scrolls [selector] into view and returns the viewport coordinates to
  /// click: the element center, or [position] relative to its top-left.
  Future<({double x, double y})> clickPointFor(String selector,
      {({double x, double y})? position}) async {
    final sel = jsonEncode(selector);
    final offset = position == null
        ? 'null'
        : '{ x: ${position.x}, y: ${position.y} }';
    final result = await evaluate('''
      () => {
        const el = document.querySelector($sel);
        if (!el) throw new Error('Element not found: ' + $sel);
        el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
        const rect = el.getBoundingClientRect();
        const offset = $offset;
        if (offset) return { x: rect.x + offset.x, y: rect.y + offset.y };
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
    await _focusWithRetry(selector, '''
        if (typeof el.select === 'function') {
          el.select();
        } else if (el.isContentEditable) {
          const range = document.createRange();
          range.selectNodeContents(el);
          const selection = window.getSelection();
          selection.removeAllRanges();
          selection.addRange(range);
        }
    ''');
  }

  /// Focuses [selector] without altering its selection.
  Future<void> focus(String selector) async {
    await _focusWithRetry(selector, '');
  }

  /// el.focus() can silently fail while a headless window is still being
  /// activated (seen on WebKit macOS, where a later keystroke then lands on
  /// the page and e.g. Backspace navigates back). Verify activeElement and
  /// retry briefly before giving up.
  Future<void> _focusWithRetry(String selector, String afterFocusJs) async {
    final sel = jsonEncode(selector);
    for (var attempt = 0; attempt < 10; attempt++) {
      final focused = await evaluate('''
        () => {
          const el = document.querySelector($sel);
          if (!el) throw new Error('Element not found: ' + $sel);
          el.focus();
          $afterFocusJs
          return document.activeElement === el;
        }
      ''');
      if (focused == true) return;
      await Future.delayed(const Duration(milliseconds: 50));
    }
  }
}
