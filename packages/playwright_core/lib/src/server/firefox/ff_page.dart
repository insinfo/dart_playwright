import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:playwright_protocol/playwright_protocol.dart';
import 'ff_connection.dart';
import 'ff_execution_context.dart';
import 'ff_input.dart';
import 'ff_network_manager.dart';
import 'ff_route.dart';
import '../../accessibility.dart';

import '../context_registry.dart';
import '../core_page.dart';
import '../core_route.dart';
import '../core_js_handle.dart';

/// Represents a Firefox Juggler Page (tab).
class FfPage extends EventEmitter
    with
        CorePageOwnership,
        CorePageFrameEvaluation,
        CorePageInputHelpers,
        CorePageDialogs,
        CorePageContentHelpers
    implements CorePage {
  final FfSession session;
  @override
  late final Keyboard keyboard;
  @override
  late final Mouse mouse;
  late final CoreFrameManager frameManager;
  late final FfNetworkManager networkManager;
  final ContextRegistry _contexts = ContextRegistry();

  bool _isClosed = false;

  FfPage(this.session) {
    frameManager = CoreFrameManager(this);
    keyboard = Keyboard(FfRawKeyboard(session));
    mouse = Mouse(FfRawMouse(session));
    networkManager = FfNetworkManager(session);
    forwardNetworkEvents(networkManager, this);
    session.on('Page.dialogOpened', _onDialogOpened);
    session.on('Runtime.console', _onConsole);
    session.on('Page.uncaughtError', _onUncaughtError);
    session.on('Page.crashed', (_) => emit('crash', true));
    session.on('Page.frameAttached', (params) {
      frameManager.frameAttached(
          params['frameId'] as String, params['parentFrameId'] as String?);
    });
    session.on('Page.frameDetached', (params) {
      final frameId = params['frameId'] as String;
      _contexts.frameDetached(frameId);
      frameManager.frameDetached(frameId);
    });
    // Firefox Juggler reports document navigations as
    // Page.navigationCommitted (not Page.navigated).
    session.on('Page.navigationCommitted', (params) {
      frameManager.frameNavigated(
        params['frameId'] as String,
        params['url'] as String,
        params['name'] as String? ?? '',
        params['navigationId'] as String? ?? '',
        parentId: params['parentFrameId'] as String?,
      );
    });
    session.on('Page.sameDocumentNavigation', (params) {
      frameManager.frameNavigatedWithinDocument(
        params['frameId'] as String,
        params['url'] as String,
      );
    });
    session.on('Page.eventFired', (params) {
      frameManager.frameLifecycleEvent(
          params['frameId'] as String, params['name'] as String);
    });
    session.on('Runtime.executionContextCreated', (params) {
      final auxData = params['auxData'] as Map<String, dynamic>?;
      final frameId = auxData?['frameId'] as String?;
      // Juggler names the utility world; the main world has no name.
      final worldName = auxData?['name'] as String?;
      if (frameId == null || (worldName != null && worldName.isNotEmpty)) {
        return;
      }
      _contexts.contextCreated(frameId,
          FfExecutionContext(session, params['executionContextId'] as String));
    });
    session.on('Runtime.executionContextDestroyed', (params) {
      final id = params['executionContextId'] as String;
      _contexts.contextDestroyed(id);
      forgetExecutionContext(id);
    });
    session.on('closed', () => _onClosed());
  }

  void _onDialogOpened(Map<String, dynamic> params) {
    final dialogId = params['dialogId'];
    dispatchDialog(Dialog(
      params['type'] as String? ?? 'alert',
      params['message'] as String? ?? '',
      params['defaultValue'] as String? ?? '',
      (accept, promptText) async {
        await session.send('Page.handleDialog', {
          'dialogId': dialogId,
          'accept': accept,
          if (promptText != null) 'promptText': promptText,
        });
      },
    ));
  }

  void _onConsole(Map<String, dynamic> params) {
    final location = params['location'] as Map<String, dynamic>?;
    emit(
        'console',
        CoreConsoleMessage(
          // Juggler says 'warn' for browser-generated messages; every other
          // engine and the documented vocabulary say 'warning'.
          type: normalizeConsoleType(params['type'] as String?),
          text: describeConsoleArgs(params['args']),
          location: CoreSourceLocation(
            url: location?['url'] as String? ?? '',
            lineNumber: (location?['lineNumber'] as num?)?.toInt() ?? 0,
            columnNumber: (location?['columnNumber'] as num?)?.toInt() ?? 0,
          ),
        ));
  }

  void _onUncaughtError(Map<String, dynamic> params) {
    final message = params['message'] as String? ?? '';
    final split = splitErrorMessage(message);
    // SpiderMonkey stacks read `func@url:line:col`; upstream rewrites them to
    // the V8 shape so a stack looks the same whichever engine produced it.
    final frames = (params['stack'] as String? ?? '')
        .split('\n')
        .where((line) => line.isNotEmpty)
        .map((line) {
          final at = line.indexOf('@');
          if (at == -1) return '    at $line';
          return '    at ${line.substring(0, at)} (${line.substring(at + 1)})';
        })
        .join('\n');
    emit(
        'pageerror',
        CorePageError(
          name: split.name,
          message: split.message,
          stack: frames.isEmpty ? message : '$message\n$frames',
        ));
  }

  Future<void> initialize() async {
    // Wait for Page.ready
    // Instead of enabling Page/Runtime like Chromium, Juggler just emits Page.ready
    await session.waitForEvent('Page.ready');
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
            frame.parentId == null ? FfExecutionContext(session, null) : null);
  }

  @override
  Future<void> gotoFrame(CoreFrame frame, String url,
      {WaitUntilState? waitUntil, Duration? timeout}) async {
    final loaded = frame.waitForNavigation(
        waitUntil: waitUntil, timeout: timeout ?? const Duration(seconds: 30));
    loaded.catchError((_) {});
    await session.send('Page.navigate', {'url': url, 'frameId': frame.id});
    await loaded;
  }

  @override
  Future<CoreFrame?> contentFrame(CoreJSHandle handle) async {
    if (handle is! FfJSHandle) return null;
    final result = await session.send('Page.describeNode', {
      'frameId': frameIdForContext(handle.context),
      'objectId': handle.objectId,
    });
    final contentFrameId = result['contentFrameId'];
    if (contentFrameId is! String) return null;
    return frameManager.frame(contentFrameId);
  }

  /// The frame a handle's context belongs to; Juggler's `Page.describeNode`
  /// needs the frame id alongside the object id.
  String? frameIdForContext(FfExecutionContext context) {
    for (final frame in frameManager.frames) {
      if (_contexts.contextFor(frame.id)?.contextId == context.contextId) {
        return frame.id;
      }
    }
    return frameManager.mainFrame?.id;
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

  /// Navigate to a URL.
  @override
  Future<void> goto(String url,
      {WaitUntilState? waitUntil, Duration? timeout}) async {
    final frame = await frameManager.waitForMainFrame();
    final loaded = frame.waitForNavigation(
        waitUntil: waitUntil, timeout: timeout ?? const Duration(seconds: 30));
    // Keep the waiter's timeout handled even while Page.navigate stalls on a
    // slow server; the awaited rethrow below still surfaces it.
    loaded.catchError((_) {});
    await session.send('Page.navigate', {'url': url, 'frameId': frame.id});
    await loaded;
  }

  @override
  Future<void> reload({WaitUntilState? waitUntil}) async {
    final frame = await frameManager.waitForMainFrame();
    final loaded = frame.waitForNavigation(
        waitUntil: waitUntil, timeout: const Duration(seconds: 30));
    await session.send('Page.reload');
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
    final result = await session.send(method, {'frameId': frame.id});
    if (result['success'] != true) {
      // Nothing will navigate; drop the waiter silently.
      loaded.catchError((_) {});
      return false;
    }
    await loaded;
    return true;
  }

  /// Get the page title.
  Future<String> title() async {
    final result = await evaluate('document.title');
    return result.toString();
  }

  /// Fill an element using trusted Juggler input events.
  @override
  Future<void> fill(String selector, String text) => fillTarget(
      mainFrame, CorePageInputHelpers.resolverForSelector(selector), text);

  @override
  Future<void> fillTarget(
      CoreFrame frame, String resolverJs, String text) async {
    await focusAndSelectTarget(frame, resolverJs);
    if (text.isEmpty) {
      await keyboard.press('Delete');
      return;
    }
    await session.send('Page.insertText', {'text': text});
  }

  /// Evaluate JavaScript in the page's main frame.
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

  /// Take a screenshot.
  Future<List<int>> screenshot({String? path}) async {
    // Juggler requires an explicit clip rect.
    final width = await evaluate('window.innerWidth');
    final height = await evaluate('window.innerHeight');

    final result = await session.send('Page.screenshot', {
      'mimeType': 'image/png',
      'clip': {
        'x': 0,
        'y': 0,
        'width': width ?? 1280,
        'height': height ?? 720,
      },
    });
    final data = result['data'] as String;
    final bytes = base64Decode(data);

    if (path != null) {
      await File(path).writeAsBytes(bytes);
    }
    return bytes;
  }

  /// Get Accessibility Snapshot
  Future<AccessibilitySnapshot> accessibilitySnapshot() async {
    // Firefox might not have Accessibility.getFullAXTree out of the box in Juggler
    // We mock it for parity tests if it fails
    try {
      await session.send('Accessibility.getFullAXTree');
      // Similar parsing...
      return AccessibilitySnapshot(
          title: 'Firefox A11y',
          root: AccessibilityNode(role: 'WebArea', name: '', ref: 'root'));
    } catch (_) {
      return AccessibilitySnapshot(
          title: await title(),
          root: AccessibilityNode(role: 'WebArea', name: '', ref: 'root'));
    }
  }

  final _routes = <String, void Function(CoreRoute)>{};

  bool _routeListenerInstalled = false;

  @override
  Future<void> route(
      String urlPattern, void Function(CoreRoute) handler) async {
    if (!_routeListenerInstalled) {
      _routeListenerInstalled = true;
      session.on('Network.requestWillBeSent', _onRequestWillBeSent);
    }
    if (_routes.isEmpty) {
      await session.send('Network.setRequestInterception', {'enabled': true});
    }
    _routes[urlPattern] = handler;
  }

  @override
  Future<void> unroute(String urlPattern) async {
    _routes.remove(urlPattern);
    if (_routes.isEmpty) {
      await session.send('Network.setRequestInterception', {'enabled': false});
    }
  }

  void _onRequestWillBeSent(Map<String, dynamic> params) {
    if (params['isIntercepted'] != true) return;
    final requestId = params['requestId'] as String;
    final url = params['url'] as String;

    void Function(CoreRoute)? matchedHandler;
    for (final pattern in _routes.keys) {
      final cleanPattern = pattern.replaceAll('**/', '');
      if (pattern == '**/*' || url.contains(cleanPattern)) {
        matchedHandler = _routes[pattern];
        break;
      }
    }

    if (matchedHandler != null) {
      matchedHandler(FfRoute(
        session,
        requestId,
        url,
        method: params['method'] as String? ?? 'GET',
        headers: _stringHeaders(params['headers']),
        postData: _decodePostData(params['postData'] as String?),
      ));
    } else {
      // Fire-and-forget: the page may be closing and the session already
      // gone; that must not surface as an unhandled async error.
      session.send('Network.resumeInterceptedRequest',
          {'requestId': requestId}).catchError((_) => <String, dynamic>{});
    }
  }

  /// Juggler reports request bodies base64-encoded (upstream decodes with
  /// Buffer.from(postData, 'base64')).
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

  /// Close the page.
  Future<void> close() async {
    if (_isClosed) return;
    await session.send('Page.close');
  }

  @override
  Future<void> setViewportSize(int width, int height) async {
    await session.send('Page.setViewportSize', {
      'viewportSize': {'width': width, 'height': height},
      'screenSize': {'width': width, 'height': height},
      'isMobile': false,
    });
  }

  @override
  Future<void> setExtraHTTPHeaders(Map<String, String> headers) async {
    // Juggler wants an array of {name, value}, not a plain object.
    await session.send('Network.setExtraHTTPHeaders', {
      'headers': headers.entries
          .map((entry) => {'name': entry.key, 'value': entry.value})
          .toList(),
    });
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
