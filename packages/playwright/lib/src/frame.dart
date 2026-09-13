import 'package:playwright_core/src/server/core_element_handle.dart';
import 'package:playwright_core/src/server/core_js_handle.dart';
import 'package:playwright_core/src/server/core_page.dart';
import 'package:playwright_core/src/server/selectors.dart';

import 'element_handle.dart';
import 'js_handle.dart';
import 'locator.dart';
import 'page.dart';

/// A frame within a page.
///
/// Every frame has its own JavaScript execution context, so `evaluate` and the
/// locators created here run against that frame's document, not the page's.
abstract class Frame with LocatorFactory {
  /// The frame's name (the `name`/`id` of the owning `iframe`).
  String name();

  /// The frame's URL.
  String url();

  /// Parent frame, or null for the main frame.
  Frame? parentFrame();

  /// Child frames.
  List<Frame> childFrames();

  /// Whether the frame has been removed from the page.
  bool isDetached();

  /// The page containing this frame.
  Page page();

  // ------------------------------------------------------------ navigation

  /// Navigate this frame to [url].
  Future<void> goto(String url,
      {WaitUntilState? waitUntil, Duration? timeout});

  /// The frame's full HTML.
  Future<String> content();

  /// Replace this frame's document with [html].
  Future<void> setContent(String html,
      {WaitUntilState? waitUntil, Duration? timeout});

  /// The frame document's title.
  Future<String> title();

  /// The `iframe`/`frame` element that owns this frame, in its parent.
  ///
  /// Null for the main frame, and for a frame whose owner lives in a
  /// cross-origin document, which the page cannot reach.
  Future<ElementHandle?> frameElement();

  // ------------------------------------------------------------ evaluation

  /// Evaluate a JavaScript expression in this frame's context.
  Future<dynamic> evaluate(String expression);

  /// Evaluate a JavaScript expression in this frame, returning a handle.
  Future<JSHandle> evaluateHandle(String expression);

  /// The first element matching [selector], or null.
  Future<ElementHandle?> querySelector(String selector);

  /// Every element matching [selector].
  Future<List<ElementHandle>> querySelectorAll(String selector);

  /// Evaluate [expression] with the first element matching [selector].
  Future<dynamic> evalOnSelector(String selector, String expression);

  /// Evaluate [expression] with the array of elements matching [selector].
  Future<dynamic> evalOnSelectorAll(String selector, String expression);

  /// Dispatch a DOM event on the element matching [selector].
  Future<void> dispatchEvent(String selector, String type,
      {Map<String, dynamic>? eventInit, Duration? timeout, bool strict = false});

  // --------------------------------------------------------------- waiting

  /// Poll [expression] in this frame until it is truthy, then return it.
  Future<dynamic> waitForFunction(String expression,
      {Duration? timeout, Duration? polling});

  /// Wait for this frame to reach a load state.
  Future<void> waitForLoadState(
      {WaitUntilState state = WaitUntilState.load, Duration? timeout});

  /// Wait for this frame to navigate.
  Future<void> waitForNavigation(
      {WaitUntilState? waitUntil, Duration? timeout});

  /// Wait until this frame URL matches [url].
  Future<void> waitForURL(Pattern url, {Duration? timeout});

  /// Wait until [selector] reaches [state] in this frame.
  ///
  /// Returns a handle to the element for the attached/visible states, and
  /// null for detached/hidden.
  Future<ElementHandle?> waitForSelector(String selector,
      {WaitForSelectorState state = WaitForSelectorState.visible,
      Duration timeout = kDefaultLocatorTimeout,
      bool strict = false});

  // --------------------------------------------------------------- actions

  /// Click an element in this frame.
  Future<void> click(String selector,
      {String button = 'left',
      int clickCount = 1,
      Duration? delay,
      ({double x, double y})? position,
      Duration? timeout,
      bool strict = false,
      bool force = false});

  /// Double-click an element in this frame.
  Future<void> dblclick(String selector,
      {String button = 'left',
      Duration? delay,
      ({double x, double y})? position,
      Duration? timeout,
      bool strict = false,
      bool force = false});

  /// Hover over an element in this frame.
  Future<void> hover(String selector,
      {({double x, double y})? position,
      Duration? timeout,
      bool strict = false,
      bool force = false});

  /// Fill an input in this frame.
  Future<void> fill(String selector, String text,
      {Duration? timeout, bool strict = false, bool force = false});

  /// Focus an element then press [key].
  Future<void> press(String selector, String key,
      {Duration? timeout, bool strict = false});

  /// Focus an element then type [text] character by character.
  Future<void> type(String selector, String text,
      {Duration? timeout, bool strict = false});

  /// Focus an element in this frame.
  Future<void> focus(String selector,
      {Duration? timeout, bool strict = false});

  /// Check a checkbox/radio in this frame.
  Future<void> check(String selector,
      {Duration? timeout, bool strict = false, bool force = false});

  /// Uncheck a checkbox in this frame.
  Future<void> uncheck(String selector,
      {Duration? timeout, bool strict = false, bool force = false});

