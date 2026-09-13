import 'dart:async';

import 'package:playwright_core/src/server/core_events.dart' as core_events;
import 'package:playwright_core/src/server/core_page.dart' hide Dialog;
import 'package:playwright_core/src/server/dialog.dart' as core;
// WaitForSelectorState is also declared by locator.dart, which is the one the
// public API uses.
import 'package:playwright_protocol/playwright_protocol.dart'
    hide WaitForSelectorState;
import 'browser_context.dart';
import 'console_message.dart';
import 'download.dart';
import 'file_chooser.dart';
import 'page_error.dart';
import 'waiter.dart';
import 'locator.dart';
import 'frame.dart';
import 'frame_locator.dart';
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

  /// Wait for [timeout] to elapse.
  ///
  /// Never wait on a fixed delay in a test: it is flaky when the machine is
  /// slow and wasteful when it is fast. Use [waitForSelector],
  /// [waitForFunction] or [waitForLoadState] instead. This exists because
  /// upstream has it, and it is honest for debugging and for scripting a page
  /// whose readiness has no observable signal.
  Future<void> waitForTimeout(Duration timeout);

  /// Get the page title.
  Future<String> title();

  /// Take a screenshot of the page.
  ///
  /// [type] is `png`, `jpeg` or `webp`; [quality] (0-100) only applies to the
  /// lossy ones. [fullPage] captures the whole scrollable document. [clip] is
  /// a rectangle in CSS pixels, relative to the viewport (or to the document
  /// when [fullPage] is set). [scale] is `device` (the default, honouring the
  /// device pixel ratio) or `css`.
  ///
  /// Not implemented yet: `omitBackground`, `mask`, `caret`, `animations` and
  /// `style`.
  Future<List<int>> screenshot({
    String? path,
    String type = 'png',
    int? quality,
    bool fullPage = false,
    ({double x, double y, double width, double height})? clip,
    String scale = 'device',
  });

  /// Render the page to PDF.
  ///
  /// **Chromium only.** Neither the Juggler nor the WebKit protocol has a
  /// print-to-PDF command, and upstream Playwright has the same limit; the
  /// other two engines throw [UnsupportedError].
  ///
  /// Sizes are in inches. [format] names a paper size (`letter`, `legal`,
  /// `tabloid`, `ledger`, `a0`..`a6`) and wins over [width]/[height].
  Future<List<int>> pdf({
    String? path,
    bool landscape = false,
    bool displayHeaderFooter = false,
    String headerTemplate = '',
    String footerTemplate = '',
    bool printBackground = false,
    double scale = 1,
    String? format,
    double? width,
    double? height,
    double marginTop = 0,
    double marginBottom = 0,
    double marginLeft = 0,
    double marginRight = 0,
    String pageRanges = '',
    bool preferCSSPageSize = false,
    bool tagged = false,
    bool outline = false,
  });

  /// Get the accessibility snapshot.
  Future<AccessibilitySnapshot> accessibilitySnapshot();

  /// Resize the page viewport.
  ///
  /// Overrides the viewport the context was created with, for this page only.
  Future<void> setViewportSize(int width, int height);

  /// Point the `<input type=file>` matched by [selector] at [paths].
  Future<void> setInputFiles(String selector, List<String> paths,
      {Duration? timeout});

  /// Turn file chooser interception on or off.
  ///
  /// Reading [onFileChooser] or calling [waitForFileChooser] turns it on for
  /// you; this is here for turning it back off.
  Future<void> setInterceptFileChooser(bool enabled);

  /// Set headers sent with every request this page makes.
  ///
  /// Replaces the previous set; pass an empty map to clear it. Names keep the
  /// casing given here. Headers set this way are not merged with the ones a
  /// request already carries: a name that collides wins.
  Future<void> setExtraHTTPHeaders(Map<String, String> headers);

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

  /// Create a locator for an element in the page's main frame.
  ///
  /// [hasText], [hasNotText], [has] and [hasNot] narrow the match the same way
  /// upstream's `locator(selector, { ... })` options do.
  Locator locator(String selector,
      {Pattern? hasText, Pattern? hasNotText, Locator? has, Locator? hasNot});

  /// The page's main frame.
  Frame mainFrame();

  /// All frames attached to the page, main frame included.
  List<Frame> frames();

  /// The frame with the given [name], or whose URL matches [url].
  ///
  /// Returns null when no frame matches.
  Frame? frame({String? name, Pattern? url});

  /// A view into the iframe matched by [selector], resolved lazily.
  FrameLocator frameLocator(String selector);

  /// Locate an element by its ARIA role, in the main frame.
  Locator getByRole(String role,
      {Object? checked,
      bool? disabled,
      bool? expanded,
      bool? includeHidden,
      int? level,
      Pattern? name,
      Object? pressed,
      bool? selected,
      Pattern? description,
      bool exact = false});

  /// Locate an element containing [text], in the main frame.
  Locator getByText(Pattern text, {bool exact = false});

  /// Locate a form control by its label, in the main frame.
  Locator getByLabel(Pattern text, {bool exact = false});

  /// Locate an input by its placeholder, in the main frame.
  Locator getByPlaceholder(Pattern text, {bool exact = false});

  /// Locate an element by its `alt` attribute, in the main frame.
  Locator getByAltText(Pattern text, {bool exact = false});

  /// Locate an element by its `title` attribute, in the main frame.
  Locator getByTitle(Pattern text, {bool exact = false});

  /// Locate an element by its test id attribute, in the main frame.
  Locator getByTestId(Pattern testId,
      {String attributeName = Selectors.defaultTestIdAttribute});

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

  /// The page mouse, dispatching trusted mouse events via the protocol.
  Mouse get mouse;

  /// Focus [selector] then press [key] (or a chord like 'Control+A').
  Future<void> press(String selector, String key);

  /// Focus [selector] then type [text] character by character.
  Future<void> type(String selector, String text);

  /// Event emitted when a JavaScript dialog (alert/confirm/prompt/
  /// beforeunload) opens.
  ///
  /// A dialog blocks the page until it is accepted or dismissed. As upstream
  /// does, a dialog that nobody is listening for is dismissed automatically,
  /// so an unexpected `alert()` cannot hang the script. Subscribing here (or
  /// on the context) takes that responsibility over: the dialog then stays
  /// open until you call [Dialog.accept] or [Dialog.dismiss].
  Stream<Dialog> get onDialog;

  /// Get the full HTML content of the page.
  Future<String> content();

  /// Get the current URL of the page.
  Future<String> url();

  /// Wait until [selector] reaches [state] in the main frame, or throw on
  /// timeout. Returns a handle for the attached/visible states, null
  /// otherwise.
  Future<ElementHandle?> waitForSelector(String selector,
      {WaitForSelectorState state = WaitForSelectorState.visible,
      Duration timeout = kDefaultLocatorTimeout,
      bool strict = false});

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

  /// Event emitted when the page logs to the console.
  Stream<ConsoleMessage> get onConsole;

  /// Event emitted when an exception reaches the top level of the page.
  Stream<PageError> get onPageError;

  /// Event emitted when the page opens a new one (`window.open`, or a link
  /// with `target=_blank`).
  ///
  /// The popup is already attached when it arrives, but it may not have
  /// navigated yet: await [waitForLoadState] on it before reading its
  /// content.
  Stream<Page> get onPopup;

  /// Event emitted when the page opens a file chooser.
  ///
  /// Reading this getter turns interception on, because a chooser that was
  /// not intercepted has already become a native dialog by the time anyone
  /// could listen. Use [setInterceptFileChooser] to turn it back off.
  Stream<FileChooser> get onFileChooser;

  /// Wait for the page to open a file chooser.
  Future<FileChooser> waitForFileChooser({Duration? timeout});

  /// Event emitted when the page starts a download.
  ///
  /// Whether downloads happen at all is a context option; see
  /// `Browser.newContext(acceptDownloads:)`.
  Stream<Download> get onDownload;

  /// Wait for the page to start a download.
  Future<Download> waitForDownload({Duration? timeout});

  /// Event emitted when the page's renderer crashes.
  ///
  /// The page becomes unusable; every pending operation on it fails.
  Stream<void> get onCrash;

  /// Wait for the page to open a popup.
  ///
  /// Start the wait before the action that triggers it, then await both, or
  /// the popup may open before anybody is listening.
  Future<Page> waitForPopup({Duration? timeout});

  /// Wait for a console message matching [predicate].
  Future<ConsoleMessage> waitForConsoleMessage(
      {bool Function(ConsoleMessage)? predicate, Duration? timeout});

  /// Wait for a dialog matching [predicate].
  Future<Dialog> waitForDialog(
      {bool Function(Dialog)? predicate, Duration? timeout});

  /// The page that opened this one, or null.
  ///
  /// Null once the opener has closed, matching upstream.
  Page? opener();

  /// The context this page belongs to.
  BrowserContext context();

  /// Whether the page has been closed.
  bool isClosed();

  /// Wait for the next occurrence of a page event.
  Future<T> waitForEvent<T>(String event, {Duration? timeout});
}

