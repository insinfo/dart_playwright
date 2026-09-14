import 'dart:convert';
import 'dart:async';
import 'package:playwright_protocol/playwright_protocol.dart';
import '../context_registry.dart';
import '../core_page.dart';
import '../core_js_handle.dart';
import '../core_route.dart';
import 'wk_connection.dart';
import 'wk_execution_context.dart';
import 'wk_input.dart';
import 'wk_network_manager.dart';
import 'wk_route.dart';
import '../../accessibility.dart';

/// A WebKit page, backed by a pageProxy session.
///
/// Page-level commands are wrapped in `Target.sendMessageToTarget` by
/// [WkPageProxySession.sendToTarget]; page-level events arrive unwrapped
/// on the same session (via `Target.dispatchMessageFromTarget`).
class WkPage extends EventEmitter
    with
        CorePageOwnership,
        CorePageRoutes,
        CorePageFileChooser,
        CorePageScreenshot,
        CorePageFrameEvaluation,
        CorePageInputHelpers,
        CorePageDialogs,
        CorePageContentHelpers
    implements CorePage {
  final WkPageProxySession session;
  final String? browserContextId;
  @override
  late final Keyboard keyboard;
  @override
  late final Mouse mouse;
  @override
  late final Touchscreen touchscreen;
  late final CoreFrameManager frameManager;
  late final WkNetworkManager networkManager;
  final ContextRegistry _contexts = ContextRegistry();

  bool _isClosed = false;

  WkPage(this.session, {this.browserContextId}) {
    frameManager = CoreFrameManager(this);
    keyboard = Keyboard(WkRawKeyboard(session));
    mouse = Mouse(WkRawMouse(session));
    touchscreen = Touchscreen(WkRawTouchscreen(session));
    networkManager = WkNetworkManager(session);
    forwardNetworkEvents(networkManager, this);
    // WebKit reports dialogs via the Dialog domain on the pageProxy session.
    session.on('Dialog.javascriptDialogOpening', _onDialogOpening);
    session.on('Page.fileChooserOpened', _onFileChooserOpened);
    session.on('Console.messageAdded', _onConsoleMessageAdded);
    // WebKit has no crash event: the target simply goes away with a flag.
    session.on('Target.targetDestroyed', (params) {
      if (params['crashed'] == true) emit('crash', true);
    });
    session.on('Page.frameNavigated', (params) {
      final frame = params['frame'] as Map<String, dynamic>;
      frameManager.frameNavigated(
        frame['id'] as String,
        frame['url'] as String,
        frame['name'] as String? ?? '',
        frame['loaderId'] as String? ?? frame['navigationId'] as String? ?? '',
        parentId: frame['parentId'] as String?,
      );
    });
    session.on('Page.frameDetached', (params) {
      final frameId = params['frameId'] as String;
      _contexts.frameDetached(frameId);
      frameManager.frameDetached(frameId);
    });
    session.on('Runtime.executionContextCreated', (params) {
      final context = params['context'] as Map<String, dynamic>;
      final frameId = context['frameId'] as String?;
      // Only the page's own world; utility worlds have type 'user'.
      if (frameId == null ||
          (context['type'] != null && context['type'] != 'normal')) {
        return;
      }
      _contexts.contextCreated(
          frameId, WkExecutionContext(session, context['id'] as int));
    });
    // WebKit reports which frame fired the event; attributing everything to
    // the main frame left child frames without lifecycle events, so
    // frame.goto()/waitForLoadState() on an iframe never completed.
    session.on('Page.loadEventFired', (params) {
      final frameId =
          params['frameId'] as String? ?? frameManager.mainFrame?.id;
      if (frameId != null) frameManager.frameLifecycleEvent(frameId, 'load');
    });
    session.on('Page.domContentEventFired', (params) {
      final frameId =
          params['frameId'] as String? ?? frameManager.mainFrame?.id;
      if (frameId != null) {
        frameManager.frameLifecycleEvent(frameId, 'DOMContentLoaded');
      }
    });
    session.on('closed', () => _onClosed());
  }

  void _onDialogOpening(Map<String, dynamic> params) {
    dispatchDialog(Dialog(
      params['type'] as String? ?? 'alert',
      params['message'] as String? ?? '',
      params['defaultPrompt'] as String? ?? '',
      (accept, promptText) async {
        await session.send('Dialog.handleJavaScriptDialog', {
          'accept': accept,
          if (promptText != null) 'promptText': promptText,
        });
      },
    ));
  }

  void _onConsoleMessageAdded(Map<String, dynamic> params) {
    final message = params['message'] as Map<String, dynamic>?;
    if (message == null) return;
    final text = message['text'] as String? ?? '';
    // WebKit reports line/column 1-based; upstream normalizes to 0-based so
    // locations agree across engines.
    final location = CoreSourceLocation(
      url: message['url'] as String? ?? '',
      lineNumber: ((message['line'] as num?)?.toInt() ?? 1) - 1,
      columnNumber: ((message['column'] as num?)?.toInt() ?? 1) - 1,
    );

    // An uncaught exception reaches WebKit as a console message; it is a page
    // error, not console output, so it leaves through the other door.
    if (message['level'] == 'error' && message['source'] == 'javascript') {
      final split = splitErrorMessage(text);
      final stackTrace = message['stackTrace'] as Map<String, dynamic>?;
      final callFrames = stackTrace?['callFrames'] as List?;
      final stack = callFrames == null
          ? ''
          : '$text\n${callFrames.map((frame) {
              final f = frame as Map<String, dynamic>;
              final name = (f['functionName'] as String?)?.isNotEmpty == true
                  ? f['functionName']
                  : 'unknown';
              return '    at $name (${f['url']}:${f['lineNumber']}:${f['columnNumber']})';
            }).join('\n')}';
      emit(
          'pageerror',
          CorePageError(
              name: split.name, message: split.message, stack: stack));
      return;
    }

    // `log` carries the real severity in `level`; `timing` is what upstream
    // surfaces as `timeEnd`.
    final rawType = message['type'] as String? ?? '';
    final type = rawType == 'log'
        ? message['level'] as String? ?? 'log'
        : (rawType == 'timing' ? 'timeEnd' : rawType);
    final parameters = message['parameters'];
    emit(
        'console',
        CoreConsoleMessage(
          type: normalizeConsoleType(type),
          text: parameters is List && parameters.isNotEmpty
              ? describeConsoleArgs(parameters)
              : text,
          location: location,
        ));
  }

  Future<void> initialize() async {
    await session.send('Dialog.enable');
    await session.sendToTarget('Page.enable');
    await session.sendToTarget('Runtime.enable');
    await session.sendToTarget('Console.enable');
    // Network events (requestWillBeSent & friends) only flow after enable.
    await session.sendToTarget('Network.enable');
    // WebKit only reports frame changes that happen after Page.enable. The
    // main frame predates it, so seed the existing tree (mirrors upstream
    // _handleFrameTree) or waitForMainFrame() would never complete.
    final result = await session.sendToTarget('Page.getResourceTree');
    _handleFrameTree(result['frameTree'] as Map<String, dynamic>);
    if (session.targetIsPaused) {
      await session.send('Target.resume', {'targetId': session.targetId});
    }
  }

  void _handleFrameTree(Map<String, dynamic> frameTree) {
    final frame = frameTree['frame'] as Map<String, dynamic>;
    final frameId = frame['id'] as String;
    final parentId = frame['parentId'] as String?;
    frameManager.frameAttached(frameId, parentId);
    frameManager.frameNavigated(
      frameId,
      frame['url'] as String? ?? '',
      frame['name'] as String? ?? '',
      frame['loaderId'] as String? ?? '',
      parentId: parentId,
    );
    frameManager.frameLifecycleEvent(frameId, 'DOMContentLoaded');
    frameManager.frameLifecycleEvent(frameId, 'load');
    for (final child in frameTree['childFrames'] as List? ?? const []) {
      _handleFrameTree(child as Map<String, dynamic>);
    }
  }

  @override
  CoreFrame get mainFrame => frameManager.mainFrame!;

  @override
  List<CoreFrame> get frames => frameManager.frames;

  @override
  Future<CoreExecutionContext> executionContextFor(CoreFrame frame,
      {Duration? timeout}) {
    return _contexts.waitFor(frame.id,
        timeout: timeout ?? const Duration(seconds: 10),
        fallback:
            frame.parentId == null ? WkExecutionContext(session, null) : null);
  }

  @override
  Future<void> gotoFrame(CoreFrame frame, String url,
      {WaitUntilState? waitUntil, Duration? timeout}) async {
    final loaded = frame.waitForNavigation(
        waitUntil: waitUntil, timeout: timeout ?? const Duration(seconds: 30));
    loaded.catchError((_) {});
    await session.connection.send('Playwright.navigate', {
      'url': url,
      'pageProxyId': session.pageProxyId,
      'frameId': frame.id,
    });
    await loaded;
  }

  @override
  Future<CoreFrame?> contentFrame(CoreJSHandle handle) async {
    if (handle is! WkJSHandle) return null;
    final info = await session
        .sendToTarget('DOM.describeNode', {'objectId': handle.objectId});
    final contentFrameId = info['contentFrameId'];
    if (contentFrameId is! String) return null;
    return frameManager.frame(contentFrameId);
  }

  @override
  Future<void> waitForLoadState(
      {WaitUntilState state = WaitUntilState.load, Duration? timeout}) async {
    final frame = await frameManager.waitForMainFrame();
    await frame.waitForLoadState(state, timeout: timeout);
  }

  @override
  Future<void> waitForNavigation(
      {WaitUntilState? waitUntil, Duration? timeout}) async {
    await mainFrame.waitForNavigation(waitUntil: waitUntil, timeout: timeout);
  }

  @override
  Future<void> goto(String url,
      {WaitUntilState? waitUntil, Duration? timeout}) async {
    final frame = await frameManager.waitForMainFrame();
    final loaded = frame.waitForNavigation(
        waitUntil: waitUntil, timeout: timeout ?? const Duration(seconds: 30));
    // Keep the waiter's timeout handled even while the navigate command
    // stalls on a slow server; the awaited rethrow below still surfaces it.
    loaded.catchError((_) {});
    // Navigation is a Playwright-domain command on the browser session,
    // scoped by pageProxyId (WebKit's Page domain has no Page.navigate).
    await session.connection.send('Playwright.navigate', {
      'url': url,
      'pageProxyId': session.pageProxyId,
    });
    await loaded;
  }

  @override
  Future<void> reload({WaitUntilState? waitUntil}) async {
    final frame = await frameManager.waitForMainFrame();
    final loaded = frame.waitForNavigation(
        waitUntil: waitUntil, timeout: const Duration(seconds: 30));
    await session.sendToTarget('Page.reload');
    await loaded;
  }

  @override
  Future<bool> goBack({WaitUntilState? waitUntil}) =>
      _goHistory('Page.goBack', waitUntil);

  @override
  Future<bool> goForward({WaitUntilState? waitUntil}) =>
      _goHistory('Page.goForward', waitUntil);

  Future<bool> _goHistory(String method, WaitUntilState? waitUntil) async {
    final frame = await frameManager.waitForMainFrame();
    final loaded = frame.waitForNavigation(
        waitUntil: waitUntil, timeout: const Duration(seconds: 30));
    try {
      await session.sendToTarget(method);
    } on PlaywrightException catch (error) {
      // WebKit reports an exhausted history as "Failed to go back/forward".
      if (error.message.contains('Failed to go')) {
        loaded.catchError((_) {});
        return false;
      }
      rethrow;
    }
    await loaded;
    return true;
  }

  Future<String> title() async {
    final result = await evaluate('document.title');
    return result.toString();
  }

  /// Fill an element using trusted WebKit input events.
  @override
  Future<void> fill(String selector, String text) => fillTarget(
      mainFrame, CorePageInputHelpers.resolverForSelector(selector), text);

  @override
  Future<void> fillTarget(
      CoreFrame frame, String resolverJs, String text) async {
    await focusAndSelectTarget(frame, resolverJs);
    if (text.isEmpty) {
      // Goes through the keyboard so macCommands (deleteForward:) are
      // attached; a bare key event does not edit on macOS.
      await keyboard.press('Delete');
      return;
    }
    await session.sendToTarget('Page.insertText', {'text': text});
  }

  @override
  Future<dynamic> evaluate(String expression) async {
    final frame = await frameManager.waitForMainFrame();
    return evaluateInFrame(frame, expression);
  }

  @override
  Future<CoreJSHandle> evaluateHandle(String expression) async {
    final frame = await frameManager.waitForMainFrame();
    return evaluateHandleInFrame(frame, expression);
  }

  @override
  Future<List<int>> screenshot(
          {String? path,
          CoreScreenshotOptions options = const CoreScreenshotOptions()}) =>
      screenshotWith(options, path);

  @override
  Future<List<int>> screenshotRect(CoreRect rect, CoreScreenshotOptions options,
      {bool fitsViewport = true}) async {
    // WebKit takes the rectangle as plain fields plus the coordinate system
    // it is expressed in, and answers with a data URL rather than raw base64.
    final result = await session.sendToTarget('Page.snapshotRect', {
      'x': rect.x,
      'y': rect.y,
      'width': rect.width,
      'height': rect.height,
      'coordinateSystem': 'Page',
      'omitDeviceScaleFactor': options.scale == 'css',
      'format': options.type,
      if (options.effectiveQuality != null) 'quality': options.effectiveQuality,
    });
    final dataUrl = result['dataURL'] as String;
    return base64Decode(dataUrl.substring(dataUrl.indexOf(',') + 1));
  }

  @override
  Future<List<int>> pdf(
      {String? path, CorePdfOptions options = const CorePdfOptions()}) {
    throw UnsupportedError(
        'page.pdf() is Chromium-only: the WebKit inspector protocol has no '
        'print-to-PDF command, and upstream Playwright has the same limit.');
  }

  Future<AccessibilitySnapshot> accessibilitySnapshot() async {
    return AccessibilitySnapshot(
        title: await title(),
        root: AccessibilityNode(role: 'WebArea', name: '', ref: 'root'));
  }

  bool _routeListenerInstalled = false;

  @override
  Future<void> route(
      String urlPattern, void Function(CoreRoute) handler) async {
    if (!_routeListenerInstalled) {
      _routeListenerInstalled = true;
      session.on('Network.requestIntercepted', _onRequestIntercepted);
    }
    if (!hasRoutes) {
      await session.sendToTarget('Network.enable');
      await session
          .sendToTarget('Network.setInterceptionEnabled', {'enabled': true});
      await session.sendToTarget('Network.addInterception', {
        'url': '.*',
        'stage': 'request',
        'isRegex': true,
      });
    }
    addRouteEntry(urlPattern, handler);
  }

  @override
  Future<void> unroute(String urlPattern) async {
    removeRouteEntry(urlPattern);
    if (!hasRoutes) {
      await session.sendToTarget('Network.removeInterception', {
        'url': '.*',
        'stage': 'request',
        'isRegex': true,
      });
      await session
          .sendToTarget('Network.setInterceptionEnabled', {'enabled': false});
    }
  }

  void _onRequestIntercepted(Map<String, dynamic> params) {
    final requestId = params['requestId'] as String;
    final request = params['request'] as Map<String, dynamic>? ?? {};
    final url = request['url'] as String? ?? '';

    if (!hasHandlerFor(url)) {
      // Fire-and-forget: the page may be closing and the session already
      // gone; that must not surface as an unhandled async error.
      session.sendToTarget('Network.interceptContinue', {
        'requestId': requestId,
        'stage': 'request',
      }).catchError((_) => <String, dynamic>{});
      return;
    }

    dispatchRoute(WkRoute(
      session,
      requestId,
      url,
      method: request['method'] as String? ?? 'GET',
      headers: _stringHeaders(request['headers']),
      postData: _decodePostData(request['postData'] as String?),
      resourceType: WkRequest(params).resourceType,
      isNavigationRequest: params['type'] == 'Document',
      frame: params['frameId'],
    ));
  }

  /// WebKit reports intercepted request bodies base64-encoded.
  String? _decodePostData(String? base64Body) {
    if (base64Body == null) return null;
    try {
      return utf8.decode(base64Decode(base64Body));
    } catch (_) {
      return base64Body;
    }
  }

  Map<String, String> _stringHeaders(dynamic headers) {
    if (headers is! Map) return const <String, String>{};
    return headers.map((key, value) => MapEntry('$key', '$value'));
  }

  Future<void> close() async {
    if (_isClosed) return;
    await session.connection
        .send('Playwright.closePage', {'pageProxyId': session.pageProxyId});
  }

  @override
  Future<void> setInputFilePaths(
      CoreFrame frame, CoreJSHandle handle, List<String> paths) async {
    // WebKit sandboxes file reads, so the browser process has to be told
    // about the paths before the page may touch them. The two commands go to
    // different layers and can run together.
    final resolved = normalizeInputFilePaths(paths);
    await Future.wait([
      session.connection.send('Playwright.grantFileReadAccess', {
        'pageProxyId': session.pageProxyId,
        'paths': resolved,
      }),
      // Note the field is `paths` here, not `files`.
      session.sendToTarget('DOM.setInputFiles', {
        'objectId': handle.objectId,
        'paths': resolved,
      }),
    ]);
  }

  @override
  Future<void> setInterceptFileChooser(bool enabled) async {
    await session
        .sendToTarget('Page.setInterceptFileChooserDialog', {'enabled': enabled});
  }

  void _onFileChooserOpened(Map<String, dynamic> params) {
    final frameId = params['frameId'] as String?;
    final element = params['element'];
    if (frameId == null || element is! Map) return;
    final context = _contexts.contextFor(frameId);
    if (context is! WkExecutionContext) return;
    emitFileChooser(
        context.createHandle(Map<String, dynamic>.from(element)));
  }

  @override
  Future<void> setViewportSize(int width, int height) async {
    // WebKit splits this across both layers: device metrics are a pageProxy
    // command, the screen size a target one (wkPage.ts:713).
    await session.send('Emulation.setDeviceMetricsOverride', {
      'width': width,
      'height': height,
      'fixedLayout': false,
      'deviceScaleFactor': 1,
    });
    await session.sendToTarget('Page.setScreenSizeOverride', {
      'width': width,
      'height': height,
    });
  }

  @override
  Future<void> setExtraHTTPHeaders(Map<String, String> headers) async {
    await session
        .sendToTarget('Network.setExtraHTTPHeaders', {'headers': headers});
  }

  @override
  bool get isClosed => _isClosed;

  void _onClosed() {
    if (_isClosed) return;
    _isClosed = true;
    emit('close', true);
    disposeStreams();
  }
}
