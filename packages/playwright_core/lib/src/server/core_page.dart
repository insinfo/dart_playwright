import 'dart:async';
import 'dart:convert';
import 'package:playwright_protocol/playwright_protocol.dart';
import '../accessibility.dart';
import 'core_browser.dart';
import 'core_events.dart';
import 'dialog.dart';
import 'keyboard.dart';
import 'core_js_handle.dart';
import 'core_route.dart';
import 'frames.dart';
import 'mouse.dart';
import 'injected/injected_script_source.dart';
export 'core_events.dart'
    show CoreConsoleMessage, CorePageError, CoreSourceLocation;
export 'dialog.dart' show Dialog;
export 'keyboard.dart' show Keyboard;
export 'mouse.dart' show Mouse, RawMouse;
export 'frames.dart' show CoreFrame, CoreFrameManager;

enum WaitUntilState {
  load,
  domcontentloaded,
  networkidle,
  commit,
}

/// A JavaScript execution context bound to one frame's main world.
abstract class CoreExecutionContext {
  /// Identifies the context. A navigation replaces the context and therefore
  /// the id, which is how cached in-page state is invalidated.
  Object get contextId;

  /// Evaluates [expression], returning the value by value.
  Future<dynamic> rawEvaluate(String expression);

  /// Evaluates [expression], returning a handle to the result.
  Future<CoreJSHandle> rawEvaluateHandle(String expression);
}

abstract class CorePage extends EventEmitter {
  CoreFrame get mainFrame;
  List<CoreFrame> get frames;

  /// The context this page belongs to, assigned when the context registers
  /// the page. Null only for a page that was built outside a context.
  CoreBrowserContext? get browserContext;
  set browserContext(CoreBrowserContext? value);

  /// The page that opened this one through `window.open` or a
  /// `target=_blank` link, or null for a page opened programmatically.
  CorePage? get opener;
  set opener(CorePage? value);

  /// Whether the page has been closed (by [close], by the script, or because
  /// its context or browser went away).
  bool get isClosed;
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

  /// Resizes the page viewport, overriding whatever the context set.
  Future<void> setViewportSize(int width, int height);

  /// Sets headers sent with every request this page makes.
  ///
  /// Replaces the previous set; pass an empty map to clear it. Header names
  /// keep the casing given here, as upstream does.
  Future<void> setExtraHTTPHeaders(Map<String, String> headers);

  // -------------------------------------------------------------- per frame

  /// The main-world execution context of [frame].
  ///
  /// Waits briefly for the context to be created; a frame that has just been
  /// attached does not have one yet.
  Future<CoreExecutionContext> executionContextFor(CoreFrame frame,
      {Duration? timeout});

  /// Navigates [frame] (not necessarily the main frame) to [url].
  Future<void> gotoFrame(CoreFrame frame, String url,
      {WaitUntilState? waitUntil, Duration? timeout});

  /// The frame owned by the `iframe`/`frame` element [handle] points at,
  /// or null when the element is not a frame owner.
  Future<CoreFrame?> contentFrame(CoreJSHandle handle);

  /// Evaluates [expression] in [frame]'s context.
  Future<dynamic> evaluateInFrame(CoreFrame frame, String expression);

  /// Evaluates [expression] in [frame]'s context, returning a handle.
  Future<CoreJSHandle> evaluateHandleInFrame(CoreFrame frame, String expression);

  /// Like [evaluateInFrame], with `window.__pwDart` (the selector engine)
  /// installed in the context first.
  Future<dynamic> evaluateInjected(CoreFrame frame, String expression);

  /// Like [evaluateHandleInFrame], with the selector engine installed first.
  Future<CoreJSHandle> evaluateHandleInjected(
      CoreFrame frame, String expression);

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

  // ---------------------------------------------------- frame-scoped input
  //
  // The `*Target` methods take a JS expression that evaluates to the element
  // inside [frame], so a locator can drive input on any frame without the
  // element having to be reachable by a CSS selector from the main document.

  /// Clicks the element [resolverJs] resolves to inside [frame].
  Future<void> clickTarget(CoreFrame frame, String resolverJs,
      {String button = 'left',
      int clickCount = 1,
      Duration? delay,
      ({double x, double y})? position});

  /// Double-clicks the element [resolverJs] resolves to inside [frame].
  Future<void> dblclickTarget(CoreFrame frame, String resolverJs,
      {String button = 'left',
      Duration? delay,
      ({double x, double y})? position});