/// Public wrappers, keyed by the core page they wrap.
///
/// `context.pages()`, `page.opener()` and the `page`/`popup` events all have
/// to hand back the *same* [Page] object for the same underlying page, or
/// identity comparisons in user code silently fail.
final Expando<PageImpl> _pageWrappers = Expando<PageImpl>('playwright.page');

class PageImpl implements Page {
  final CorePage _corePage;

  PageImpl(this._corePage);

  /// The single wrapper for [corePage], created on first use.
  factory PageImpl.forCore(CorePage corePage) =>
      _pageWrappers[corePage] ??= PageImpl(corePage);

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
  Future<void> waitForTimeout(Duration timeout) =>
      Future<void>.delayed(timeout);

  @override
  Future<String> title() => _corePage.title();

  @override
  Future<List<int>> screenshot({
    String? path,
    String type = 'png',
    int? quality,
    bool fullPage = false,
    ({double x, double y, double width, double height})? clip,
    String scale = 'device',
  }) =>
      _corePage.screenshot(
        path: path,
        options: CoreScreenshotOptions(
          type: type,
          quality: quality,
          fullPage: fullPage,
          clip: clip == null
              ? null
              : CoreRect(
                  x: clip.x,
                  y: clip.y,
                  width: clip.width,
                  height: clip.height),
          scale: scale,
        ),
      );

