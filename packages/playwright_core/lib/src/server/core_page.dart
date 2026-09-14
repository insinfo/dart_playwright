import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:playwright_protocol/playwright_protocol.dart';
import '../accessibility.dart';
import 'core_browser.dart';
import 'core_coverage.dart';
import 'core_events.dart';
import 'core_file_chooser.dart';
import 'core_screenshot.dart';
import 'dialog.dart';
import 'trace/trace_utils.dart';
import 'keyboard.dart';
import 'core_js_handle.dart';
import 'core_route.dart';
import 'frames.dart';
import 'mouse.dart';
import 'injected/injected_script_source.dart';
import 'init_scripts.dart';
export 'core_download.dart' show CoreDownload;
export 'core_file_chooser.dart' show CoreFileChooser;
export 'core_screenshot.dart' show CoreRect, CoreScreenshotOptions;
export 'core_events.dart'
    show CoreConsoleMessage, CorePageError, CoreSourceLocation;
export 'dialog.dart' show Dialog;
export 'keyboard.dart' show Keyboard;
export 'mouse.dart' show Mouse, RawMouse, RawTouchscreen, Touchscreen;
export 'frames.dart' show CoreFrame, CoreFrameManager;
export 'core_coverage.dart';
export 'init_scripts.dart'
    show
        CoreBinding,
        CoreBindingCallback,
        CoreBindingSource,
        CoreBrowserContextBindings,
        CoreInitScript,
        CorePageInitScripts,
        initScriptSource,
        kBindingChannelName;

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
  /// Stable identifier for this page, in upstream's `page@<32 hex>` shape.
  ///
  /// The trace format keys pages by it: every `page`, `pageClosed`, console
  /// and snapshot event carries a `pageId`, and the viewer groups the timeline
  /// by page from that. Nothing else in the port needs it, so it is minted
  /// here and never sent to an engine.
  String get guid;

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
  Future<List<int>> screenshot(
      {String? path,
      CoreScreenshotOptions options = const CoreScreenshotOptions()});

  /// Captures exactly [rect], given in document coordinates.
  ///
  /// Document coordinates are the one system all three engines accept:
  /// Chromium's `clip` and Firefox's `clip` are always document-relative, and
  /// WebKit takes `coordinateSystem: 'Page'` for the same thing.
  Future<List<int>> screenshotRect(CoreRect rect, CoreScreenshotOptions options,
      {bool fitsViewport = true});

  /// Renders the page to PDF.
  ///
  /// Chromium only; Firefox and WebKit have no print-to-PDF command in their
  /// protocols, so they throw.
  Future<List<int>> pdf({String? path, CorePdfOptions options});

  /// The accessibility tree of the page's main frame.
  ///
  /// See [CorePageAccessibility.accessibilitySnapshot].
  Future<AccessibilitySnapshot> accessibilitySnapshot(
      {bool interestingOnly = true, CoreFrame? frame});

  /// The aria snapshot YAML of the page's main frame.
  ///
  /// See [CorePageAccessibility.ariaSnapshot].
  Future<String> ariaSnapshot({CoreFrame? frame, String? selectorJs});

  /// Resizes the page viewport, overriding whatever the context set.
  Future<void> setViewportSize(int width, int height);

  /// Points the `<input type=file>` behind [handle] at [paths].
  ///
  /// The engines take file paths, not contents, so the files must exist on
  /// the machine running the browser.
  Future<void> setInputFilePaths(
      CoreFrame frame, CoreJSHandle handle, List<String> paths);

  /// Turns file chooser interception on or off.
  ///
  /// While on, the page never shows the native dialog and a `filechooser`
  /// event carrying a [CoreFileChooser] is emitted instead.
  Future<void> setInterceptFileChooser(bool enabled);

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
  Future<CoreJSHandle> evaluateHandleInFrame(
      CoreFrame frame, String expression);

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

  /// The page's touchscreen. Taps only reach the page when the context was
  /// created with `hasTouch`.
  Touchscreen get touchscreen;

  /// Taps the element [resolverJs] resolves to inside [frame].
  Future<void> tapTarget(CoreFrame frame, String resolverJs,
      {({double x, double y})? position});

  /// The rectangle of the element [resolverJs] resolves to inside [frame],
  /// in the top document's coordinates, which is what the screenshot
  /// commands of all three engines speak.
  Future<CoreRect> documentRectForTarget(CoreFrame frame, String resolverJs);

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

  // --------------------------------------------------- init scripts

  /// Adds [source] to the scripts every new document of this page runs before
  /// any of its own. See [CorePageInitScripts.addInitScript].
  Future<CoreInitScript> addInitScript(String source);

  /// Exposes [name] as a function on this page. See
  /// [CorePageInitScripts.exposeBinding].
  Future<void> exposeBinding(String name, CoreBindingCallback callback,
      {bool noGlobal});

  /// Functions exposed on this page only.
  Map<String, CoreBinding> get pageBindings;

  /// Every init script this page installs, context's included.
  List<CoreInitScript> get allInitScripts;

  /// Engine hook, see [CorePageInitScripts.applyInitScripts].
  Future<void> applyInitScripts(List<CoreInitScript> scripts);

  /// Engine hook, see [CorePageInitScripts.installBindingChannel].
  Future<void> installBindingChannel(String name);

  /// Declares [binding] in the documents that are already open.
  Future<void> installBindingInLiveFrames(CoreBinding binding);

  /// JavaScript and CSS coverage.
  ///
  /// **Chromium only.** Firefox and WebKit throw [UnsupportedError]: their
  /// protocols have no equivalent, and upstream Playwright exposes
  /// `page.coverage` on the Chromium page alone. See [CoreCoverage].
  CoreCoverage get coverage;

  Future<void> close();
}

