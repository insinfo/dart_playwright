import 'dart:convert';
import 'dart:io';
import 'package:playwright_protocol/playwright_protocol.dart';
import 'cr_coverage.dart';
import 'cr_execution_context.dart';
import 'cr_js_handle.dart';
import 'cr_input.dart';
import 'cr_network_manager.dart';
import 'cr_route.dart';
import '../context_registry.dart';
import '../core_request.dart';
import '../core_route.dart';
import '../core_page.dart';
import '../core_js_handle.dart';

/// Represents a Chromium Page (tab).
class CrPage extends EventEmitter
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
  final dynamic session;

  /// The CDP target id backing this page, used to match popups to openers.
  final String? targetId;
  final CrNetworkManager networkManager;
  @override
  late final Keyboard keyboard;
  @override
  late final Mouse mouse;
  @override
  late final Touchscreen touchscreen;
  late final CoreFrameManager frameManager;
  final ContextRegistry _contexts = ContextRegistry();

  bool _isClosed = false;

  CrPage._(this.session, this.targetId)
      : networkManager = CrNetworkManager(session) {
    frameManager = CoreFrameManager(this);
    keyboard = Keyboard(CrRawKeyboard(session));
    mouse = Mouse(CrRawMouse(session));
    touchscreen = Touchscreen(CrRawTouchscreen(session));
    forwardNetworkEvents(networkManager, this);

    session.on('Runtime.executionContextCreated', (params) {
      final context = params['context'] as Map<String, dynamic>;
      final auxData = context['auxData'] as Map<String, dynamic>?;
      final frameId = auxData?['frameId'] as String?;
      // Only the main world; isolated worlds have isDefault == false.
      if (frameId == null || auxData?['isDefault'] == false) return;
      _contexts.contextCreated(
          frameId, CrExecutionContext(session, context['id'] as int));
    });
    session.on('Runtime.executionContextDestroyed', (params) {
      final id = params['executionContextId'] as int;
      _contexts.contextDestroyed(id);
      forgetExecutionContext(id);
    });
    session.on('Runtime.executionContextsCleared', (_) => _contexts.clear());
    session.on('closed', () => _onClosed());
    session.on('Page.javascriptDialogOpening', _onDialogOpening);
    session.on('Page.fileChooserOpened', _onFileChooserOpened);
    session.on('Runtime.consoleAPICalled', _onConsoleAPICalled);
    session.on('Log.entryAdded', _onLogEntryAdded);
    session.on('Runtime.exceptionThrown', _onExceptionThrown);
    session.on('Runtime.bindingCalled', _onBindingCalled);
    // The renderer died: the tab is showing "Aw, Snap!". The session survives,
    // so the page object stays usable enough to report the crash.
    session.on('Inspector.targetCrashed', (_) => emit('crash', true));
    _wireWebSocketEvents();
    _wireWorkerEvents();

    // Frame events
    session.on('Page.frameAttached', (params) {
      frameManager.frameAttached(
          params['frameId'] as String, params['parentFrameId'] as String?);
    });
    session.on('Page.frameNavigated', (params) {
      final frame = params['frame'] as Map<String, dynamic>;
      // Upstream drops the socket registry when the top document changes
      // (`frames.ts#_clearWebSockets`); sockets are not attributed to frames,
      // so only a main-frame navigation may clear it.
      if (frame['parentId'] == null) clearWebSockets();
      frameManager.frameNavigated(
        frame['id'] as String,
        frame['url'] as String,
        frame['name'] as String? ?? '',
        frame['loaderId'] as String? ?? '',
        parentId: frame['parentId'] as String?,
      );
    });
    session.on('Page.frameDetached', (params) {
      final frameId = params['frameId'] as String;
      _contexts.frameDetached(frameId);
      frameManager.frameDetached(frameId);
    });
    session.on('Page.navigatedWithinDocument', (params) {
      frameManager.frameNavigatedWithinDocument(
          params['frameId'] as String, params['url'] as String);
    });
    session.on('Page.lifecycleEvent', (params) {
      frameManager.frameLifecycleEvent(
        params['frameId'] as String,
        params['name'] as String,
        loaderId: params['loaderId'] as String?,
      );
    });
    // Some Chromium builds do not deliver Page.lifecycleEvent reliably for
    // the main frame even after Page.setLifecycleEventsEnabled. The legacy
    // load events are always emitted, so use them as a main-frame fallback.
    session.on('Page.loadEventFired', (_) {
      final frame = frameManager.mainFrame;
      if (frame != null) {
        frameManager.frameLifecycleEvent(frame.id, 'load');
      }
    });
    session.on('Page.domContentEventFired', (_) {
      final frame = frameManager.mainFrame;
      if (frame != null) {
        frameManager.frameLifecycleEvent(frame.id, 'DOMContentLoaded');
      }
    });
  }

  // ------------------------------------------------------------ websockets

  /// CDP reports frame timestamps on the monotonic clock. The baseline is the
  /// difference between the wall time and the monotonic time of the handshake,
  /// which is the only event carrying both (`crNetworkManager.ts:541`).
  final _wsWallTimeBaseline = <String, double>{};

  double _wsWallTime(String requestId, dynamic timestamp) {
    final baseline = _wsWallTimeBaseline[requestId];
    final value = (timestamp as num?)?.toDouble();
    if (baseline == null || value == null) return -1;
    return baseline + value * 1000;
  }

  void _wireWebSocketEvents() {
    // Upstream wires these in crNetworkManager and forwards straight to the
    // frame manager; here the page owns the registry, so the page is where
    // they land. The protocol events and their payloads are unchanged.
    session.on('Network.webSocketCreated', (Map<String, dynamic> params) {
      onWebSocketCreated(
          params['requestId'] as String, params['url'] as String? ?? '');
    });
    session.on('Network.webSocketWillSendHandshakeRequest',
        (Map<String, dynamic> params) {
      final requestId = params['requestId'] as String;
      final wallTimeMs = ((params['wallTime'] as num?)?.toDouble() ?? 0) * 1000;
      final timestamp = (params['timestamp'] as num?)?.toDouble() ?? 0;
      _wsWallTimeBaseline[requestId] = wallTimeMs - timestamp * 1000;
      final request = params['request'] as Map<String, dynamic>? ?? const {};
      onWebSocketRequest(requestId,
          headers: headersObjectToArray(request['headers'], separator: '\n'),
          wallTimeMs: wallTimeMs);
    });
    session.on('Network.webSocketHandshakeResponseReceived',
        (Map<String, dynamic> params) {
      final response = params['response'] as Map<String, dynamic>? ?? const {};
      onWebSocketResponse(
        params['requestId'] as String,
        status: (response['status'] as num?)?.toInt() ?? 0,
        statusText: response['statusText'] as String? ?? '',
        headers: headersObjectToArray(response['headers'], separator: '\n'),
      );
    });
    session.on('Network.webSocketFrameSent', (Map<String, dynamic> params) {
      final response = params['response'] as Map<String, dynamic>? ?? const {};
      final payload = response['payloadData'] as String?;
      if (payload == null || payload.isEmpty) return;
      final requestId = params['requestId'] as String;
      onWebSocketFrameSent(
          requestId,
          (response['opcode'] as num?)?.toInt() ?? 0,
          payload,
          _wsWallTime(requestId, params['timestamp']));
    });
    session.on('Network.webSocketFrameReceived', (Map<String, dynamic> params) {
      final response = params['response'] as Map<String, dynamic>? ?? const {};
      final payload = response['payloadData'] as String?;
      if (payload == null || payload.isEmpty) return;
      final requestId = params['requestId'] as String;
      webSocketFrameReceived(
          requestId,
          (response['opcode'] as num?)?.toInt() ?? 0,
          payload,
          _wsWallTime(requestId, params['timestamp']));
    });
    session.on('Network.webSocketClosed', (Map<String, dynamic> params) {
      final requestId = params['requestId'] as String;
      _wsWallTimeBaseline.remove(requestId);
      webSocketClosed(requestId);
    });
    session.on('Network.webSocketFrameError', (Map<String, dynamic> params) {
      webSocketError(params['requestId'] as String,
          params['errorMessage'] as String? ?? '');
    });
  }

  // --------------------------------------------------------------- workers

  final _workerSessions = <String, dynamic>{};

  void _wireWorkerEvents() {
    session.on('Target.attachedToTarget', (Map<String, dynamic> params) {
      _onAttachedToTarget(params).catchError((Object _) {});
    });
    session.on('Target.detachedFromTarget', (Map<String, dynamic> params) {
      final sessionId = params['sessionId'] as String?;
      if (sessionId == null) return;
      if (_workerSessions.remove(sessionId) == null) return;
      (session.connection as dynamic).closeSession(sessionId);
      removeWorker(sessionId);
    });
  }

  Future<void> _onAttachedToTarget(Map<String, dynamic> params) async {
    final targetInfo = params['targetInfo'] as Map<String, dynamic>?;
    final sessionId = params['sessionId'] as String?;
    if (targetInfo == null || sessionId == null) return;
    if (targetInfo['type'] != 'worker') {
      // Not something this port models (an OOPIF, most often). Detaching
      // releases it; leaving it attached and paused would hang the page.
      await session
          .send('Target.detachFromTarget', {'sessionId': sessionId}).catchError(
              (Object _) => <String, dynamic>{});
      return;
    }

    final connection = session.connection as dynamic;
    final workerSession = connection.createSession(sessionId, 'worker');
    _workerSessions[sessionId] = workerSession;
    final worker = CoreWorker(targetInfo['url'] as String? ?? '');

    workerSession.once('Runtime.executionContextCreated',
        (Map<String, dynamic> event) {
      final context = event['context'] as Map<String, dynamic>? ?? const {};
      worker.createExecutionContext(
          CrExecutionContext(workerSession, (context['id'] as num?)?.toInt()));
      // Upstream gates this on `Inspector.workerScriptLoaded` for Chromium
      // 143+, which only matters when the target starts paused. This port
      // never pauses a worker (see the setAutoAttach below), so the context
      // is usable the moment it is announced — which is what upstream does
      // for every older Chromium.
      worker.workerScriptLoaded();
    });
    addWorker(sessionId, worker);

    // Best effort: the worker may be gone before any of this lands.
    await workerSession
        .send('Runtime.enable')
        .catchError((Object _) => <String, dynamic>{});
    await workerSession
        .send('Runtime.runIfWaitingForDebugger')
        .catchError((Object _) => <String, dynamic>{});
  }

  void _onDialogOpening(Map<String, dynamic> params) {
    dispatchDialog(Dialog(
      params['type'] as String? ?? 'alert',
      params['message'] as String? ?? '',
      params['defaultPrompt'] as String? ?? '',
      (accept, promptText) async {
        await session.send('Page.handleJavaScriptDialog', {
          'accept': accept,
          if (promptText != null) 'promptText': promptText,
        });
      },
    ));
  }

  void _onConsoleAPICalled(Map<String, dynamic> params) {
    // CDP replays the last 1000 console messages when Runtime is enabled,
    // tagged with executionContextId 0. Upstream drops them (crPage.ts:797)
    // and so must we, or every page starts by reporting the previous page's
    // console.
    final contextId = params['executionContextId'];
    if (contextId == null || contextId == 0) return;

    final stack = params['stackTrace'] as Map<String, dynamic>?;
    final frames = stack?['callFrames'] as List?;
    final top = (frames != null && frames.isNotEmpty)
        ? frames.first as Map<String, dynamic>
        : null;
    emit(
        'console',
        CoreConsoleMessage(
          type: normalizeConsoleType(params['type'] as String?),
          text: describeConsoleArgs(params['args']),
          location: CoreSourceLocation(
            url: top?['url'] as String? ?? '',
            lineNumber: (top?['lineNumber'] as num?)?.toInt() ?? 0,
            columnNumber: (top?['columnNumber'] as num?)?.toInt() ?? 0,
          ),
        ));
  }

  void _onLogEntryAdded(Map<String, dynamic> params) {
    final entry = params['entry'] as Map<String, dynamic>?;
    if (entry == null) return;
    // Worker entries belong to the worker's own console (crPage.ts:858).
    // Everything else the browser itself reports - failed subresources, CSP
    // violations, deprecations - reaches the page console with the log level
    // standing in for the console type.
    if (entry['source'] == 'worker') return;
    emit(
        'console',
        CoreConsoleMessage(
          type: normalizeConsoleType(entry['level'] as String?),
          text: entry['text'] as String? ?? '',
          location: CoreSourceLocation(
            url: entry['url'] as String? ?? '',
            lineNumber: (entry['lineNumber'] as num?)?.toInt() ?? 0,
          ),
        ));
  }

  void _onExceptionThrown(Map<String, dynamic> params) {
    final details = params['exceptionDetails'] as Map<String, dynamic>?;
    if (details == null) return;
    emit('pageerror', pageErrorFromCdpExceptionDetails(details));
  }

  /// Create and initialize a new page.
  static Future<CrPage> create(dynamic session, {String? targetId}) async {
    final page = CrPage._(session, targetId);
    await page._initialize();
    return page;
  }

  Future<void> _initialize() async {
    // Enable essential domains
    await Future.wait(<Future<dynamic>>[
      session.send('Page.enable') as Future<dynamic>,
      session.send('Page.setLifecycleEventsEnabled', {'enabled': true})
          as Future<dynamic>,
      session.send('Runtime.enable') as Future<dynamic>,
      session.send('Network.enable') as Future<dynamic>,
      session.send('Log.enable') as Future<dynamic>,
      session.send('Accessibility.enable') as Future<dynamic>,
    ]);
    // Chromium only emits Page.frameAttached/frameNavigated for frames
    // created after Page.enable. The main frame predates it, so seed the
    // existing tree or waitForMainFrame() would never complete.
    final result = await session.send('Page.getFrameTree');
    _handleFrameTree(result['frameTree'] as Map<String, dynamic>);
    // Workers are sub-targets of the page, so the page session is where they
    // auto-attach; the browser-level auto-attach only sees page targets.
    //
    // Upstream uses `waitForDebuggerOnStart: true` here so that the very
    // first console messages of the worker are not missed. This port leaves
    // it off, as it already does at the browser level: a paused target that
    // nobody resumes hangs the page, and `Runtime.enable` replays the
    // execution context anyway, so nothing this port exposes needs the pause.
    // The cost is the one upstream pays for: messages logged before the
    // worker session is attached are lost.
    await session.send('Target.setAutoAttach', {
      'autoAttach': true,
      'waitForDebuggerOnStart': false,
      'flatten': true,
    });
    // Upstream sends this last, after everything the page needs is enabled
    // (crPage.ts:548). It is not only about paused targets: while a target
    // auto-attached from `window.open` has not been resumed, the opener's
    // renderer stays blocked inside the `window.open` call, so the evaluate
    // or the click that opened the popup never returns.
    await session.send('Runtime.runIfWaitingForDebugger');
  }

  void _handleFrameTree(Map<String, dynamic> frameTree) {
    final frame = frameTree['frame'] as Map<String, dynamic>;
    final parentId = frame['parentId'] as String?;
    frameManager.frameAttached(frame['id'] as String, parentId);
    frameManager.frameNavigated(
      frame['id'] as String,
      frame['url'] as String? ?? '',
      frame['name'] as String? ?? '',
      frame['loaderId'] as String? ?? '',
      parentId: parentId,
    );
    for (final child in frameTree['childFrames'] as List? ?? const []) {
      _handleFrameTree(child as Map<String, dynamic>);
    }
  }

  @override
  CoreFrame get mainFrame => frameManager.mainFrame!;

  @override
  List<CoreFrame> get frames => frameManager.frames;

  @override
  late final CoreCoverage coverage = CrCoverage(session);

  // --------------------------------------------------- init scripts

  /// Identifiers CDP gave the scripts currently installed, so the next
  /// [applyInitScripts] can take them back off.
  final _initScriptIds = <String>[];

  /// Binding channels already opened on this page.
  final _bindingChannels = <String>{};

  @override
  Future<void> applyInitScripts(List<CoreInitScript> scripts) async {
    for (final identifier in _initScriptIds) {
      try {
        await session.send('Page.removeScriptToEvaluateOnNewDocument',
            {'identifier': identifier});
      } catch (_) {
        // The page may already be gone; the script goes with it.
      }
    }
    _initScriptIds.clear();
    for (final script in scripts) {
      final result = await session.send(
          'Page.addScriptToEvaluateOnNewDocument', {'source': script.source});
      final identifier = result['identifier'] as String?;
      if (identifier != null) _initScriptIds.add(identifier);
    }
  }

  @override
  Future<void> installBindingChannel(String name) async {
    if (!_bindingChannels.add(name)) return;
    try {
      await session.send('Runtime.addBinding', {'name': name});
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
    final contextId = (params['executionContextId'] as num?)?.toInt();
    if (payload is! String || contextId == null) return;
    // The context is addressed by id rather than looked up in the registry:
    // a binding can legitimately be called from a context the driver never
    // saw announced, and the answer still has to reach it.
    dispatchBindingCall(payload, CrExecutionContext(session, contextId));
  }

  @override
  Future<CoreExecutionContext> executionContextFor(CoreFrame frame,
      {Duration? timeout}) {
    return _contexts.waitFor(frame.id,
        timeout: timeout ?? const Duration(seconds: 10),
        // The main frame's default context is addressable without an id, so a
        // missing creation event must not make the page unusable.
        fallback:
            frame.parentId == null ? CrExecutionContext(session, null) : null);
  }

  @override
  Future<void> gotoFrame(CoreFrame frame, String url,
      {WaitUntilState? waitUntil, Duration? timeout, String? referer}) async {
    final loaded = frame.waitForNavigation(
        waitUntil: waitUntil, timeout: timeout ?? const Duration(seconds: 30));
    loaded.catchError((_) {});
    final result = await session.send('Page.navigate', {
      'url': url,
      'frameId': frame.id,
      if (referer != null) 'referrer': referer,
    });
    if (result['errorText'] != null) {
      throw PlaywrightException(
          'Navigation to $url failed: ${result['errorText']}');
    }
    await loaded;
  }

  @override
  Future<CoreFrame?> contentFrame(CoreJSHandle handle) async {
    if (handle is! CrJSHandle) return null;
    final info =
        await session.send('DOM.describeNode', {'objectId': handle.objectId});
    final frameId = info['node']?['frameId'];
    if (frameId is! String) return null;
    return frameManager.frame(frameId);
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
      {WaitUntilState? waitUntil, Duration? timeout, String? referer}) async {
    final frame = await frameManager.waitForMainFrame();
    final loaded = frame.waitForNavigation(
        waitUntil: waitUntil, timeout: timeout ?? const Duration(seconds: 30));
    // Keep the waiter's timeout handled even while Page.navigate stalls on a
    // slow server; the awaited rethrow below still surfaces it.
    loaded.catchError((_) {});
    final result = await session.send('Page.navigate',
        {'url': url, if (referer != null) 'referrer': referer});
    if (result['errorText'] != null) {
      throw PlaywrightException(
          'Navigation to $url failed: ${result['errorText']}');
    }
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
  Future<bool> goBack({WaitUntilState? waitUntil}) => _goHistory(-1, waitUntil);

  @override
  Future<bool> goForward({WaitUntilState? waitUntil}) =>
      _goHistory(1, waitUntil);

  Future<bool> _goHistory(int delta, WaitUntilState? waitUntil) async {
    final history = await session.send('Page.getNavigationHistory');
    final entries = history['entries'] as List;
    final targetIndex = (history['currentIndex'] as int) + delta;
    if (targetIndex < 0 || targetIndex >= entries.length) return false;
    final entry = entries[targetIndex] as Map<String, dynamic>;
    final frame = await frameManager.waitForMainFrame();
    final loaded = frame.waitForNavigation(
        waitUntil: waitUntil, timeout: const Duration(seconds: 30));
    await session.send('Page.navigateToHistoryEntry', {'entryId': entry['id']});
    await loaded;
    return true;
  }

  /// Get the page title.
  Future<String> title() async {
    final result = await evaluate('document.title');
    return result.toString();
  }

  /// Evaluate JavaScript in the page's main frame.
  @override
  Future<dynamic> evaluate(String expression) async {
    final frame = await frameManager.waitForMainFrame();
    return evaluateInFrame(frame, expression);
  }

  /// Fill an element using trusted CDP input events.
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
    await session.send('Input.insertText', {'text': text});
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
  Future<void> setDefaultBackgroundColor(
          ({int r, int g, int b, int a})? color) =>
      session.send('Emulation.setDefaultBackgroundColorOverride', {
        if (color != null)
          'color': {'r': color.r, 'g': color.g, 'b': color.b, 'a': color.a},
      }) as Future<void>;

  @override
  Future<List<int>> screenshotRect(CoreRect rect, CoreScreenshotOptions options,
      {bool fitsViewport = true}) async {
    var clipScale = 1.0;
    if (options.scale == 'css') {
      // A HiDPI screen would otherwise give an image larger than the CSS box.
      final ratio = await evaluate('() => window.devicePixelRatio') as num?;
      if (ratio != null && ratio > 0) clipScale = 1 / ratio.toDouble();
    }
    final result = await session.send('Page.captureScreenshot', {
      'format': options.type,
      if (options.effectiveQuality != null) 'quality': options.effectiveQuality,
      'clip': {
        'x': rect.x,
        'y': rect.y,
        'width': rect.width,
        'height': rect.height,
        'scale': clipScale,
      },
      // This is how a full-page shot works without resizing the window.
      'captureBeyondViewport': !fitsViewport,
    });
    return base64Decode(result['data'] as String);
  }

  @override
  Future<List<int>> pdf(
      {String? path, CorePdfOptions options = const CorePdfOptions()}) async {
    final paper = options.paperSize;
    final result = await session.send('Page.printToPDF', {
      // Asking for a stream keeps a large document out of a single protocol
      // message, which is what upstream does too.
      'transferMode': 'ReturnAsStream',
      'landscape': options.landscape,
      'displayHeaderFooter': options.displayHeaderFooter,
      'headerTemplate': options.headerTemplate,
      'footerTemplate': options.footerTemplate,
      'printBackground': options.printBackground,
      'scale': options.scale,
      'paperWidth': paper.width,
      'paperHeight': paper.height,
      'marginTop': options.marginTop,
      'marginBottom': options.marginBottom,
      'marginLeft': options.marginLeft,
      'marginRight': options.marginRight,
      'pageRanges': options.pageRanges,
      'preferCSSPageSize': options.preferCSSPageSize,
      'generateTaggedPDF': options.tagged,
      'generateDocumentOutline': options.outline,
    });

    final handle = result['stream'] as String?;
    final bytes = handle == null
        ? base64Decode(result['data'] as String? ?? '')
        : await _readProtocolStream(handle);
    if (path != null) await File(path).writeAsBytes(bytes);
    return bytes;
  }

  /// Drains an `IO` stream handle. The browser decides the chunk size; the
  /// loop ends on `eof` and the handle is closed afterwards.
  Future<List<int>> _readProtocolStream(String handle) async {
    final chunks = <int>[];
    var eof = false;
    while (!eof) {
      final response = await session.send('IO.read', {'handle': handle});
      final data = response['data'] as String? ?? '';
      chunks.addAll(response['base64Encoded'] == true
          ? base64Decode(data)
          : utf8.encode(data));
      eof = response['eof'] == true;
    }
    await session.send('IO.close', {'handle': handle});
    return chunks;
  }

  bool _routeListenerInstalled = false;

  /// Add a route interception handler.
  @override
  Future<void> route(Object urlPattern, void Function(CoreRoute) handler,
      {bool fromContext = false}) async {
    if (!_routeListenerInstalled) {
      _routeListenerInstalled = true;
      session.on('Fetch.requestPaused', _onRequestPaused);
    }
    if (!hasRoutes) {
      await session.send('Fetch.enable', {
        'patterns': [
          {'requestStage': 'Request'}
        ]
      });
    }
    addRouteEntry(urlPattern, handler, fromContext: fromContext);
  }

  @override
  Future<void> unroute(Object urlPattern, {bool fromContext = false}) async {
    removeRouteEntry(urlPattern, fromContext: fromContext);
    if (!hasRoutes) {
      await session.send('Fetch.disable');
    }
  }

  void _onRequestPaused(Map<String, dynamic> params) {
    final fetchRequestId = params['requestId'] as String;
    final request = params['request'] as Map<String, dynamic>;
    final url = request['url'] as String;

    if (!hasHandlerFor(url)) {
      // Fire-and-forget: the page may be closing and the session already
      // gone; that must not surface as an unhandled async error.
      (session.send('Fetch.continueRequest', {'requestId': fetchRequestId})
              as Future<Map<String, dynamic>>)
          .catchError((_) => <String, dynamic>{});
      return;
    }

    dispatchRoute(CrRoute(
      session,
      fetchRequestId,
      url,
      method: request['method'] as String? ?? 'GET',
      headers: _stringHeaders(request['headers']),
      postData: request['postData'] as String?,
      resourceType: normalizeResourceType(params['resourceType'] as String?),
      isNavigationRequest: params['resourceType'] == 'Document',
      frame: params['frameId'],
    ));
  }

  Map<String, String> _stringHeaders(dynamic headers) {
    if (headers is! Map) return const <String, String>{};
    return headers.map((key, value) => MapEntry('$key', '$value'));
  }

  @override
  Future<void> setInputFilePaths(
      CoreFrame frame, CoreJSHandle handle, List<String> paths) async {
    await session.send('DOM.setFileInputFiles', {
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
    // CDP hands over a backendNodeId, not an object id, so the node has to be
    // resolved into the frame's context before it can be used.
    final backendNodeId = params['backendNodeId'];
    final frameId = params['frameId'] as String?;
    if (backendNodeId == null || frameId == null) return;
    _resolveFileChooser(backendNodeId, frameId, params['mode'] as String?)
        .catchError((Object _) {});
  }

  Future<void> _resolveFileChooser(
      Object backendNodeId, String frameId, String? mode) async {
    final frame = frameManager.frame(frameId);
    if (frame == null) return;
    final context = await executionContextFor(frame) as CrExecutionContext;
    final resolved = await session.send('DOM.resolveNode', {
      'backendNodeId': backendNodeId,
      if (context.executionContextId != null)
        'executionContextId': context.executionContextId,
    });
    final objectId = (resolved['object'] as Map?)?['objectId'] as String?;
    if (objectId == null) return;
    emit(
        'filechooser',
        CoreFileChooser(
          element: CrJSHandle(context, objectId),
          isMultiple: mode == 'selectMultiple',
        ));
  }

  @override
  Future<void> setViewportSize(int width, int height) async {
    // Upstream keeps screen size equal to the viewport for a plain
    // setViewportSize (page.ts:636) and sends a landscape orientation for
    // non-mobile pages (crPage.ts:922).
    await session.send('Emulation.setDeviceMetricsOverride', {
      'mobile': false,
      'width': width,
      'height': height,
      'screenWidth': width,
      'screenHeight': height,
      'deviceScaleFactor': 1,
      'screenOrientation': {'angle': 0, 'type': 'landscapePrimary'},
      'dontSetVisibleSize': false,
    });
  }

  @override
  Future<void> setExtraHTTPHeaders(Map<String, String> headers) async {
    // CDP takes a plain object and upstream does not lower-case the names.
    await session.send('Network.setExtraHTTPHeaders', {'headers': headers});
  }

  @override
  bool get isClosed => _isClosed;

  /// Close the page.
  Future<void> close() async {
    if (_isClosed) return;
    await session.send('Page.close');
  }

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