  @override
  Future<List<int>> pdf({
    String? path,
    bool landscape = false,
    bool displayHeaderFooter = false,
    String headerTemplate = '',
    String footerTemplate = '',
    bool printBackground = false,
    double scale = 1,
    String? format,
    double? width,
    double? height,
    double marginTop = 0,
    double marginBottom = 0,
    double marginLeft = 0,
    double marginRight = 0,
    String pageRanges = '',
    bool preferCSSPageSize = false,
    bool tagged = false,
    bool outline = false,
  }) =>
      _corePage.pdf(
        path: path,
        options: CorePdfOptions(
          landscape: landscape,
          displayHeaderFooter: displayHeaderFooter,
          headerTemplate: headerTemplate,
          footerTemplate: footerTemplate,
          printBackground: printBackground,
          scale: scale,
          format: format,
          width: width,
          height: height,
          marginTop: marginTop,
          marginBottom: marginBottom,
          marginLeft: marginLeft,
          marginRight: marginRight,
          pageRanges: pageRanges,
          preferCSSPageSize: preferCSSPageSize,
          tagged: tagged,
          outline: outline,
        ),
      );

  @override
  Future<AccessibilitySnapshot> accessibilitySnapshot() =>
      _corePage.accessibilitySnapshot();

  @override
  Future<void> setViewportSize(int width, int height) =>
      _corePage.setViewportSize(width, height);