  /// Hovers the element [resolverJs] resolves to inside [frame].
  Future<void> hoverTarget(CoreFrame frame, String resolverJs,
      {({double x, double y})? position});

  /// Fills the element [resolverJs] resolves to inside [frame].
  Future<void> fillTarget(CoreFrame frame, String resolverJs, String text);

  /// The page's keyboard, dispatching trusted key events via the protocol.
  Keyboard get keyboard;

  /// The page's mouse, dispatching trusted mouse events via the protocol.
  Mouse get mouse;

  /// The top-level viewport point to aim at for the element [resolverJs]
  /// resolves to inside [frame].
  Future<({double x, double y})> clickPointForTarget(
      CoreFrame frame, String resolverJs,
      {({double x, double y})? position});

  /// Focuses [selector] then presses [key] (or a chord like 'Control+A').
  Future<void> press(String selector, String key);

  /// Focuses [selector] then types [text] character by character.
  Future<void> type(String selector, String text);

  /// Focuses the element [resolverJs] resolves to, then presses [key].
  Future<void> pressTarget(CoreFrame frame, String resolverJs, String key);

  /// Focuses the element [resolverJs] resolves to, then types [text].
  Future<void> typeTarget(CoreFrame frame, String resolverJs, String text);

  /// Focuses the element [resolverJs] resolves to inside [frame].
  Future<void> focusTarget(CoreFrame frame, String resolverJs);

  /// Registers a handler invoked when a JavaScript dialog opens. Without a
  /// handler, dialogs are auto-dismissed.
  void onDialog(void Function(Dialog dialog) handler);

  Future<void> close();
}

/// Wraps a bare arrow/function expression in a call, so that both
/// `() => 2 + 2` and `2 + 2` evaluate to `4`.
String wrapEvaluationExpression(String expression) {
  final trimmed = expression.trim();
  final isFunction = trimmed.startsWith('function') ||
      trimmed.startsWith('async function') ||
      RegExp(r'^(?:async\s+)?(?:\([^)]*\)|[A-Za-z_$][\w$]*)\s*=>')
          .hasMatch(trimmed);
  return isFunction ? '($expression)()' : expression;
}

/// Ownership links every page carries: the context that owns it and the page
/// that opened it.
mixin CorePageOwnership {
  CoreBrowserContext? browserContext;
  CorePage? opener;
}

/// Dialog dispatch shared by the engine pages.
///
/// Upstream dismisses a dialog that nobody is watching, because a modal
/// dialog blocks the renderer and an unobserved one would hang the script.
/// "Watching" means either the imperative [onDialog] handler, a subscriber on
/// the page's `dialog` stream, or a subscriber on the context's.
mixin CorePageDialogs on EventEmitter {
  /// Supplied by [CorePageOwnership]; the context also receives `dialog`.
  CoreBrowserContext? get browserContext;

  void Function(Dialog dialog)? _dialogHandler;

  /// Registers the dialog handler (replaces any previous one).
  void onDialog(void Function(Dialog dialog) handler) {
    _dialogHandler = handler;
  }

  /// Routes an opened [dialog] to whoever is watching, or auto-dismisses it.
  void dispatchDialog(Dialog dialog) {
    final handler = _dialogHandler;
    final context = browserContext;
    final watchedByPage = listenerCount('dialog') > 0;
    final watchedByContext = context != null && context.listenerCount('dialog') > 0;

    if (handler == null && !watchedByPage && !watchedByContext) {
      dialog.dismiss();
      return;
    }

    if (handler != null) handler(dialog);
    // Dialog.accept/dismiss are idempotent, so reaching several watchers is
    // safe: the first decision wins and the rest are no-ops.
    if (watchedByPage) emit('dialog', dialog);
    if (watchedByContext) context.emit('dialog', dialog);
  }
}

/// Normalizes an engine's console message type.
///
/// Upstream does almost no normalization here: CDP's `Runtime.consoleAPICalled`
/// type and CDP's `Log` level are passed through verbatim, and the single
/// rename in the whole codebase is Juggler's `warn` (`ffPage.ts:290`), because
/// Firefox uses it for browser-generated messages while every other engine and
/// the documented `ConsoleMessage.type()` vocabulary say `warning`. WebKit's
/// two derivations (`log` takes the level, `timing` becomes `timeEnd`) are
/// applied by the WebKit driver before calling this.
String normalizeConsoleType(String? raw) {
  if (raw == null || raw.isEmpty) return 'log';
  return raw == 'warn' ? 'warning' : raw;
}

