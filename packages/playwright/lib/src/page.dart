import 'package:playwright_core/src/server/core_page.dart' hide Dialog;
import 'package:playwright_core/src/server/dialog.dart' as core;
import 'package:playwright_core/src/server/core_element_handle.dart';
import 'locator.dart';
import 'frame.dart';
import 'js_handle.dart';
import 'element_handle.dart';
import 'route.dart';
import 'dialog.dart';
import 'network.dart';
import 'package:playwright_core/src/accessibility.dart';

export 'package:playwright_core/src/server/core_page.dart' show WaitUntilState;

/// A single tab or page in a browser.
abstract class Page {
  /// Navigate to a URL.
  Future<void> goto(String url, {WaitUntilState? waitUntil, Duration? timeout});

  /// Wait for the page to reach a specific load state.
  Future<void> waitForLoadState(
      {WaitUntilState state = WaitUntilState.load, Duration? timeout});

  /// Wait for the page to navigate to a new URL.
  Future<void> waitForNavigation(
      {WaitUntilState? waitUntil, Duration? timeout});

  /// Wait until the main frame URL matches [url].
  Future<void> waitForURL(Pattern url, {Duration? timeout});

  /// Reload the page and wait for the navigation to reach [waitUntil].
  Future<void> reload({WaitUntilState? waitUntil});

  /// Navigate back in history. Returns false when there is no entry.
  Future<bool> goBack({WaitUntilState? waitUntil});

  /// Navigate forward in history. Returns false when there is no entry.
  Future<bool> goForward({WaitUntilState? waitUntil});

  /// Replace the document content and wait for it to reach [waitUntil].
  Future<void> setContent(String html,
      {WaitUntilState? waitUntil, Duration? timeout});

  /// Poll [expression] until it evaluates to a truthy value and return it.
  Future<dynamic> waitForFunction(String expression,
      {Duration? timeout, Duration? polling});

  /// Get the page title.
  Future<String> title();

  /// Take a screenshot of the page.
  Future<List<int>> screenshot({String? path});

  /// Get the accessibility snapshot.
  Future<AccessibilitySnapshot> accessibilitySnapshot();

  /// Intercept network requests.
  Future<void> route(String urlPattern, void Function(Route) handler);

  /// Remove the route handler for [urlPattern].
  Future<void> unroute(String urlPattern);

  /// Remove all route handlers.
  Future<void> unrouteAll();

  /// Evaluate JavaScript expression in the page.
  Future<dynamic> evaluate(String expression);

  /// Evaluate JavaScript expression and return a handle.
  Future<JSHandle> evaluateHandle(String expression);

  /// Create a locator for an element.
  Locator locator(String selector);

  /// The page's main frame.
  Frame mainFrame();

  /// All frames attached to the page.
  List<Frame> frames();

  /// Click an element using trusted protocol-level input events.
  ///
  /// [button] is 'left', 'middle' or 'right'. [position] is an offset from
  /// the element's top-left corner (defaults to its center). [delay] is
  /// held between press and release.
  Future<void> click(String selector,
      {String button = 'left',
      int clickCount = 1,
      Duration? delay,
      ({double x, double y})? position});

  /// Double-click an element using trusted protocol-level input events.
  Future<void> dblclick(String selector,
      {String button = 'left',
      Duration? delay,
      ({double x, double y})? position});

  /// Hover over an element using a trusted protocol-level mouse move.
  Future<void> hover(String selector, {({double x, double y})? position});

  /// Fill an element with text using trusted protocol-level input events.
  Future<void> fill(String selector, String text);

  /// The page keyboard, dispatching trusted key events via the protocol.
  Keyboard get keyboard;

  /// Focus [selector] then press [key] (or a chord like 'Control+A').
  Future<void> press(String selector, String key);

  /// Focus [selector] then type [text] character by character.
  Future<void> type(String selector, String text);

  /// Register a handler for JavaScript dialogs (alert/confirm/prompt).
  /// Without a handler, dialogs are auto-dismissed.
  void onDialog(void Function(Dialog dialog) handler);

  /// Get the full HTML content of the page.
  Future<String> content();

  /// Get the current URL of the page.
  Future<String> url();