  /// Select option(s) of a `<select>` in this frame.
  Future<List<String>> selectOption(String selector, dynamic value,
      {Duration? timeout, bool strict = false, bool force = false});

  // ----------------------------------------------------------------- state

  Future<String> textContent(String selector,
      {Duration? timeout, bool strict = false});
  Future<String> innerText(String selector,
      {Duration? timeout, bool strict = false});
  Future<String> innerHTML(String selector,
      {Duration? timeout, bool strict = false});
  Future<String> inputValue(String selector,
      {Duration? timeout, bool strict = false});
  Future<String?> getAttribute(String selector, String name,
      {Duration? timeout, bool strict = false});
  Future<bool> isVisible(String selector);
  Future<bool> isHidden(String selector);
  Future<bool> isEnabled(String selector, {Duration? timeout});
  Future<bool> isDisabled(String selector, {Duration? timeout});
  Future<bool> isEditable(String selector, {Duration? timeout});
  Future<bool> isChecked(String selector, {Duration? timeout});
}

class FrameImpl extends Frame {
  final CoreFrame _coreFrame;
  final Page _page;

  FrameImpl(this._coreFrame, this._page);

  /// The engine-level frame this wraps.
  CoreFrame get coreFrame => _coreFrame;

  @override
  Locator byParts(List<Map<String, dynamic>> parts) =>
      LocatorImpl(this, ParsedSelector(parts));

  @override
  bool operator ==(Object other) =>
      other is FrameImpl && other._coreFrame == _coreFrame;

  @override
  int get hashCode => _coreFrame.hashCode;

  @override
  String toString() => "Frame(name: '${name()}', url: '${url()}')";

  @override
  String name() => _coreFrame.name;

  @override
  String url() => _coreFrame.url;

  @override
  Frame? parentFrame() {
    final parent = _coreFrame.parentFrame;
    return parent == null ? null : FrameImpl(parent, _page);
  }

  @override
  List<Frame> childFrames() =>
      _coreFrame.childFrames.map((frame) => FrameImpl(frame, _page)).toList();

  @override
  bool isDetached() => _coreFrame.isDetached;

  @override
  Page page() => _page;

  // ------------------------------------------------------------ navigation

  @override
  Future<void> goto(String url,
          {WaitUntilState? waitUntil, Duration? timeout}) =>
      _coreFrame.goto(url, waitUntil: waitUntil, timeout: timeout);

  @override
  Future<String> content() => _coreFrame.content();

  @override
  Future<void> setContent(String html,
          {WaitUntilState? waitUntil, Duration? timeout}) =>
      _coreFrame.setContent(html, waitUntil: waitUntil, timeout: timeout);

  @override
  Future<String> title() => _coreFrame.title();

  @override
  Future<ElementHandle?> frameElement() async {
    final parent = _coreFrame.parentFrame;
    if (parent == null) return null;
    // window.frameElement resolves the owner from inside the child document.
    // It is null across origins, which is exactly when the page cannot reach
    // the owner anyway.
    final hasOwner = await _coreFrame.evaluate('''
      () => {
        try { return !!window.frameElement; } catch (e) { return false; }
      }
    ''');
    if (hasOwner != true) return null;
    final handle =
        await _coreFrame.evaluateHandleInjected('() => window.frameElement');
    final wrapped = FrameImpl(parent, _page).wrapHandle(handle);
    return wrapped is ElementHandle ? wrapped : null;
  }

  // ------------------------------------------------------------ evaluation

  @override
  Future<dynamic> evaluate(String expression) => _coreFrame.evaluate(expression);

  @override
  Future<ElementHandle?> querySelector(String selector) async {
    final target = locator(selector);
    if (await target.count() == 0) return null;
    return target.first.elementHandle();
  }

  @override
  Future<List<ElementHandle>> querySelectorAll(String selector) =>
      locator(selector).elementHandles();

  @override
  Future<dynamic> evalOnSelector(String selector, String expression) =>
      locator(selector).evaluate(expression, strict: false);

  @override
  Future<dynamic> evalOnSelectorAll(String selector, String expression) =>
      locator(selector).evaluateAll(expression);

  @override
  Future<void> dispatchEvent(String selector, String type,
          {Map<String, dynamic>? eventInit,
          Duration? timeout,
          bool strict = false}) =>
      locator(selector).dispatchEvent(type,
          eventInit: eventInit, timeout: timeout, strict: strict);

  @override
  Future<JSHandle> evaluateHandle(String expression) async {
    // Goes through the injected variant so that handles always come back from
    // a context where window.__pwDart exists: ElementHandle's state getters
    // are implemented on top of it.
    final handle = await _coreFrame.evaluateHandleInjected(expression);
    return wrapHandle(handle);
  }

  /// Wraps an engine handle in the public API type.
  JSHandle wrapHandle(CoreJSHandle handle) {
    if (handle is CoreElementHandle) {
      return ElementHandleImpl(handle, frame: this);
    }
    return JSHandleImpl(handle);
  }

  // --------------------------------------------------------------- waiting

  @override
  Future<dynamic> waitForFunction(String expression,
          {Duration? timeout, Duration? polling}) =>
      _coreFrame.waitForFunction(expression,
          timeout: timeout, polling: polling);