  @override
  Future<void> setExtraHTTPHeaders(Map<String, String> headers) =>
      _corePage.setExtraHTTPHeaders(headers);

  @override
  Future<void> setInputFiles(String selector, List<String> paths,
          {Duration? timeout}) =>
      locator(selector).setInputFiles(paths, timeout: timeout, strict: false);

  @override
  Future<void> setInterceptFileChooser(bool enabled) =>
      _corePage.setInterceptFileChooser(enabled);

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
  Mouse get mouse => _corePage.mouse;

  @override
  Future<void> press(String selector, String key) =>
      _corePage.press(selector, key);

  @override
  Future<void> type(String selector, String text) =>
      _corePage.type(selector, text);

  @override
  Stream<Dialog> get onDialog => _corePage
      .stream<core.Dialog>('dialog')
      .map((coreDialog) => DialogImpl(coreDialog));

  @override
  Future<dynamic> evaluate(String expression) => _corePage.evaluate(expression);

  @override
  Future<JSHandle> evaluateHandle(String expression) =>
      _mainFrame.evaluateHandle(expression);

  /// The main frame, typed so locators can be built from it.
  FrameImpl get _mainFrame => FrameImpl(_corePage.mainFrame, this);

  @override
  Locator locator(String selector,
          {Pattern? hasText,
          Pattern? hasNotText,
          Locator? has,
          Locator? hasNot}) =>
      _mainFrame.locator(selector,
          hasText: hasText, hasNotText: hasNotText, has: has, hasNot: hasNot);

  @override
  Frame mainFrame() => _mainFrame;

  @override
  List<Frame> frames() =>
      _corePage.frames.map((frame) => FrameImpl(frame, this)).toList();

  @override
  Frame? frame({String? name, Pattern? url}) {
    for (final frame in _corePage.frames) {
      if (name != null && frame.name == name) return FrameImpl(frame, this);
      if (url != null && _matchesUrl(url, frame.url)) {
        return FrameImpl(frame, this);
      }
    }
    return null;
  }

  static bool _matchesUrl(Pattern pattern, String value) {
    if (pattern is RegExp) return pattern.hasMatch(value);
    return value == pattern.toString();
  }

  @override
  FrameLocator frameLocator(String selector) =>
      _mainFrame.frameLocator(selector);

  @override
  Locator getByRole(String role,
          {Object? checked,
          bool? disabled,
          bool? expanded,
          bool? includeHidden,
          int? level,
          Pattern? name,
          Object? pressed,
          bool? selected,
          Pattern? description,
          bool exact = false}) =>
      _mainFrame.getByRole(role,
          checked: checked,
          disabled: disabled,
          expanded: expanded,
          includeHidden: includeHidden,
          level: level,
          name: name,
          pressed: pressed,
          selected: selected,
          description: description,
          exact: exact);

  @override
  Locator getByText(Pattern text, {bool exact = false}) =>
      _mainFrame.getByText(text, exact: exact);

  @override
  Locator getByLabel(Pattern text, {bool exact = false}) =>
      _mainFrame.getByLabel(text, exact: exact);

  @override
  Locator getByPlaceholder(Pattern text, {bool exact = false}) =>
      _mainFrame.getByPlaceholder(text, exact: exact);

  @override
  Locator getByAltText(Pattern text, {bool exact = false}) =>
      _mainFrame.getByAltText(text, exact: exact);

  @override
  Locator getByTitle(Pattern text, {bool exact = false}) =>
      _mainFrame.getByTitle(text, exact: exact);