/// Splits `"TypeError: x is not a function"` into name and message.
///
/// Port of `splitErrorMessage` (`utils/stackTrace.ts:134`): the first colon
/// separates them and the message skips the following `": "`. A message with
/// no colon has an empty name.
({String name, String message}) splitErrorMessage(String message) {
  final index = message.indexOf(':');
  if (index == -1) return (name: '', message: message);
  return (
    name: message.substring(0, index),
    message: index + 2 <= message.length
        ? message.substring(index + 2)
        : message,
  );
}

/// Builds a [CorePageError] from a CDP `Runtime.ExceptionDetails`.
///
/// Port of `exceptionToError` (`chromium/crProtocolHelper.ts:84`): the
/// exception's `description` already carries `Name: message` plus the V8 stack,
/// so the header is everything before the first `    at` line, and the error
/// name can be overridden by the `name` property of the exception preview
/// (which is how a subclass of `Error` reports its own name).
CorePageError pageErrorFromCdpExceptionDetails(Map<String, dynamic> details) {
  final exception = details['exception'] as Map<String, dynamic>?;
  String messageWithStack;
  if (exception != null) {
    messageWithStack =
        exception['description'] as String? ?? '${exception['value']}';
  } else {
    messageWithStack = details['text'] as String? ?? '';
  }

  final lines = messageWithStack.split('\n');
  final firstStackLine =
      lines.indexWhere((line) => line.startsWith('    at'));
  final header = firstStackLine == -1
      ? messageWithStack
      : lines.sublist(0, firstStackLine).join('\n');
  final stack = firstStackLine == -1 ? '' : messageWithStack;

  final split = splitErrorMessage(header);
  var name = split.name;
  final preview = exception?['preview'] as Map<String, dynamic>?;
  final properties = preview?['properties'] as List?;
  if (properties != null) {
    for (final property in properties) {
      if (property is Map && property['name'] == 'name') {
        name = property['value'] as String? ?? 'Error';
        break;
      }
    }
  }
  return CorePageError(name: name, message: split.message, stack: stack);
}

/// Renders one `Runtime.RemoteObject` (CDP, WebKit) or Juggler remote object
/// the way devtools would show it in the console.
///
/// Primitives print as their value; everything else falls back to the
/// engine-provided description (`Object`, `Array(3)`, a function's source).
/// Upstream instead builds a JSHandle per argument and calls `preview()` on
/// it; that needs the whole handle machinery for what is, in practice, the
/// same string for every value a test asserts on.
String describeRemoteObject(dynamic remoteObject) {
  if (remoteObject is! Map) return '${remoteObject ?? ''}';
  final unserializable = remoteObject['unserializableValue'];
  if (unserializable != null) return '$unserializable';
  if (remoteObject.containsKey('value') && remoteObject['objectId'] == null) {
    final value = remoteObject['value'];
    if (value is String) return value;
    return jsonEncode(value);
  }
  final description = remoteObject['description'];
  if (description != null) return '$description';
  if (remoteObject['subtype'] == 'null') return 'null';
  final type = remoteObject['type'];
  if (type == 'undefined') return 'undefined';
  return '${type ?? ''}';
}