  /// Wait until [selector] matches an element, or throw on timeout.
  Future<void> waitForSelector(String selector,
      {Duration timeout = const Duration(seconds: 30)});

  /// Close the page.
  Future<void> close();

  /// Event emitted when the page closes.
  Stream<void> get onClose;

  /// Event emitted when the main frame fires the load event.
  Stream<void> get onLoad;

  /// Event emitted when the main frame fires DOMContentLoaded.
  Stream<void> get onDomContentLoaded;

  /// Event emitted when a frame is attached.
  Stream<Frame> get onFrameAttached;

  /// Event emitted when a frame navigates.
  Stream<Frame> get onFrameNavigated;

  /// Event emitted when a frame is detached.
  Stream<Frame> get onFrameDetached;

  /// Event emitted when a request is issued by the page.
  Stream<Request> get onRequest;

  /// Event emitted when a response is received.
  Stream<Response> get onResponse;

  /// Event emitted when a request finishes successfully.
  Stream<Request> get onRequestFinished;

  /// Event emitted when a request fails.
  Stream<Request> get onRequestFailed;

  /// Wait for a request matching the [predicate].
  Future<Request> waitForRequest(
      {bool Function(Request)? predicate, Duration? timeout});

  /// Wait for a response matching the [predicate].
  Future<Response> waitForResponse(
      {bool Function(Response)? predicate, Duration? timeout});

  /// Wait for the next occurrence of a page event.
  Future<T> waitForEvent<T>(String event, {Duration? timeout});
}

class PageImpl implements Page {
  final CorePage _corePage;

  PageImpl(this._corePage);

  @override
  Future<void> goto(String url,
          {WaitUntilState? waitUntil, Duration? timeout}) =>
      _corePage.goto(url, waitUntil: waitUntil, timeout: timeout);

  @override
  Future<void> waitForLoadState(
          {WaitUntilState state = WaitUntilState.load, Duration? timeout}) =>
      _corePage.waitForLoadState(state: state, timeout: timeout);

  @override
  Future<void> waitForNavigation(
          {WaitUntilState? waitUntil, Duration? timeout}) =>
      _corePage.waitForNavigation(waitUntil: waitUntil, timeout: timeout);

  @override
  Future<void> waitForURL(Pattern url, {Duration? timeout}) =>
      _corePage.mainFrame.waitForURL(url, timeout: timeout);

  @override
  Future<void> reload({WaitUntilState? waitUntil}) =>
      _corePage.reload(waitUntil: waitUntil);

  @override
  Future<bool> goBack({WaitUntilState? waitUntil}) =>
      _corePage.goBack(waitUntil: waitUntil);

  @override
  Future<bool> goForward({WaitUntilState? waitUntil}) =>
      _corePage.goForward(waitUntil: waitUntil);

  @override
  Future<void> setContent(String html,
          {WaitUntilState? waitUntil, Duration? timeout}) =>
      _corePage.setContent(html, waitUntil: waitUntil, timeout: timeout);

  @override
  Future<dynamic> waitForFunction(String expression,
          {Duration? timeout, Duration? polling}) =>
      _corePage.waitForFunction(expression,
          timeout: timeout, polling: polling);

  @override
  Future<String> title() => _corePage.title();

  @override
  Future<List<int>> screenshot({String? path}) =>
      _corePage.screenshot(path: path);

  @override
  Future<AccessibilitySnapshot> accessibilitySnapshot() =>
      _corePage.accessibilitySnapshot();

  final _routePatterns = <String>{};

  @override
  Future<void> route(String urlPattern, void Function(Route) handler) async {
    _routePatterns.add(urlPattern);
    await _corePage.route(urlPattern, (crRoute) {
      final routeImpl = RouteImpl(crRoute);
      handler(routeImpl);
    });
  }

  @override
  Future<void> unroute(String urlPattern) async {
    _routePatterns.remove(urlPattern);
    await _corePage.unroute(urlPattern);
  }

  @override
  Future<void> unrouteAll() async {
    for (final pattern in _routePatterns.toList()) {
      await unroute(pattern);
    }
  }

  @override
  Keyboard get keyboard => _corePage.keyboard;

  @override
  Future<void> press(String selector, String key) =>
      _corePage.press(selector, key);