/// Whether [expression] is a function the caller means to be *called*, rather
/// than a value to evaluate. Shared by `evaluate` and by the init scripts, so
/// both agree on what counts as a function.
bool isFunctionExpression(String expression) {
  final trimmed = expression.trim();
  return trimmed.startsWith('function') ||
      trimmed.startsWith('async function') ||
      RegExp(r'^(?:async\s+)?(?:\([^)]*\)|[A-Za-z_$][\w$]*)\s*=>')
          .hasMatch(trimmed);
}

/// Wraps a bare arrow/function expression in a call, so that both
/// `() => 2 + 2` and `2 + 2` evaluate to `4`.
String wrapEvaluationExpression(String expression) {
  return isFunctionExpression(expression) ? '($expression)()' : expression;
}

/// Ownership links every page carries: the context that owns it and the page
/// that opened it.
mixin CorePageOwnership {
  CoreBrowserContext? browserContext;
  CorePage? opener;

  /// See [CorePage.guid].
  final String guid = 'page@${createGuid()}';
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
    final watchedByContext =
        context != null && context.listenerCount('dialog') > 0;

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

/// Screenshot geometry shared by the engine pages.
///
/// The engines differ in what they accept, but all three take a rectangle in
/// document coordinates, so the rectangle is computed once here and each
/// driver only has to translate the options.
mixin CorePageScreenshot {
  Future<dynamic> evaluate(String expression);

  Future<List<int>> screenshotRect(CoreRect rect, CoreScreenshotOptions options,
      {bool fitsViewport = true});

  /// The document rectangle a screenshot with [options] should capture, plus
  /// whether it fits in the viewport (which is what tells Chromium to capture
  /// beyond it).
  Future<({CoreRect rect, bool fitsViewport})> screenshotRectFor(
      CoreScreenshotOptions options) async {
    final metrics = await evaluate('''
      () => ({
        scrollX: window.scrollX,
        scrollY: window.scrollY,
        viewportWidth: window.innerWidth,
        viewportHeight: window.innerHeight,
        documentWidth: Math.max(
            document.body ? document.body.scrollWidth : 0,
            document.documentElement.scrollWidth,
            document.body ? document.body.offsetWidth : 0,
            document.documentElement.offsetWidth,
            document.body ? document.body.clientWidth : 0,
            document.documentElement.clientWidth),
        documentHeight: Math.max(
            document.body ? document.body.scrollHeight : 0,
            document.documentElement.scrollHeight,
            document.body ? document.body.offsetHeight : 0,
            document.documentElement.offsetHeight,
            document.body ? document.body.clientHeight : 0,
            document.documentElement.clientHeight),
      })
    ''') as Map;

    double number(String key) => (metrics[key] as num).toDouble();
    final viewportWidth = number('viewportWidth');
    final viewportHeight = number('viewportHeight');

    if (options.fullPage) {
      final full = CoreRect(
          x: 0,
          y: 0,
          width: number('documentWidth'),
          height: number('documentHeight'));
      final rect =
          options.clip == null ? full : _intersect(options.clip!, full);
      return (
        rect: rect.enclosingIntRect,
        fitsViewport:
            full.width <= viewportWidth && full.height <= viewportHeight,
      );
    }

    // Without fullPage the capture is the viewport, expressed in document
    // coordinates by adding the current scroll offset.
    final viewport = CoreRect(
        x: number('scrollX'),
        y: number('scrollY'),
        width: viewportWidth,
        height: viewportHeight);
    final clip = options.clip;
    final rect = clip == null
        ? viewport
        : _intersect(
            CoreRect(
                x: clip.x + viewport.x,
                y: clip.y + viewport.y,
                width: clip.width,
                height: clip.height),
            viewport);
    return (rect: rect.enclosingIntRect, fitsViewport: true);
  }

  static CoreRect _intersect(CoreRect rect, CoreRect bounds) {
    final left = rect.x < bounds.x ? bounds.x : rect.x;
    final top = rect.y < bounds.y ? bounds.y : rect.y;
    final rightLimit = bounds.x + bounds.width;
    final bottomLimit = bounds.y + bounds.height;
    var right = rect.x + rect.width;
    var bottom = rect.y + rect.height;
    if (right > rightLimit) right = rightLimit;
    if (bottom > bottomLimit) bottom = bottomLimit;
    if (right <= left || bottom <= top) {
      throw ArgumentError(
          'Clipped area is either empty or outside the resulting image');
    }
    return CoreRect(x: left, y: top, width: right - left, height: bottom - top);
  }

  /// Captures the page with [options], writing to [path] when given.
  Future<List<int>> screenshotWith(
      CoreScreenshotOptions options, String? path) async {
    options.validate();
    final target = await screenshotRectFor(options);
    final bytes = await screenshotRect(target.rect, options,
        fitsViewport: target.fitsViewport);
    if (path != null) await File(path).writeAsBytes(bytes);
    return bytes;
  }
}

/// Options for `page.pdf`, which only Chromium can answer.
///
/// Sizes are in inches, matching what `Page.printToPDF` takes; `format` picks
/// one of the named paper sizes instead.
class CorePdfOptions {
  final bool landscape;
  final bool displayHeaderFooter;
  final String headerTemplate;
  final String footerTemplate;
  final bool printBackground;
  final double scale;
  final String? format;
  final double? width;
  final double? height;
  final double marginTop;
  final double marginBottom;
  final double marginLeft;
  final double marginRight;
  final String pageRanges;
  final bool preferCSSPageSize;
  final bool tagged;
  final bool outline;

  const CorePdfOptions({
    this.landscape = false,
    this.displayHeaderFooter = false,
    this.headerTemplate = '',
    this.footerTemplate = '',
    this.printBackground = false,
    this.scale = 1,
    this.format,
    this.width,
    this.height,
    this.marginTop = 0,
    this.marginBottom = 0,
    this.marginLeft = 0,
    this.marginRight = 0,
    this.pageRanges = '',
    this.preferCSSPageSize = false,
    this.tagged = false,
    this.outline = false,
  });

  /// The named paper sizes upstream ships, in inches.
  static const paperFormats = <String, ({double width, double height})>{
    'letter': (width: 8.5, height: 11),
    'legal': (width: 8.5, height: 14),
    'tabloid': (width: 11, height: 17),
    'ledger': (width: 17, height: 11),
    'a0': (width: 33.1, height: 46.8),
    'a1': (width: 23.4, height: 33.1),
    'a2': (width: 16.54, height: 23.4),
    'a3': (width: 11.7, height: 16.54),
    'a4': (width: 8.27, height: 11.7),
    'a5': (width: 5.83, height: 8.27),
    'a6': (width: 4.13, height: 5.83),
  };

  /// The paper size in inches: the named format, the explicit size, or the
  /// letter default.
  ({double width, double height}) get paperSize {
    if (format != null) {
      final known = paperFormats[format!.toLowerCase()];
      if (known == null) {
        throw ArgumentError.value(
            format,
            'format',
            'Unknown paper format. Expected one of: '
                '${paperFormats.keys.join(', ')}');
      }
      return known;
    }
    return (width: width ?? 8.5, height: height ?? 11);
  }
}

/// Makes file paths absolute and native before they reach an engine.
///
/// Firefox builds an nsIFile from each path and rejects a Windows path that
/// contains forward slashes, which is exactly what joining with `/` produces.
/// Chromium and WebKit tolerate it, so normalizing here is what makes the
/// three agree.
List<String> normalizeInputFilePaths(List<String> paths) => [
      for (final path in paths) p.normalize(File(path).absolute.path),
    ];

/// File chooser emission shared by the engine pages.
///
/// Only Chromium reports whether the input takes several files; asking the
/// element itself gives the same answer on every engine, and also catches
/// `webkitdirectory`, which upstream treats as multiple too.
mixin CorePageFileChooser on EventEmitter {
  void emitFileChooser(CoreJSHandle element) {
    element
        .evaluate('(el) => !!(el.multiple || el.webkitdirectory)')
        .then((multiple) {
      emit('filechooser',
          CoreFileChooser(element: element, isMultiple: multiple == true));
    }).catchError((Object _) {
      emit('filechooser', CoreFileChooser(element: element, isMultiple: false));
    });
  }
}

/// The route handler chain shared by the engine pages.
///
/// Handlers are kept in registration order and run newest first, which is
/// what upstream does; a handler that calls `fallback()` passes the route to
/// the next one, and when the last one declines the request continues
/// untouched.
mixin CorePageRoutes {
  final routeEntries = <({String pattern, void Function(CoreRoute) handler})>[];

  /// Whether any handler is installed, which is what decides if interception
  /// has to be enabled on the engine.
  bool get hasRoutes => routeEntries.isNotEmpty;

  void addRouteEntry(String pattern, void Function(CoreRoute) handler) {
    routeEntries.add((pattern: pattern, handler: handler));
  }

  void removeRouteEntry(String pattern) {
    routeEntries.removeWhere((entry) => entry.pattern == pattern);
  }

  /// Whether [pattern] matches [url].
  ///
  /// A deliberately small glob: `**/*` matches everything and anything else
  /// is a substring test after dropping `**/`. The full URL-pattern syntax is
  /// not ported yet.
  static bool matchesPattern(String pattern, String url) {
    if (pattern == '**/*') return true;
    return url.contains(pattern.replaceAll('**/', ''));
  }

  /// Whether any handler would claim [url]; the engines use it to decide
  /// between running the chain and continuing the request straight away.
  bool hasHandlerFor(String url) =>
      routeEntries.any((entry) => matchesPattern(entry.pattern, url));

  /// Runs the matching handlers for [route], newest first.
  void dispatchRoute(CoreRoute route) {
    final handlers = routeEntries
        .where((entry) => matchesPattern(entry.pattern, route.request.url))
        .map((entry) => entry.handler)
        .toList()
        .reversed
        .toList();

    var index = 0;
    void runNext() {
      if (index >= handlers.length) {
        route.onFallback = null;
        // Nobody claimed it. Fire-and-forget: the page may be closing and the
        // session already gone, which must not surface as an unhandled error.
        route.continue_().catchError((Object _) {});
        return;
      }
      final handler = handlers[index++];
      route.onFallback = runNext;
      handler(route);
    }

    runNext();
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
    message:
        index + 2 <= message.length ? message.substring(index + 2) : message,
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
  final firstStackLine = lines.indexWhere((line) => line.startsWith('    at'));
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

/// The accessibility tree and the aria snapshot, shared by the engine pages.
///
/// There is nothing engine-specific left here on purpose. Upstream Playwright
/// used to have three implementations of this — `crAccessibility.ts` over CDP's
/// `Accessibility.getFullAXTree`, `ffAccessibility.ts` over Juggler and
/// `wkAccessibility.ts` over the WebKit inspector protocol — and removed all
/// three: as of 1.62 the only accessibility tree it builds is the one its
/// injected script computes from the DOM, in the page, identically everywhere.
/// This port follows that, which is why Firefox and WebKit answer at all and
/// why the three answers agree.
mixin CorePageAccessibility on CorePageFrameEvaluation {
  Future<String> title();

  /// The accessibility tree of [frame] (the main frame by default).
  ///
  /// With [interestingOnly] — the default, and upstream's `default` snapshot
  /// mode — an element whose computed ARIA role is `generic` contributes no
  /// node of its own and its children are hoisted to the nearest node that has
  /// a role, so `<div><span><button>` is one `button`, not three nodes. Pass
  /// `false` to keep those wrappers: that sets upstream's internal
  /// `includeGenericRole`, the switch its `ai` mode uses, on an otherwise
  /// unchanged tree.
  ///
  /// The snapshot does not descend into iframes; each frame has its own tree.
  Future<AccessibilitySnapshot> accessibilitySnapshot({
    bool interestingOnly = true,
    CoreFrame? frame,
  }) async {
    final options = jsonEncode({'includeGenericRole': !interestingOnly});
    final raw = await evaluateInjected(
        frame ?? mainFrame, '() => window.__pwDart.ariaTree(null, $options)');
    return AccessibilitySnapshot(
      title: await title(),
      root: AccessibilityNode.fromInjectedJson(raw, AccessibilityRefCounter()),
    );
  }

  /// The same tree rendered as upstream's aria snapshot YAML.
  ///
  /// This is the text `toMatchAriaSnapshot` compares against upstream. Pass
  /// [selectorJs] to snapshot one element instead of the whole frame: it is a
  /// JS expression evaluated in the frame that must return an element.
  Future<String> ariaSnapshot({CoreFrame? frame, String? selectorJs}) async {
    final root = selectorJs ?? 'null';
    final result = await evaluateInjected(
        frame ?? mainFrame, '() => window.__pwDart.ariaSnapshot($root, {})');
    return result as String? ?? '';
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

  /// The page touchscreen; classes using this mixin must provide it.
  Touchscreen get touchscreen;

  /// Taps the element [resolverJs] resolves to inside [frame].
  Future<void> tapTarget(CoreFrame frame, String resolverJs,
      {({double x, double y})? position}) async {
    final point =
        await clickPointForTarget(frame, resolverJs, position: position);
    await touchscreen.tap(point.x, point.y);
  }

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

  /// The rectangle of the element [resolverJs] resolves to inside [frame],
  /// in the *top document's* coordinates.
  ///
  /// Same walk as [clickPointForTarget]: the element's own box is shifted by
  /// each owning iframe's border box up the chain, and then by the top
  /// document's scroll offset, because that is the coordinate system every
  /// engine's screenshot command speaks.
  Future<CoreRect> documentRectForTarget(
      CoreFrame frame, String resolverJs) async {
    final result = await evaluateInjected(frame, '''
      () => {
        const el = $resolverJs;
        if (!el) throw new Error('Element not found');
        el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
        const rect = el.getBoundingClientRect();
        let x = rect.x, y = rect.y;
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
        const top = win || window;
        return {
          x: x + top.scrollX,
          y: y + top.scrollY,
          width: rect.width,
          height: rect.height,
        };
      }
    ''');
    final map = result as Map;
    final rect = CoreRect(
      x: (map['x'] as num).toDouble(),
      y: (map['y'] as num).toDouble(),
      width: (map['width'] as num).toDouble(),
      height: (map['height'] as num).toDouble(),
    );
    if (rect.width <= 0 || rect.height <= 0) {
      throw PlaywrightException(
          'Element is not visible: it has zero width or height');
    }
    return rect.enclosingIntRect;
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
