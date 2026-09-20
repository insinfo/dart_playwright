import 'dart:async';
import 'dart:convert';
import 'package:playwright_protocol/playwright_protocol.dart';
import 'ff_connection.dart';
import 'ff_execution_context.dart';
import 'ff_input.dart';
import 'ff_network_manager.dart';
import 'ff_route.dart';

import '../context_registry.dart';
import '../core_page.dart';
import '../core_route.dart';
import '../core_js_handle.dart';

/// Represents a Firefox Juggler Page (tab).
class FfPage extends EventEmitter
    with
        CorePageOwnership,
        CorePageWebSockets,
        CorePageWorkers,
        CorePageRoutes,
        CorePageFileChooser,
        CorePageScreenshot,
        CorePageFrameEvaluation,
        CorePageInitScripts,
        CorePageAccessibility,
        CorePageInputHelpers,
        CorePageDialogs,
        CorePageContentHelpers
    implements CorePage {
  final FfSession session;
  @override
  late final Keyboard keyboard;
  @override
  late final Mouse mouse;
  @override
  late final Touchscreen touchscreen;
  late final CoreFrameManager frameManager;
  late final FfNetworkManager networkManager;
  final ContextRegistry _contexts = ContextRegistry();

  bool _isClosed = false;

  FfPage(this.session) {
    frameManager = CoreFrameManager(this);
    keyboard = Keyboard(FfRawKeyboard(session));
    mouse = Mouse(FfRawMouse(session));
    touchscreen = Touchscreen(FfRawTouchscreen(session));
    networkManager = FfNetworkManager(session);
    forwardNetworkEvents(networkManager, this);
    _wireWebSocketEvents();
    _wireWorkerEvents();
    session.on('Page.dialogOpened', _onDialogOpened);
    session.on('Page.fileChooserOpened', _onFileChooserOpened);
    session.on('Runtime.console', _onConsole);
    session.on('Page.uncaughtError', _onUncaughtError);
    session.on('Page.bindingCalled', _onBindingCalled);
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
      // See the same call in cr_page: only the top document may clear it.
      if (params['parentFrameId'] == null) clearWebSockets();
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

  // ------------------------------------------------------------ websockets

  /// The handshake pieces, keyed by the *network* request id, until
  /// `Page.webSocketOpened` names the socket they belong to. Juggler is the
  /// only protocol that splits the handshake across two domains.
  final _webSocketRequests =
      <String, ({String url, List<({String name, String value})> headers})>{};
  final _webSocketResponses = <String,
      ({
    int status,
    String statusText,
    List<({String name, String value})> headers
  })>{};

  /// Juggler identifies a socket by frame plus per-frame id, never by the
  /// network request id. Port of `ffPage.ts#webSocketId`.
  static String _webSocketId(String frameId, String wsid) => '$frameId---$wsid';

  /// Juggler timestamps frames in seconds since the epoch; upstream scales
  /// them to milliseconds (`ffPage.ts:184`). A frame without one gets `-1`.
  static double _wsWallTime(dynamic timestamp) {
    final value = (timestamp as num?)?.toDouble();
    return value == null ? -1 : value * 1000;
  }

  void _wireWebSocketEvents() {
    networkManager.on('webSocketRequestWillBeSent', (dynamic event) {
      final e = event as ({
        String requestId,
        String url,
        List<({String name, String value})> headers
      });
      _webSocketRequests[e.requestId] = (url: e.url, headers: e.headers);
    });
    networkManager.on('webSocketResponseReceived', (dynamic event) {
      final e = event as ({
        String requestId,
        int status,
        String statusText,
        List<({String name, String value})> headers
      });
      _webSocketResponses[e.requestId] =
          (status: e.status, statusText: e.statusText, headers: e.headers);
    });
    networkManager.on('webSocketRequestFinished', (dynamic event) {
      _onWebSocketRequestFinished((event as ({String requestId})).requestId);
    });

    session.on('Page.webSocketCreated', (Map<String, dynamic> params) {
      onWebSocketCreated(
          _webSocketId(params['frameId'] as String? ?? '',
              params['wsid'] as String? ?? ''),
          params['requestURL'] as String? ?? '');
    });
    session.on('Page.webSocketOpened', (Map<String, dynamic> params) {
      final requestId = params['requestId'] as String? ?? '';
      final request = _webSocketRequests.remove(requestId);
      final response = _webSocketResponses.remove(requestId);
      if (request == null || response == null) return;
      final id = _webSocketId(
          params['frameId'] as String? ?? '', params['wsid'] as String? ?? '');
      // Juggler reports no wall time for the handshake, so the socket keeps
      // a null one rather than a made-up zero.
      onWebSocketRequest(id, headers: request.headers);
      onWebSocketResponse(id,
          status: response.status,
          statusText: response.statusText,
          headers: response.headers);
    });
    session.on('Page.webSocketClosed', (Map<String, dynamic> params) {
      final id = _webSocketId(
          params['frameId'] as String? ?? '', params['wsid'] as String? ?? '');
      final error = params['error'] as String?;
      if (error != null && error.isNotEmpty) webSocketError(id, error);
      webSocketClosed(id);
    });
    session.on('Page.webSocketFrameReceived', (Map<String, dynamic> params) {
      webSocketFrameReceived(
          _webSocketId(params['frameId'] as String? ?? '',
              params['wsid'] as String? ?? ''),
          (params['opcode'] as num?)?.toInt() ?? 0,
          params['data'] as String? ?? '',
          _wsWallTime(params['timestamp']));
    });
    session.on('Page.webSocketFrameSent', (Map<String, dynamic> params) {
      onWebSocketFrameSent(
          _webSocketId(params['frameId'] as String? ?? '',
              params['wsid'] as String? ?? ''),
          (params['opcode'] as num?)?.toInt() ?? 0,
          params['data'] as String? ?? '',
          _wsWallTime(params['timestamp']));
    });
  }

  /// A handshake that was refused never produces `Page.webSocketOpened`, so
  /// Juggler would leave the socket invisible. Upstream synthesises the whole
  /// life of the socket from the network events instead
  /// (`ffPage.ts#_onWebSocketRequestFinished`), keyed by the request id, and
  /// rewrites the scheme, because the network layer reports `http(s)`.
  void _onWebSocketRequestFinished(String requestId) {
    final response = _webSocketResponses[requestId];
    if (response == null || response.status < 400) return;
    final request = _webSocketRequests.remove(requestId);
    _webSocketResponses.remove(requestId);
    if (request == null) return;

    final parsed = Uri.tryParse(request.url);
    if (parsed == null) return;
    final url = parsed
        .replace(scheme: parsed.scheme == 'https' ? 'wss' : 'ws')
        .toString();

    onWebSocketCreated(requestId, url);
    onWebSocketRequest(requestId, headers: request.headers);
    onWebSocketResponse(requestId,
        status: response.status,
        statusText: response.statusText,
        headers: response.headers);
    webSocketClosed(requestId);
  }

  // --------------------------------------------------------------- workers

  final _workerSessions =
      <String, ({FfWorkerSession session, String frameId})>{};

  void _wireWorkerEvents() {
    session.on('Page.workerCreated', (Map<String, dynamic> params) {
      final workerId = params['workerId'] as String?;
      if (workerId == null) return;
      final frameId = params['frameId'] as String? ?? '';
      final worker = CoreWorker(params['url'] as String? ?? '');
      final workerSession = FfWorkerSession(session, frameId, workerId);
      _workerSessions[workerId] = (session: workerSession, frameId: frameId);
      workerSession.once('Runtime.executionContextCreated',
          (Map<String, dynamic> event) {
        worker.createExecutionContext(FfExecutionContext(
            workerSession, event['executionContextId'] as String?));
        worker.workerScriptLoaded();
      });
      addWorker(workerId, worker);
    });
    session.on('Page.workerDestroyed', (Map<String, dynamic> params) {
      final workerId = params['workerId'] as String?;
      if (workerId == null) return;
      _workerSessions.remove(workerId)?.session.dispose();
      removeWorker(workerId);
    });
    session.on('Page.dispatchMessageFromWorker', (Map<String, dynamic> params) {
      final entry = _workerSessions[params['workerId'] as String? ?? ''];
      if (entry == null) return;
      final message = params['message'] as String?;
      if (message == null) return;
      entry.session
          .dispatchMessage(jsonDecode(message) as Map<String, dynamic>);
    });
    // Juggler keeps the worker alive past a navigation of its frame, but the
    // page is gone by then; upstream tears them down with the frame
    // (`ffPage.ts:245`).
    session.on('Page.frameDetached', (Map<String, dynamic> params) {
      final frameId = params['frameId'] as String?;
      if (frameId == null) return;
      for (final workerId in _workerSessions.keys.toList()) {
        if (_workerSessions[workerId]?.frameId != frameId) continue;
        _workerSessions.remove(workerId)?.session.dispose();
        removeWorker(workerId);
      }
    });
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
    }).join('\n');
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
  CoreCoverage get coverage {
    throw UnsupportedError(
        'page.coverage is Chromium-only: the counts come from V8 and from '
        "Blink's CSS engine, and the Juggler protocol has no "
        'equivalent. Upstream Playwright has the same limit.');
  }

  // --------------------------------------------------- init scripts

  /// Binding channels already opened on this page.
  final _bindingChannels = <String>{};

  @override
  Future<void> applyInitScripts(List<CoreInitScript> scripts) async {
    // Juggler replaces the whole list in one command, which is why there is
    // nothing to remove first.
    await session.send('Page.setInitScripts', {
      'scripts': [
        for (final script in scripts) {'script': script.source},
      ],
    });
  }

  @override
  Future<void> installBindingChannel(String name) async {
    if (!_bindingChannels.add(name)) return;
    try {
      await session.send('Page.addBinding', {'name': name, 'script': ''});
    } catch (error) {
      _bindingChannels.remove(name);
      rethrow;
    }
  }

  @override
  Object? contextIdOf(CoreFrame frame) =>
      _contexts.contextFor(frame.id)?.contextId;

  void _onBindingCalled(Map<String, dynamic> params) {
    if (params['name'] != kBindingChannelName) return;
    final payload = params['payload'];
    final contextId = params['executionContextId'] as String?;
    if (payload is! String || contextId == null) return;
    dispatchBindingCall(payload, FfExecutionContext(session, contextId));
  }

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
  @override
  Future<List<int>> screenshot(
          {String? path,
          CoreScreenshotOptions options = const CoreScreenshotOptions()}) =>
      screenshotWith(options, path);

  @override
  Future<List<int>> screenshotRect(CoreRect rect, CoreScreenshotOptions options,
      {bool fitsViewport = true}) async {
    // Juggler takes a document rectangle and a mime type, and expresses
    // scale: 'css' as a flag rather than a factor.
    final result = await session.send('Page.screenshot', {
      'mimeType': 'image/${options.type}',
      'clip': {
        'x': rect.x,
        'y': rect.y,
        'width': rect.width,
        'height': rect.height,
      },
      if (options.effectiveQuality != null) 'quality': options.effectiveQuality,
      'omitDeviceScaleFactor': options.scale == 'css',
    });
    return base64Decode(result['data'] as String);
  }

  @override
  Future<List<int>> pdf(
      {String? path, CorePdfOptions options = const CorePdfOptions()}) {
    throw UnsupportedError(
        'page.pdf() is Chromium-only: the Juggler protocol has no '
        'print-to-PDF command, and upstream Playwright has the same limit.');
  }

  bool _routeListenerInstalled = false;

  @override
  Future<void> route(
      String urlPattern, void Function(CoreRoute) handler) async {
    if (!_routeListenerInstalled) {
      _routeListenerInstalled = true;
      session.on('Network.requestWillBeSent', _onRequestWillBeSent);
    }
    if (!hasRoutes) {
      await session.send('Network.setRequestInterception', {'enabled': true});
    }
    addRouteEntry(urlPattern, handler);
  }

  @override
  Future<void> unroute(String urlPattern) async {
    removeRouteEntry(urlPattern);
    if (!hasRoutes) {
      await session.send('Network.setRequestInterception', {'enabled': false});
    }
  }

  void _onRequestWillBeSent(Map<String, dynamic> params) {
    if (params['isIntercepted'] != true) return;
    final requestId = params['requestId'] as String;
    final url = params['url'] as String;

    if (!hasHandlerFor(url)) {
      // Fire-and-forget: the page may be closing and the session already
      // gone; that must not surface as an unhandled async error.
      session.send('Network.resumeInterceptedRequest',
          {'requestId': requestId}).catchError((_) => <String, dynamic>{});
      return;
    }

    dispatchRoute(FfRoute(
      session,
      requestId,
      url,
      method: params['method'] as String? ?? 'GET',
      headers: _stringHeaders(params['headers']),
      postData: _decodePostData(params['postData'] as String?),
      resourceType: FfRequest(params).resourceType,
      isNavigationRequest: params['cause'] == 'TYPE_DOCUMENT',
      frame: params['frameId'],
    ));
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
  Future<void> setInputFilePaths(
      CoreFrame frame, CoreJSHandle handle, List<String> paths) async {
    // Juggler is the one engine that also wants the frame.
    await session.send('Page.setFileInputFiles', {
      'frameId': frame.id,
      'objectId': handle.objectId,
      'files': normalizeInputFilePaths(paths),
    });
  }

  @override
  Future<void> setInterceptFileChooser(bool enabled) async {
    await session
        .send('Page.setInterceptFileChooserDialog', {'enabled': enabled});
  }

  void _onFileChooserOpened(Map<String, dynamic> params) {
    // Juggler identifies the element only by its execution context, so the
    // frame has to be found the other way round.
    final contextId = params['executionContextId'];
    final element = params['element'];
    if (contextId == null || element is! Map) return;
    final frameId = _contexts.frameIdFor(contextId);
    final context = frameId == null ? null : _contexts.contextFor(frameId);
    if (context is! FfExecutionContext) return;
    final handle = context.createHandle(Map<String, dynamic>.from(element));
    emitFileChooser(handle);
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
    // Upstream closes the page's workers before the page itself reports
    // closed, so a `worker.on('close')` listener still fires.
    clearWorkers();
    emit('close', true);
    disposeStreams();
  }
}
