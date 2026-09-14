import 'dart:convert';
import 'dart:io';
import 'package:playwright_protocol/playwright_protocol.dart';
import 'cr_execution_context.dart';
import 'cr_js_handle.dart';
import 'cr_input.dart';
import 'cr_network_manager.dart';
import 'cr_route.dart';
import '../context_registry.dart';
import '../core_request.dart';
import '../core_route.dart';
import '../../accessibility.dart';
import '../core_page.dart';
import '../core_js_handle.dart';

/// Represents a Chromium Page (tab).
class CrPage extends EventEmitter
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
    // The renderer died: the tab is showing "Aw, Snap!". The session survives,
    // so the page object stays usable enough to report the crash.
    session.on('Inspector.targetCrashed', (_) => emit('crash', true));

    // Frame events
    session.on('Page.frameAttached', (params) {
      frameManager.frameAttached(
          params['frameId'] as String, params['parentFrameId'] as String?);
    });
    session.on('Page.frameNavigated', (params) {
      final frame = params['frame'] as Map<String, dynamic>;
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
  Future<CoreExecutionContext> executionContextFor(CoreFrame frame,
      {Duration? timeout}) {
    return _contexts.waitFor(frame.id,
        timeout: timeout ?? const Duration(seconds: 10),
        // The main frame's default context is addressable without an id, so a
        // missing creation event must not make the page unusable.
        fallback: frame.parentId == null
            ? CrExecutionContext(session, null)
            : null);
  }

  @override
  Future<void> gotoFrame(CoreFrame frame, String url,
      {WaitUntilState? waitUntil, Duration? timeout}) async {
    final loaded = frame.waitForNavigation(
        waitUntil: waitUntil, timeout: timeout ?? const Duration(seconds: 30));
    loaded.catchError((_) {});
    final result =
        await session.send('Page.navigate', {'url': url, 'frameId': frame.id});
    if (result['errorText'] != null) {
      throw PlaywrightException(
          'Navigation to $url failed: ${result['errorText']}');
    }
    await loaded;
  }

  @override
  Future<CoreFrame?> contentFrame(CoreJSHandle handle) async {
    if (handle is! CrJSHandle) return null;
    final info = await session
        .send('DOM.describeNode', {'objectId': handle.objectId});
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
      {WaitUntilState? waitUntil, Duration? timeout}) async {
    final frame = await frameManager.waitForMainFrame();
    final loaded = frame.waitForNavigation(
        waitUntil: waitUntil, timeout: timeout ?? const Duration(seconds: 30));
    // Keep the waiter's timeout handled even while Page.navigate stalls on a
    // slow server; the awaited rethrow below still surfaces it.
    loaded.catchError((_) {});
    final result = await session.send('Page.navigate', {'url': url});
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
  Future<bool> goBack({WaitUntilState? waitUntil}) =>
      _goHistory(-1, waitUntil);

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
      {String? path,
      CorePdfOptions options = const CorePdfOptions()}) async {
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

  /// Get Accessibility Snapshot
  Future<AccessibilitySnapshot> accessibilitySnapshot() async {
    final result = await session.send('Accessibility.getFullAXTree');
    final nodes = result['nodes'] as List;

    // Simplistic parser for V0.1
    if (nodes.isEmpty) {
      return AccessibilitySnapshot(
          title: '',
          root: AccessibilityNode(role: 'WebArea', name: '', ref: 'root'));
    }

    final rootData = nodes.firstWhere((n) => n['role']?['value'] == 'WebArea',
        orElse: () => nodes.first);

    AccessibilityNode parseNode(Map<String, dynamic> data) {
      final role = data['role']?['value'] as String? ?? 'Unknown';
      final name = data['name']?['value'] as String? ?? '';
      final description = data['description']?['value'] as String?;
      final value = data['value']?['value']?.toString();
      final nodeId = data['nodeId'] as String? ?? '';

      final childIds = (data['childIds'] as List?)?.cast<String>() ?? [];
      final children = childIds
          .map((id) {
            final childData =
                nodes.firstWhere((n) => n['nodeId'] == id, orElse: () => null);
            return childData != null ? parseNode(childData) : null;
          })
          .whereType<AccessibilityNode>()
          .toList();

      return AccessibilityNode(
        role: role,
        name: name,
        description: description,
        value: value,
        children: children,
        ref: 'node_$nodeId',
      );
    }

    final root = parseNode(rootData);
    final title = await this.title();

    return AccessibilitySnapshot(title: title, root: root);
  }

  bool _routeListenerInstalled = false;

  /// Add a route interception handler.
  @override
  Future<void> route(
      String urlPattern, void Function(CoreRoute) handler) async {
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
    addRouteEntry(urlPattern, handler);
  }

  @override
  Future<void> unroute(String urlPattern) async {
    removeRouteEntry(urlPattern);
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
    emit('close', true);
    disposeStreams();
  }
}