/// Joins console call arguments with a space, as the devtools console does.
String describeConsoleArgs(dynamic args) {
  if (args is! List) return '';
  return args.map(describeRemoteObject).join(' ');
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

/// Per-frame evaluation, shared by the engine pages.
///
/// Each engine only has to map a frame to its execution context; everything
/// built on top of evaluation (content, waiters, the selector engine) is
/// implemented once here.
mixin CorePageFrameEvaluation {
  CoreFrame get mainFrame;

  Future<CoreExecutionContext> executionContextFor(CoreFrame frame,
      {Duration? timeout});

  /// Contexts that already have `window.__pwDart` installed. Context ids are
  /// unique per page, so a navigation (which creates a new context) naturally
  /// misses the cache.
  final Set<Object> _injectedContexts = <Object>{};

  Future<dynamic> evaluateInFrame(CoreFrame frame, String expression) async {
    final context = await executionContextFor(frame);
    return context.rawEvaluate(wrapEvaluationExpression(expression));
  }

  Future<CoreJSHandle> evaluateHandleInFrame(
      CoreFrame frame, String expression) async {
    final context = await executionContextFor(frame);
    return context.rawEvaluateHandle(wrapEvaluationExpression(expression));
  }

  Future<CoreExecutionContext> _injectedContext(CoreFrame frame) async {
    final context = await executionContextFor(frame);
    if (_injectedContexts.add(context.contextId)) {
      try {
        await context.rawEvaluate(kInjectedScriptSource);
      } catch (error) {
        _injectedContexts.remove(context.contextId);
        rethrow;
      }
    }
    return context;
  }

  Future<dynamic> evaluateInjected(CoreFrame frame, String expression) async {
    final context = await _injectedContext(frame);
    return context.rawEvaluate(wrapEvaluationExpression(expression));
  }

  Future<CoreJSHandle> evaluateHandleInjected(
      CoreFrame frame, String expression) async {
    final context = await _injectedContext(frame);
    return context.rawEvaluateHandle(wrapEvaluationExpression(expression));
  }

  /// Forgets the injected-script cache for a destroyed context.
  void forgetExecutionContext(Object contextId) {
    _injectedContexts.remove(contextId);
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
    return pollForTruthy(evaluate, expression,
        timeout: timeout, polling: polling);
  }

  /// Replaces the document content and waits for it to reach [waitUntil].
  Future<void> setContent(String html,
      {WaitUntilState? waitUntil, Duration? timeout}) async {
    return setContentVia(evaluate, html,
        waitUntil: waitUntil, timeout: timeout);
  }
}

/// Polls [expression] through [evaluate] until it yields a truthy value.
Future<dynamic> pollForTruthy(
    Future<dynamic> Function(String) evaluate, String expression,
    {Duration? timeout, Duration? polling}) async {
  final effectiveTimeout = timeout ?? const Duration(seconds: 30);
  final interval = polling ?? const Duration(milliseconds: 100);
  final deadline = DateTime.now().add(effectiveTimeout);
  while (true) {
    final value = await evaluate(expression);
    final isTruthy = value != null && value != false && value != 0 && value != '';
    if (isTruthy) return value;
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('waitForFunction: condition not met',
          timeout: effectiveTimeout);
    }
    await Future.delayed(interval);
  }
}

/// Rewrites the document reachable through [evaluate] and waits for
/// [waitUntil].
Future<void> setContentVia(
    Future<dynamic> Function(String) evaluate, String html,
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
  await pollForTruthy(evaluate, '() => $condition', timeout: timeout);
}