  @override
  Future<void> waitForLoadState(
          {WaitUntilState state = WaitUntilState.load, Duration? timeout}) =>
      _coreFrame.waitForLoadState(state, timeout: timeout);

  @override
  Future<void> waitForNavigation(
          {WaitUntilState? waitUntil, Duration? timeout}) =>
      _coreFrame.waitForNavigation(waitUntil: waitUntil, timeout: timeout);

  @override
  Future<void> waitForURL(Pattern url, {Duration? timeout}) =>
      _coreFrame.waitForURL(url, timeout: timeout);

  @override
  Future<ElementHandle?> waitForSelector(String selector,
      {WaitForSelectorState state = WaitForSelectorState.visible,
      Duration timeout = kDefaultLocatorTimeout,
      bool strict = false}) async {
    final target = locator(selector);
    await target.waitFor(state: state, timeout: timeout, strict: strict);
    if (state == WaitForSelectorState.detached ||
        state == WaitForSelectorState.hidden) {
      return null;
    }
    return target.elementHandle(timeout: timeout, strict: strict);
  }

  // --------------------------------------------------------------- actions

  @override
  Future<void> click(String selector,
          {String button = 'left',
          int clickCount = 1,
          Duration? delay,
          ({double x, double y})? position,
          Duration? timeout,
          bool strict = false,
          bool force = false}) =>
      locator(selector).click(
          button: button,
          clickCount: clickCount,
          delay: delay,
          position: position,
          timeout: timeout,
          strict: strict,
          force: force);

  @override
  Future<void> dblclick(String selector,
          {String button = 'left',
          Duration? delay,
          ({double x, double y})? position,
          Duration? timeout,
          bool strict = false,
          bool force = false}) =>
      locator(selector).dblclick(
          button: button,
          delay: delay,
          position: position,
          timeout: timeout,
          strict: strict,
          force: force);

  @override
  Future<void> hover(String selector,
          {({double x, double y})? position,
          Duration? timeout,
          bool strict = false,
          bool force = false}) =>
      locator(selector).hover(
          position: position, timeout: timeout, strict: strict, force: force);

  @override
  Future<void> fill(String selector, String text,
          {Duration? timeout, bool strict = false, bool force = false}) =>
      locator(selector)
          .fill(text, timeout: timeout, strict: strict, force: force);

  @override
  Future<void> press(String selector, String key,
          {Duration? timeout, bool strict = false}) =>
      locator(selector).press(key, timeout: timeout, strict: strict);

  @override
  Future<void> type(String selector, String text,
          {Duration? timeout, bool strict = false}) =>
      locator(selector)
          .pressSequentially(text, timeout: timeout, strict: strict);

  @override
  Future<void> focus(String selector, {Duration? timeout, bool strict = false}) =>
      locator(selector).focus(timeout: timeout, strict: strict);

  @override
  Future<void> check(String selector,
          {Duration? timeout, bool strict = false, bool force = false}) =>
      locator(selector).check(timeout: timeout, strict: strict, force: force);

  @override
  Future<void> uncheck(String selector,
          {Duration? timeout, bool strict = false, bool force = false}) =>
      locator(selector).uncheck(timeout: timeout, strict: strict, force: force);

  @override
  Future<List<String>> selectOption(String selector, dynamic value,
          {Duration? timeout, bool strict = false, bool force = false}) =>
      locator(selector)
          .selectOption(value, timeout: timeout, strict: strict, force: force);

  // ----------------------------------------------------------------- state

  @override
  Future<String> textContent(String selector,
          {Duration? timeout, bool strict = false}) =>
      locator(selector).textContent(timeout: timeout, strict: strict);

  @override
  Future<String> innerText(String selector,
          {Duration? timeout, bool strict = false}) =>
      locator(selector).innerText(timeout: timeout, strict: strict);

  @override
  Future<String> innerHTML(String selector,
          {Duration? timeout, bool strict = false}) =>
      locator(selector).innerHTML(timeout: timeout, strict: strict);

  @override
  Future<String> inputValue(String selector,
          {Duration? timeout, bool strict = false}) =>
      locator(selector).inputValue(timeout: timeout, strict: strict);

  @override
  Future<String?> getAttribute(String selector, String name,
          {Duration? timeout, bool strict = false}) =>
      locator(selector).getAttribute(name, timeout: timeout, strict: strict);

  @override
  Future<bool> isVisible(String selector) => locator(selector).isVisible();

  @override
  Future<bool> isHidden(String selector) => locator(selector).isHidden();

  @override
  Future<bool> isEnabled(String selector, {Duration? timeout}) =>
      locator(selector).isEnabled(timeout: timeout, strict: false);

  @override
  Future<bool> isDisabled(String selector, {Duration? timeout}) =>
      locator(selector).isDisabled(timeout: timeout, strict: false);

  @override
  Future<bool> isEditable(String selector, {Duration? timeout}) =>
      locator(selector).isEditable(timeout: timeout, strict: false);

  @override
  Future<bool> isChecked(String selector, {Duration? timeout}) =>
      locator(selector).isChecked(timeout: timeout, strict: false);
}