  @override
  Locator getByTestId(Pattern testId,
          {String attributeName = Selectors.defaultTestIdAttribute}) =>
      _mainFrame.getByTestId(testId, attributeName: attributeName);

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
  Future<ElementHandle?> waitForSelector(String selector,
          {WaitForSelectorState state = WaitForSelectorState.visible,
          Duration timeout = kDefaultLocatorTimeout,
          bool strict = false}) =>
      _mainFrame.waitForSelector(selector,
          state: state, timeout: timeout, strict: strict);

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
  Stream<ConsoleMessage> get onConsole => _corePage
      .stream<core_events.CoreConsoleMessage>('console')
      .map((message) => ConsoleMessageImpl(message));

  @override
  Stream<PageError> get onPageError => _corePage
      .stream<core_events.CorePageError>('pageerror')
      .map((error) => PageErrorImpl(error));

  @override
  Stream<Page> get onPopup =>
      _corePage.stream<CorePage>('popup').map(PageImpl.forCore);

  @override
  Stream<void> get onCrash => _corePage.stream<void>('crash');

  /// Interception is turned on the first time anybody asks for the stream;
  /// re-arming it is cheap and idempotent on all three engines.
  @override
  Stream<FileChooser> get onFileChooser {
    _corePage.setInterceptFileChooser(true).catchError((Object _) {});
    return _corePage.stream<CoreFileChooser>('filechooser').map((chooser) =>
        FileChooserImpl(this, chooser, (paths) async {
          final frame = _corePage.mainFrame;
          await _corePage.setInputFilePaths(frame, chooser.element, paths);
        }));
  }

  @override
  Stream<Download> get onDownload =>
      _corePage.stream<CoreDownload>('download').map(DownloadImpl.new);

  @override
  Future<Download> waitForDownload({Duration? timeout}) => waitForStreamEvent(
        'download',
        onDownload,
        timeout: timeout,
        abortOn: _pageAborts,
      );

  @override
  Future<FileChooser> waitForFileChooser({Duration? timeout}) =>
      waitForStreamEvent(
        'filechooser',
        onFileChooser,
        timeout: timeout,
        abortOn: _pageAborts,
      );

  /// The waits that a page-scoped waiter gives up on: the page closing and
  /// the page crashing, exactly the two upstream registers.
  List<WaitAbort> get _pageAborts => [
        (
          stream: onClose,
          error: () => TargetClosedException('Page closed'),
        ),
        (
          stream: onCrash,
          error: () => PlaywrightException('Page crashed'),
        ),
      ];

  @override
  Future<Page> waitForPopup({Duration? timeout}) => waitForStreamEvent(
        'popup',
        onPopup,
        timeout: timeout,
        abortOn: _pageAborts,
      );

  @override
  Future<ConsoleMessage> waitForConsoleMessage(
          {bool Function(ConsoleMessage)? predicate, Duration? timeout}) =>
      waitForStreamEvent(
        'console',
        onConsole,
        predicate: predicate,
        timeout: timeout,
        abortOn: _pageAborts,
      );

  @override
  Future<Dialog> waitForDialog(
          {bool Function(Dialog)? predicate, Duration? timeout}) =>
      waitForStreamEvent(
        'dialog',
        onDialog,
        predicate: predicate,
        timeout: timeout,
        abortOn: _pageAborts,
      );

  @override
  Page? opener() {
    final opener = _corePage.opener;
    if (opener == null || opener.isClosed) return null;
    return PageImpl.forCore(opener);
  }

  @override
  BrowserContext context() {
    final context = _corePage.browserContext;
    if (context == null) {
      throw PlaywrightException('Page does not belong to a browser context');
    }
    return BrowserContextImpl.forCore(context);
  }

  @override
  bool isClosed() => _corePage.isClosed;

  @override
  Future<T> waitForEvent<T>(String event, {Duration? timeout}) {
    return _corePage.waitForEvent<T>(event, timeout: timeout);
  }
}