  @override
  Future<void> type(String selector, String text) =>
      _corePage.type(selector, text);

  @override
  void onDialog(void Function(Dialog dialog) handler) {
    _corePage.onDialog((core.Dialog coreDialog) {
      handler(DialogImpl(coreDialog));
    });
  }

  @override
  Future<dynamic> evaluate(String expression) => _corePage.evaluate(expression);

  @override
  Future<JSHandle> evaluateHandle(String expression) async {
    final handle = await _corePage.evaluateHandle(expression);
    // Cast appropriately based on the handle type returned
    if (handle is CoreElementHandle) {
      return ElementHandleImpl(handle);
    }
    return JSHandleImpl(handle);
  }

  @override
  Locator locator(String selector) {
    return LocatorImpl(this, selector);
  }

  @override
  Frame mainFrame() => FrameImpl(_corePage.mainFrame, this);

  @override
  List<Frame> frames() =>
      _corePage.frames.map((frame) => FrameImpl(frame, this)).toList();

  @override
  Future<void> click(String selector,
          {String button = 'left',
          int clickCount = 1,
          Duration? delay,
          ({double x, double y})? position}) =>
      _corePage.click(selector,
          button: button,
          clickCount: clickCount,
          delay: delay,
          position: position);

  @override
  Future<void> dblclick(String selector,
          {String button = 'left',
          Duration? delay,
          ({double x, double y})? position}) =>
      _corePage.dblclick(selector,
          button: button, delay: delay, position: position);

  @override
  Future<void> hover(String selector, {({double x, double y})? position}) =>
      _corePage.hover(selector, position: position);

  @override
  Future<void> fill(String selector, String text) =>
      _corePage.fill(selector, text);

  @override
  Future<String> content() async {
    final result =
        await _corePage.evaluate('() => document.documentElement.outerHTML');
    return result.toString();
  }

  @override
  Future<String> url() async {
    final result = await _corePage.evaluate('() => window.location.href');
    return result.toString();
  }

  @override
  Future<void> waitForSelector(String selector,
      {Duration timeout = const Duration(seconds: 30)}) {
    return LocatorImpl(this, selector).waitFor(timeout: timeout);
  }

  @override
  Future<void> close() => _corePage.close();

  @override
  Stream<void> get onClose => _corePage.stream<void>('close');

  @override
  Stream<void> get onLoad => _corePage.stream<void>('load');

  @override
  Stream<void> get onDomContentLoaded =>
      _corePage.stream<void>('domcontentloaded');

  @override
  Stream<Frame> get onFrameAttached =>
      _corePage.stream('frameAttached').map((frame) => FrameImpl(frame, this));

  @override
  Stream<Frame> get onFrameNavigated =>
      _corePage.stream('frameNavigated').map((frame) => FrameImpl(frame, this));

  @override
  Stream<Frame> get onFrameDetached =>
      _corePage.stream('frameDetached').map((frame) => FrameImpl(frame, this));

  @override
  Stream<Request> get onRequest =>
      _corePage.stream('request').map((r) => RequestImpl(r));

  @override
  Stream<Response> get onResponse =>
      _corePage.stream('response').map((r) => ResponseImpl(r));

  @override
  Stream<Request> get onRequestFinished =>
      _corePage.stream('requestFinished').map((r) => RequestImpl(r));

  @override
  Stream<Request> get onRequestFailed =>
      _corePage.stream('requestFailed').map((r) => RequestImpl(r));

  @override
  Future<Request> waitForRequest(
      {bool Function(Request)? predicate, Duration? timeout}) async {
    final stream = predicate == null ? onRequest : onRequest.where(predicate);
    return timeout == null ? stream.first : stream.first.timeout(timeout);
  }

  @override
  Future<Response> waitForResponse(
      {bool Function(Response)? predicate, Duration? timeout}) async {
    final stream = predicate == null ? onResponse : onResponse.where(predicate);
    return timeout == null ? stream.first : stream.first.timeout(timeout);
  }

  @override
  Future<T> waitForEvent<T>(String event, {Duration? timeout}) {
    return _corePage.waitForEvent<T>(event, timeout: timeout);
  }
}