/// Shared helpers for protocol-based input.
///
/// Geometry and focus are resolved with injected JS (as upstream Playwright
/// does); the actual mouse/keyboard events are dispatched by each engine
/// through its native protocol so pages receive trusted events.
mixin CorePageInputHelpers {
  Future<dynamic> evaluate(String expression);

  /// Target resolution goes through the injected evaluate: a locator's
  /// resolver expression calls into `window.__pwDart`, which must be present
  /// in the frame's context.
  Future<dynamic> evaluateInjected(CoreFrame frame, String expression);
  CoreFrame get mainFrame;

  /// The page keyboard; classes using this mixin must provide it.
  Keyboard get keyboard;

  /// The page mouse; classes using this mixin must provide it.
  Mouse get mouse;

  /// Clicks the element [resolverJs] resolves to inside [frame].
  Future<void> clickTarget(CoreFrame frame, String resolverJs,
      {String button = 'left',
      int clickCount = 1,
      Duration? delay,
      ({double x, double y})? position}) async {
    final point =
        await clickPointForTarget(frame, resolverJs, position: position);
    await mouse.click(point.x, point.y,
        button: button, clickCount: clickCount, delay: delay);
  }

  /// Double-clicks the element [resolverJs] resolves to inside [frame].
  Future<void> dblclickTarget(CoreFrame frame, String resolverJs,
          {String button = 'left',
          Duration? delay,
          ({double x, double y})? position}) =>
      clickTarget(frame, resolverJs,
          button: button, clickCount: 2, delay: delay, position: position);

  /// Hovers the element [resolverJs] resolves to inside [frame].
  Future<void> hoverTarget(CoreFrame frame, String resolverJs,
      {({double x, double y})? position}) async {
    final point =
        await clickPointForTarget(frame, resolverJs, position: position);
    await mouse.move(point.x, point.y);
  }

  /// Clicks [selector] in the main frame.
  Future<void> click(String selector,
          {String button = 'left',
          int clickCount = 1,
          Duration? delay,
          ({double x, double y})? position}) =>
      clickTarget(mainFrame, resolverForSelector(selector),
          button: button,
          clickCount: clickCount,
          delay: delay,
          position: position);

  /// Double-clicks [selector] in the main frame.
  Future<void> dblclick(String selector,
          {String button = 'left',
          Duration? delay,
          ({double x, double y})? position}) =>
      click(selector,
          button: button, clickCount: 2, delay: delay, position: position);

  /// Hovers [selector] in the main frame.
  Future<void> hover(String selector, {({double x, double y})? position}) =>
      hoverTarget(mainFrame, resolverForSelector(selector), position: position);

  /// A JS expression resolving [selector] in the main document, for the
  /// page-level `click`/`fill`/`press` API.
  static String resolverForSelector(String selector) {
    final sel = jsonEncode(selector);
    return 'document.querySelector($sel)';
  }

  /// Focuses [selector] then presses [key] (or a chord like 'Control+A').
  Future<void> press(String selector, String key) =>
      pressTarget(mainFrame, resolverForSelector(selector), key);

  /// Focuses [selector] then types [text] character by character.
  Future<void> type(String selector, String text) =>
      typeTarget(mainFrame, resolverForSelector(selector), text);

  Future<void> pressTarget(
      CoreFrame frame, String resolverJs, String key) async {
    await focusTarget(frame, resolverJs);
    await keyboard.press(key);
  }

  Future<void> typeTarget(
      CoreFrame frame, String resolverJs, String text) async {
    await focusTarget(frame, resolverJs);
    await keyboard.type(text);
  }

  /// Scrolls [selector] into view and returns the viewport coordinates to
  /// click: the element center, or [position] relative to its top-left.
  Future<({double x, double y})> clickPointFor(String selector,
          {({double x, double y})? position}) =>
      clickPointForTarget(mainFrame, resolverForSelector(selector),
          position: position);

  /// Like [clickPointFor], for an element inside [frame].
  ///
  /// The returned point is in the top-level viewport's coordinates: the
  /// element's rect is shifted by each owning `iframe`'s border box up the
  /// chain, which is how the mouse events (dispatched page-wide) land on it.
  /// Cross-origin frame owners are not reachable from the page, so the walk
  /// stops there.
  Future<({double x, double y})> clickPointForTarget(
      CoreFrame frame, String resolverJs,
      {({double x, double y})? position}) async {
    final offset =
        position == null ? 'null' : '{ x: ${position.x}, y: ${position.y} }';
    final result = await evaluateInjected(frame, '''
      () => {
        const el = $resolverJs;
        if (!el) throw new Error('Element not found');
        el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
        const rect = el.getBoundingClientRect();
        const offset = $offset;
        let x = offset ? rect.x + offset.x : rect.x + rect.width / 2;
        let y = offset ? rect.y + offset.y : rect.y + rect.height / 2;
        let win = el.ownerDocument.defaultView;
        while (win && win !== win.parent) {
          let owner = null;
          try { owner = win.frameElement; } catch (e) { break; }
          if (!owner) break;
          const ownerRect = owner.getBoundingClientRect();
          const style = owner.ownerDocument.defaultView.getComputedStyle(owner);
          x += ownerRect.x + (parseFloat(style.borderLeftWidth) || 0) + (parseFloat(style.paddingLeft) || 0);
          y += ownerRect.y + (parseFloat(style.borderTopWidth) || 0) + (parseFloat(style.paddingTop) || 0);
          win = win.parent;
        }
        return { x, y };
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
  Future<void> focusAndSelect(String selector) =>
      focusAndSelectTarget(mainFrame, resolverForSelector(selector));

  Future<void> focusAndSelectTarget(CoreFrame frame, String resolverJs) {
    return _focusWithRetry(frame, resolverJs, '''
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
  Future<void> focus(String selector) =>
      focusTarget(mainFrame, resolverForSelector(selector));

  Future<void> focusTarget(CoreFrame frame, String resolverJs) =>
      _focusWithRetry(frame, resolverJs, '');

  /// el.focus() can silently fail while a headless window is still being
  /// activated (seen on WebKit macOS, where a later keystroke then lands on
  /// the page and e.g. Backspace navigates back). Verify activeElement and
  /// retry briefly before giving up.
  Future<void> _focusWithRetry(
      CoreFrame frame, String resolverJs, String afterFocusJs) async {
    for (var attempt = 0; attempt < 10; attempt++) {
      final focused = await evaluateInjected(frame, '''
        () => {
          const el = $resolverJs;
          if (!el) throw new Error('Element not found');
          el.focus();
          $afterFocusJs
          return el.ownerDocument.activeElement === el;
        }
      ''');
      if (focused == true) return;
      await Future.delayed(const Duration(milliseconds: 50));
    }
  }
}
